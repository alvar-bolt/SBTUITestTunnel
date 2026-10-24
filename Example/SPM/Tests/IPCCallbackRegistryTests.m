#import <XCTest/XCTest.h>
#import "../../../Sources/SBTUITestTunnelCommon/DetoxIPC/fno-objc-arc/NSInvocation+DTXRemoteSerialization.h"
#import "../../../Sources/SBTUITestTunnelCommon/DetoxIPC/DTXIPCConnection.h"
#import "../../../Sources/SBTUITestTunnelCommon/DetoxIPC/fno-objc-arc/_DTXIPCRemoteBlockRegistry.h"
#import "../../../Sources/SBTUITestTunnelClient/include/SBTUITestTunnelClient.h"

@interface SBTUITestTunnelClient (ReplyContractTests)
- (NSString*)sendSynchronousRequestWithPath:(NSString*)path params:(NSDictionary*)params assertOnError:(BOOL)assertOnError;
@end

// These private interfaces belong to the same pinned package under test.
@interface DTXIPCConnection (CallbackRegistryTests)
@property (atomic, strong) NSError* failureError;
- (BOOL)_invokeRemoteBlock:(NSDictionary*)serializedBlock;
- (oneway void)_cleanupRemoteBlock:(NSString*)identifier;
@end

@interface _DTXIPCExportedObject : NSObject
+ (instancetype)_exportedObjectWithObject:(id)object connection:(DTXIPCConnection*)connection serializedInvocation:(NSDictionary*)serializedInvocation;
- (oneway void)invoke;
@end

@interface IPCReplyOwner : NSObject
@property (atomic) NSInteger entered;
@property (nonatomic, strong) dispatch_group_t replyGroup;
@property (nonatomic, readonly) NSInteger left;
@property (nonatomic, strong) id queuedInvocation;
@end

@implementation IPCReplyOwner
- (instancetype)init
{
    self = [super init];
    if (self) { self.replyGroup = dispatch_group_create(); }
    return self;
}
- (dispatch_group_t)_enterReplyGroup
{
    self.entered += 1;
    dispatch_group_enter(self.replyGroup);
    return self.replyGroup;
}
- (NSInteger)left
{
    return dispatch_group_wait(self.replyGroup, DISPATCH_TIME_NOW) == 0 ? self.entered : 0;
}
- (BOOL)_enqueueSynchronousExportedObjectInvocation:(id)invocation
{
    self.queuedInvocation = invocation;
    return YES;
}
@end

@interface IPCRegressionConnection : DTXIPCConnection
@property (nonatomic) BOOL wasInvalidated;
@end

@implementation IPCRegressionConnection
- (void)invalidate
{
    self.wasInvalidated = YES;
    [super invalidate];
}
@end

@interface IPCForwardingBlockReceiver : NSObject
@property (nonatomic, copy) void (^reply)(void);
- (void)captureReply:(void (^)(void))reply;
@end

@implementation IPCForwardingBlockReceiver
- (void)captureReply:(void (^)(void))reply { self.reply = reply; }
@end

@protocol IPCFailureFixtureProtocol <NSObject>
- (void)requestWithReply:(void (^)(void))reply;
- (void)requestWithReply:(void (^)(void))reply otherReply:(void (^)(void))other;
@end

@class IPCFailureFixtureConnection;
@interface IPCFailureFixturePeer : NSObject
@property (nonatomic, weak) IPCFailureFixtureConnection* owner;
@property (nonatomic) BOOL cleanupBeforeReply;
@property (nonatomic) BOOL rejectCallbackDelivery;
@property (nonatomic) NSInteger requests;
@property (nonatomic, copy) NSString* heldIdentifier;
- (id)rootProxy;
- (oneway void)_invokeFromRemote:(NSDictionary*)invocation;
@end

@interface IPCLiveAsyncReplyPeer : NSObject <IPCFailureFixtureProtocol>
@end
@implementation IPCLiveAsyncReplyPeer
- (void)requestWithReply:(void (^)(void))reply
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { reply(); }
    });
}
- (void)requestWithReply:(void (^)(void))reply otherReply:(void (^)(void))other
{
    [self requestWithReply:reply];
    [self requestWithReply:other];
}
@end

// Hold an actual NSConnection callback at receiver entry so its later one-way
// cleanup can overtake acquisition, matching the independently captured CI race.
@interface IPCDeferredDeliveryConnection : IPCRegressionConnection
@property (nonatomic, strong) dispatch_semaphore_t deliveryEntered;
@property (nonatomic, strong) dispatch_semaphore_t allowDelivery;
@property (nonatomic, strong) dispatch_semaphore_t cleanupReceived;
@end

@implementation IPCDeferredDeliveryConnection
- (instancetype)initWithServiceName:(NSString*)serviceName
{
    self = [super initWithServiceName:serviceName];
    if (self) {
        self.deliveryEntered = dispatch_semaphore_create(0);
        self.allowDelivery = dispatch_semaphore_create(0);
        self.cleanupReceived = dispatch_semaphore_create(0);
    }
    return self;
}
- (BOOL)_invokeRemoteBlock:(NSDictionary*)serializedBlock
{
    dispatch_semaphore_signal(self.deliveryEntered);
    dispatch_semaphore_wait(self.allowDelivery, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return [super _invokeRemoteBlock:serializedBlock];
}
- (oneway void)_cleanupRemoteBlock:(NSString*)identifier
{
    dispatch_semaphore_signal(self.cleanupReceived);
    [super _cleanupRemoteBlock:identifier];
}
@end

@interface IPCFailureFixtureConnection : IPCRegressionConnection
@property (nonatomic) BOOL fixtureValid;
@property (nonatomic, strong) IPCFailureFixturePeer* fixturePeer;
@end

@implementation IPCFailureFixtureConnection
- (BOOL)isValid { return self.fixtureValid; }
- (id)otherConnection { return self.fixturePeer; }
- (void)invalidate
{
    self.fixtureValid = NO;
    [super invalidate];
}
@end

@implementation IPCFailureFixturePeer
- (id)rootProxy { return self; }
- (oneway void)_dumpRemoteBlockHistory:(NSString*)identifier
{
    [_DTXIPCRemoteBlockRegistry dumpLifetimeHistoryForIdentifier:identifier reason:@"fixture_peer"];
}
- (BOOL)_invokeRemoteBlock:(NSDictionary*)serialized
{
    return self.rejectCallbackDelivery ? NO : [self.owner _invokeRemoteBlock:serialized];
}
- (oneway void)_cleanupRemoteBlock:(NSString*)identifier { [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier]; }
- (BOOL)_ping
{
    if (self.owner.fixtureValid == NO) { [NSException raise:@"IPCFixtureInvalidated" format:@"Fixture connection was invalidated"]; }
    return YES;
}
- (oneway void)_invokeFromRemote:(NSDictionary*)invocation
{
    NSString* identifier = invocation[@"arguments"][2][@"remoteIdentifier"];
    if ([invocation[@"arguments"] count] > 3) { self.heldIdentifier = invocation[@"arguments"][3][@"remoteIdentifier"]; }
    self.requests += 1;
    if (self.cleanupBeforeReply) { [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier]; }
    [self.owner _invokeRemoteBlock:@{@"blockCall": @YES, @"remoteBlockIdentifier": identifier,
                                   @"types": @"v8@?0", @"arguments": @[NSNull.null]}];
    if (self.cleanupBeforeReply == NO) { [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier]; }
}
@end

@interface IPCClientFixtureApplication : NSObject
@property (nonatomic, copy) NSArray* launchArguments;
@property (nonatomic, copy) NSDictionary* launchEnvironment;
@end
@implementation IPCClientFixtureApplication @end

@interface IPCClientDelegateSpy : NSObject <SBTUITestTunnelClientDelegate>
@property (nonatomic, strong) NSError* error;
@property (nonatomic) NSInteger shutdowns;
@end
@implementation IPCClientDelegateSpy
- (void)tunnelClientIsReadyToLaunch:(SBTUITestTunnelClient*)sender { }
- (void)tunnelClient:(SBTUITestTunnelClient*)sender didShutdownWithError:(NSError*)error
{
    self.error = error;
    self.shutdowns += 1;
}
@end

@interface IPCClientProxyFixture : NSObject <SBTIPCTunnel>
@property (nonatomic, weak) SBTUITestTunnelClient* client;
@property (nonatomic, strong) NSDictionary* reply;
@property (nonatomic, strong) NSError* error;
@end
@implementation IPCClientProxyFixture
- (void)performCommandWithParameters:(NSDictionary*)parameters block:(void (^)(NSDictionary*))block
{
    if (self.error) { [self.client setValue:self.error forKey:@"ipcRequestError"]; }
    if (self.reply) { block(self.reply); }
}
- (void)serverDidConnect:(id)sender { }
@end

@interface IPCClientFixture : NSObject
@property (nonatomic, strong) IPCClientFixtureApplication* application;
@property (nonatomic, strong) SBTUITestTunnelClient* client;
@property (nonatomic, strong) IPCClientDelegateSpy* delegate;
@property (nonatomic, strong) IPCClientProxyFixture* proxy;
@property (nonatomic, strong) IPCRegressionConnection* connection;
@end
@implementation IPCClientFixture
- (instancetype)init
{
    self = [super init];
    if (self) {
        self.application = [IPCClientFixtureApplication new];
        self.application.launchArguments = @[];
        self.application.launchEnvironment = @{};
        self.client = [[SBTUITestTunnelClient alloc] initWithApplication:(id)self.application];
        self.delegate = [IPCClientDelegateSpy new];
        self.client.delegate = self.delegate;
        self.proxy = [IPCClientProxyFixture new];
        self.proxy.client = self.client;
        self.connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
        [self.client setValue:self.connection forKey:@"ipcConnection"];
        [self.client setValue:self.proxy forKey:@"ipcProxy"];
        [self.client setValue:@YES forKey:@"connected"];
    }
    return self;
}
- (void)dealloc { [_connection invalidate]; }
@end

@interface IPCCallbackRegistryTests : XCTestCase
@end

@implementation IPCCallbackRegistryTests

- (NSDictionary*)invocationForIdentifier:(NSString*)identifier
{
    return @{@"blockCall": @YES, @"remoteBlockIdentifier": identifier,
             @"types": @"v8@?0", @"arguments": @[NSNull.null]};
}

- (void)testCleanupBetweenLookupAndInvocationPreservesCallback
{
    IPCReplyOwner* owner = [IPCReplyOwner new];
    __block NSInteger called = 0;
    NSString* identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{ called += 1; } distantObject:(id)owner];
    IPCRegressionConnection* connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    @autoreleasepool {
        _DTXIPCRemoteBlockSnapshot* snapshot = [_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier];
        XCTAssertNotNil(snapshot);
        [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
        XCTAssertNil([_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier]);
        XCTAssertEqual(owner.left, 0);
        // This was the second registry lookup that fed nil to _Block_signature.
        id invocation = [_DTXIPCExportedObject _exportedObjectWithObject:snapshot.block connection:connection serializedInvocation:[self invocationForIdentifier:identifier]];
        XCTAssertNotNil(invocation);
        [invocation invoke];
        XCTAssertEqual(called, 1);
        XCTAssertFalse(connection.wasInvalidated);
    }
    XCTAssertEqual(owner.entered, 1);
    XCTAssertEqual(owner.left, 1);
    [connection invalidate];
}

- (void)testReplyObligationSurvivesUntilCallbackIsQueued
{
    IPCReplyOwner* owner = [IPCReplyOwner new];
    __block NSInteger called = 0;
    NSString* identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{ called += 1; } distantObject:(id)owner];
    IPCRegressionConnection* connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    [connection _invokeRemoteBlock:[self invocationForIdentifier:identifier]];
    XCTAssertNotNil(owner.queuedInvocation);
    XCTAssertEqual(called, 0);
    XCTAssertEqual(owner.left, 0);
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    XCTAssertEqual(owner.left, 1);
    [owner.queuedInvocation invoke];
    XCTAssertEqual(called, 1);
    [connection invalidate];
}

- (void)testSnapshotHoldsReplyObligationAcrossConcurrentCleanup
{
    for (NSUInteger iteration = 0; iteration < 100; iteration++) {
        IPCReplyOwner* owner = [IPCReplyOwner new];
        __block NSInteger called = 0;
        NSString* identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{ called += 1; } distantObject:(id)owner];
        dispatch_semaphore_t acquired = dispatch_semaphore_create(0);
        dispatch_semaphore_t proceed = dispatch_semaphore_create(0);
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                _DTXIPCRemoteBlockSnapshot* snapshot = [_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier];
                dispatch_semaphore_signal(acquired);
                if (dispatch_semaphore_wait(proceed, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0) {
                    ((void (^)(void))snapshot.block)();
                }
            }
            dispatch_semaphore_signal(finished);
        });
        XCTAssertEqual(dispatch_semaphore_wait(acquired, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)), 0);
        [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
        XCTAssertEqual(owner.left, 0);
        dispatch_semaphore_signal(proceed);
        XCTAssertEqual(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)), 0);
        XCTAssertEqual(called, 1);
        XCTAssertEqual(owner.left, 1);
    }
}

- (void)testBalancedRetainsReleaseReplyExactlyOnce
{
    IPCReplyOwner* owner = [IPCReplyOwner new];
    NSString* identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{} distantObject:(id)owner];
    [_DTXIPCRemoteBlockRegistry retainRemoteBlock:identifier];
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    @autoreleasepool {
        XCTAssertNotNil([_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier]);
    }
    XCTAssertEqual(owner.left, 0);
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    XCTAssertEqual(owner.left, 1);
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    XCTAssertEqual(owner.left, 1);
}

- (void)testCleanupReleasesCapturedObjects
{
    __weak NSObject* weakToken;
    @autoreleasepool {
        NSObject* token = [NSObject new];
        weakToken = token;
        NSString* identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{ (void)token.description; } distantObject:nil];
        token = nil;
        XCTAssertNotNil(weakToken);
        [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    }
    XCTAssertNil(weakToken);
}

- (void)testUnknownCallbackInvalidatesConnection
{
    IPCRegressionConnection* connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    XCTAssertNoThrow([connection _invokeRemoteBlock:[self invocationForIdentifier:NSUUID.UUID.UUIDString]]);
    XCTAssertTrue(connection.wasInvalidated);
}

- (void)testMissingCallbackIdentifierInvalidatesConnection
{
    IPCRegressionConnection* connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    XCTAssertNoThrow([connection _invokeRemoteBlock:@{@"blockCall": @YES}]);
    XCTAssertTrue(connection.wasInvalidated);
}

- (void)testForwardingBlockCleanupAfterDisconnectionDoesNotThrow
{
    IPCRegressionConnection* connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    IPCForwardingBlockReceiver* receiver = [IPCForwardingBlockReceiver new];
    @autoreleasepool {
        NSDictionary* serialized = @{
            @"selector": @"captureReply:", @"types": @"v24@0:8@?16",
            @"arguments": @[NSNull.null, NSNull.null, @{
                @"type": @"block", @"signature": @"v8@?0", @"remoteIdentifier": NSUUID.UUID.UUIDString
            }]
        };
        id invocation = [_DTXIPCExportedObject _exportedObjectWithObject:receiver connection:connection serializedInvocation:serialized];
        [invocation invoke];
    }
    XCTAssertNotNil(receiver.reply);
    [connection invalidate];
    XCTAssertNoThrow(receiver.reply());
    XCTAssertNoThrow(receiver.reply = nil);
}

- (void)testMissingReplyReachesSynchronousProxyErrorHandler
{
    IPCFailureFixtureConnection* connection = [[IPCFailureFixtureConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    connection.fixtureValid = YES;
    connection.fixturePeer = [IPCFailureFixturePeer new];
    connection.fixturePeer.owner = connection;
    connection.fixturePeer.cleanupBeforeReply = YES;
    connection.remoteObjectInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    __block NSInteger errors = 0;
    __block NSInteger callbacks = 0;
    __block NSError* receivedError;
    id<IPCFailureFixtureProtocol> proxy = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError* error) {
        errors += 1;
        receivedError = error;
    }];
    [proxy requestWithReply:^{ callbacks += 1; }];
    XCTAssertEqual(callbacks, 0);
    XCTAssertEqual(errors, 1);
    XCTAssertEqualObjects(receivedError.domain, DTXIPCErrorDomain);
    XCTAssertEqual(receivedError.code, 2);
    [proxy requestWithReply:^{ callbacks += 1; }];
    XCTAssertEqual(errors, 2);
    XCTAssertEqual(callbacks, 0);
    XCTAssertEqual(connection.fixturePeer.requests, 1);
    [connection invalidate];
}

- (void)testSynchronousProxyDeliversRegisteredReply
{
    IPCFailureFixtureConnection* connection = [[IPCFailureFixtureConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    connection.fixtureValid = YES;
    connection.fixturePeer = [IPCFailureFixturePeer new];
    connection.fixturePeer.owner = connection;
    connection.remoteObjectInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    __block NSInteger errors = 0;
    __block NSInteger callbacks = 0;
    id<IPCFailureFixtureProtocol> proxy = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError* error) { errors += 1; }];
    [proxy requestWithReply:^{ callbacks += 1; }];
    XCTAssertEqual(callbacks, 1);
    XCTAssertEqual(errors, 0);
    XCTAssertFalse(connection.wasInvalidated);
    [connection invalidate];
}

- (void)testClientRejectsMissingMandatoryReply
{
    IPCClientFixture* fixture = [IPCClientFixture new];
    XCTAssertNil([fixture.client sendSynchronousRequestWithPath:@"fixture" params:@{} assertOnError:YES]);
    XCTAssertEqual(fixture.delegate.shutdowns, 1);
    XCTAssertTrue([fixture.delegate.error.localizedDescription containsString:@"without a reply"]);
}

- (void)testOptionalIPCProbeDoesNotFailDelegateWhenReplyIsMissing
{
    IPCClientFixture* fixture = [IPCClientFixture new];
    XCTAssertNil([fixture.client sendSynchronousRequestWithPath:@"fixture" params:@{} assertOnError:NO]);
    XCTAssertEqual(fixture.delegate.shutdowns, 0);
}

- (void)testClientPreservesRegisteredIPCReply
{
    IPCClientFixture* fixture = [IPCClientFixture new];
    fixture.proxy.reply = @{SBTUITunnelResponseResultKey: @"OK"};
    XCTAssertEqualObjects([fixture.client sendSynchronousRequestWithPath:@"fixture" params:@{} assertOnError:YES], @"OK");
    XCTAssertEqual(fixture.delegate.shutdowns, 0);
}

- (void)testClientReportsOriginalIPCTransportError
{
    IPCClientFixture* fixture = [IPCClientFixture new];
    fixture.proxy.error = [NSError errorWithDomain:DTXIPCErrorDomain code:2 userInfo:nil];
    XCTAssertNil([fixture.client sendSynchronousRequestWithPath:@"fixture" params:@{} assertOnError:YES]);
    XCTAssertEqualObjects(fixture.delegate.error, fixture.proxy.error);
    XCTAssertEqual(fixture.delegate.shutdowns, 1);
}

- (void)testLateCleanupAfterFailedCallLeavesOriginalReplyGroup
{
    IPCFailureFixtureConnection* connection = [[IPCFailureFixtureConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    connection.fixtureValid = YES;
    connection.fixturePeer = [IPCFailureFixturePeer new];
    connection.fixturePeer.owner = connection;
    connection.fixturePeer.cleanupBeforeReply = YES;
    connection.remoteObjectInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    __block NSInteger errors = 0;
    id<IPCFailureFixtureProtocol> proxy = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError* error) { errors += 1; }];
    [proxy requestWithReply:^{} otherReply:^{}];
    XCTAssertEqual(errors, 1);
    XCTAssertNotNil(connection.fixturePeer.heldIdentifier);
    XCTAssertNoThrow([_DTXIPCRemoteBlockRegistry releaseRemoteBlock:connection.fixturePeer.heldIdentifier]);
    [connection invalidate];
}

- (void)testCopiedForwardingReplySurvivesInvocationAndAutoreleasePool
{
    IPCFailureFixtureConnection* connection = [[IPCFailureFixtureConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    connection.fixtureValid = YES;
    connection.fixturePeer = [IPCFailureFixturePeer new];
    connection.fixturePeer.owner = connection;
    IPCForwardingBlockReceiver* receiver = [IPCForwardingBlockReceiver new];
    __block NSInteger replies = 0;
    __block NSString* identifier = nil;
    XCTestExpectation* delivered = [self expectationWithDescription:@"copied callback delivered"];
    @autoreleasepool {
        void (^reply)(void) = ^{ replies += 1; [delivered fulfill]; };
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[receiver methodSignatureForSelector:@selector(captureReply:)]];
        invocation.selector = @selector(captureReply:);
        [invocation setArgument:&reply atIndex:2];
        NSDictionary* serialized = [invocation _dtx_serializedDictionaryForDistantObject:nil];
        identifier = serialized[@"arguments"][2][@"remoteIdentifier"];
        id exported = [_DTXIPCExportedObject _exportedObjectWithObject:receiver connection:connection serializedInvocation:serialized];
        [exported invoke];
        XCTAssertNotNil(receiver.reply);
    }
    XCTAssertNotNil([_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier], @"An asynchronously retained forwarding copy must still own the registry entry");
    receiver.reply();
    [self waitForExpectations:@[delivered] timeout:5];
    XCTAssertEqual(replies, 1);
    XCTAssertTrue(connection.fixtureValid);
    @autoreleasepool { receiver.reply = nil; }
    XCTAssertNil([_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier]);
    [connection invalidate];
}

- (void)testLiveNSConnectionAsyncReplyCleanupOrdering
{
    NSString* service = NSUUID.UUID.UUIDString;
    DTXIPCConnection* server = [[DTXIPCConnection alloc] initWithServiceName:service];
    server.exportedInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    server.exportedObject = [IPCLiveAsyncReplyPeer new];
    [server resume];
    DTXIPCConnection* client = [[DTXIPCConnection alloc] initWithServiceName:service];
    client.remoteObjectInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    [client resume];
    __block NSInteger errors = 0;
    __block NSInteger replies = 0;
    id<IPCFailureFixtureProtocol> proxy = [client synchronousRemoteObjectProxyWithErrorHandler:^(NSError* error) { errors += 1; }];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    NSInteger requests = 0;
    while (requests < 1000 && errors == 0 && deadline.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            [proxy requestWithReply:^{ replies += 1; }];
            requests += 1;
        }
    }
    [client invalidate];
    [server invalidate];
    XCTAssertEqual(errors, 0);
    XCTAssertEqual(requests, 1000);
    XCTAssertEqual(replies, requests);
}

- (void)testLiveNSConnectionCleanupCannotOvertakeDeferredCallbackAcquisition
{
    NSString* service = NSUUID.UUID.UUIDString;
    DTXIPCConnection* server = [[DTXIPCConnection alloc] initWithServiceName:service];
    server.exportedInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    server.exportedObject = [IPCLiveAsyncReplyPeer new];
    [server resume];
    IPCDeferredDeliveryConnection* client = [[IPCDeferredDeliveryConnection alloc] initWithServiceName:service];
    client.remoteObjectInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    [client resume];

    XCTestExpectation* requestFinished = [self expectationWithDescription:@"request finished"];
    XCTestExpectation* gateFinished = [self expectationWithDescription:@"receiver gate observed"];
    __block NSInteger errors = 0;
    __block NSInteger replies = 0;
    __block BOOL deliveryWasEntered = NO;
    __block BOOL cleanupOvertookDelivery = NO;
    id<IPCFailureFixtureProtocol> proxy = [client synchronousRemoteObjectProxyWithErrorHandler:^(NSError* error) { errors += 1; }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [proxy requestWithReply:^{ replies += 1; }];
        [requestFinished fulfill];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        deliveryWasEntered = dispatch_semaphore_wait(client.deliveryEntered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
        if (deliveryWasEntered) {
            // This bounded test-only gate amplifies message reordering; production
            // transport must hold ownership rather than depend on this interval.
            cleanupOvertookDelivery = dispatch_semaphore_wait(client.cleanupReceived, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) == 0;
        }
        dispatch_semaphore_signal(client.allowDelivery);
        [gateFinished fulfill];
    });
    [self waitForExpectations:@[requestFinished, gateFinished] timeout:10];
    [client invalidate];
    [server invalidate];
    XCTAssertTrue(deliveryWasEntered);
    XCTAssertFalse(cleanupOvertookDelivery, @"Callback cleanup must wait until the receiver has acquired delivery ownership");
    XCTAssertEqual(errors, 0);
    XCTAssertEqual(replies, 1);
}

- (void)testReceiptDoesNotWaitForAsyncCallbackAndInvocationSurvivesCleanup
{
    IPCRegressionConnection* connection = [[IPCRegressionConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    dispatch_semaphore_t callbackEntered = dispatch_semaphore_create(0);
    dispatch_semaphore_t allowCallback = dispatch_semaphore_create(0);
    XCTestExpectation* delivered = [self expectationWithDescription:@"asynchronous callback completed"];
    __weak NSObject* weakToken = nil;
    NSString* identifier = nil;
    @autoreleasepool {
        NSObject* token = [NSObject new];
        weakToken = token;
        identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{
            XCTAssertNotNil(token);
            dispatch_semaphore_signal(callbackEntered);
            dispatch_semaphore_wait(allowCallback, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            [delivered fulfill];
        } distantObject:nil];
    }
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    XCTAssertTrue([connection _invokeRemoteBlock:[self invocationForIdentifier:identifier]]);
    XCTAssertLessThan(NSProcessInfo.processInfo.systemUptime - started, 2.0, @"Receipt must not wait for the callback body");
    XCTAssertEqual(dispatch_semaphore_wait(callbackEntered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0l);
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    XCTAssertNil([_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier]);
    XCTAssertNotNil(weakToken, @"Transferred invocation must retain the callback across registry cleanup");
    dispatch_semaphore_signal(allowCallback);
    [self waitForExpectations:@[delivered] timeout:5];
    XCTestExpectation* released = [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
        return weakToken == nil;
    }] evaluatedWithObject:connection handler:nil];
    [self waitForExpectations:@[released] timeout:5];
    [connection invalidate];
}

- (void)testLiveAsyncCallbackCanMakeNestedSynchronousRequest
{
    NSString* service = NSUUID.UUID.UUIDString;
    DTXIPCConnection* server = [[DTXIPCConnection alloc] initWithServiceName:service];
    server.exportedInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    server.exportedObject = [IPCLiveAsyncReplyPeer new];
    [server resume];
    DTXIPCConnection* client = [[DTXIPCConnection alloc] initWithServiceName:service];
    client.remoteObjectInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(IPCFailureFixtureProtocol)];
    [client resume];
    __block NSInteger errors = 0;
    __block NSInteger replies = 0;
    void (^onError)(NSError*) = ^(NSError* error) { @synchronized (client) { errors += 1; } };
    id<IPCFailureFixtureProtocol> asynchronous = [client remoteObjectProxyWithErrorHandler:onError];
    id<IPCFailureFixtureProtocol> synchronous = [client synchronousRemoteObjectProxyWithErrorHandler:onError];
    XCTestExpectation* nestedReply = [self expectationWithDescription:@"nested synchronous reply from async callback"];
    [asynchronous requestWithReply:^{
        [synchronous requestWithReply:^{ replies += 1; }];
        [nestedReply fulfill];
    }];
    [self waitForExpectations:@[nestedReply] timeout:10];
    [client invalidate];
    [server invalidate];
    XCTAssertEqual(errors, 0);
    XCTAssertEqual(replies, 1);
}

- (void)testRejectedCallbackReceiptInvalidatesSenderWithExplicitError
{
    IPCFailureFixtureConnection* connection = [[IPCFailureFixtureConnection alloc] initWithServiceName:NSUUID.UUID.UUIDString];
    connection.fixtureValid = YES;
    connection.fixturePeer = [IPCFailureFixturePeer new];
    connection.fixturePeer.owner = connection;
    connection.fixturePeer.rejectCallbackDelivery = YES;
    IPCForwardingBlockReceiver* receiver = [IPCForwardingBlockReceiver new];
    void (^reply)(void) = ^{ XCTFail(@"Rejected callback must not be invoked"); };
    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[receiver methodSignatureForSelector:@selector(captureReply:)]];
    invocation.selector = @selector(captureReply:);
    [invocation setArgument:&reply atIndex:2];
    NSDictionary* serialized = [invocation _dtx_serializedDictionaryForDistantObject:nil];
    NSString* identifier = serialized[@"arguments"][2][@"remoteIdentifier"];
    id exported = [_DTXIPCExportedObject _exportedObjectWithObject:receiver connection:connection serializedInvocation:serialized];
    [exported invoke];
    receiver.reply();
    XCTAssertFalse(connection.fixtureValid);
    XCTAssertEqualObjects(connection.failureError.domain, DTXIPCErrorDomain);
    XCTAssertEqual(connection.failureError.code, 4);
    XCTAssertTrue([connection.failureError.localizedDescription containsString:@"not accepted"]);
    XCTAssertNoThrow(receiver.reply = nil, @"Rejected delivery cleanup must tolerate the invalidated connection");
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
}

- (void)testLifetimeHistoryPreservesRemovalBeforeMissingDelivery
{
    XCTAssertTrue([_DTXIPCRemoteBlockRegistry lifetimeTracingEnabled]);
    NSString* identifier = [_DTXIPCRemoteBlockRegistry registerRemoteBlock:^{} distantObject:nil];
    [_DTXIPCRemoteBlockRegistry releaseRemoteBlock:identifier];
    XCTAssertNil([_DTXIPCRemoteBlockRegistry snapshotForIdentifier:identifier]);
    NSDictionary* history = [_DTXIPCRemoteBlockRegistry lifetimeHistoryForIdentifier:identifier];
    NSArray* events = history[@"events"];
    XCTAssertEqualObjects([events valueForKey:@"event"], (@[@"registered", @"released", @"removed", @"snapshot_miss"]));
    XCTAssertEqualObjects([events valueForKey:@"value"], (@[@1, @0, @0, @0]));
    uint64_t previous = 0;
    for (NSDictionary* event in events) {
        XCTAssertGreaterThan([event[@"sequence"] unsignedLongLongValue], previous);
        XCTAssertGreaterThan([event[@"monotonic_raw_ns"] unsignedLongLongValue], 0ull);
        XCTAssertEqualObjects(event[@"callback_id"], identifier);
        XCTAssertEqualObjects(event[@"identifier_truncated"], @NO);
        previous = [event[@"sequence"] unsignedLongLongValue];
    }
}

- (void)testLifetimeHistoryHasExplicitRingAndDumpBounds
{
    NSString* identifier = NSUUID.UUID.UUIDString;
    for (NSInteger index = 0; index < 1100; index++) {
        [_DTXIPCRemoteBlockRegistry recordLifetimeEvent:"bounded_fixture" identifier:identifier value:index];
    }
    NSDictionary* history = [_DTXIPCRemoteBlockRegistry lifetimeHistoryForIdentifier:identifier];
    NSArray* events = history[@"events"];
    XCTAssertEqualObjects(history[@"enabled"], @YES);
    XCTAssertEqualObjects(history[@"capacity"], @1024);
    XCTAssertGreaterThan([history[@"overwritten_entries"] integerValue], 0);
    XCTAssertEqual([history[@"omitted_matching_entries"] integerValue], 960);
    XCTAssertEqual(events.count, 64u);
    XCTAssertEqualObjects(events.firstObject[@"value"], @1036);
    XCTAssertEqualObjects(events.lastObject[@"value"], @1099);
    XCTAssertEqualObjects(events.lastObject[@"sequence"], history[@"last_sequence"]);
}

@end
