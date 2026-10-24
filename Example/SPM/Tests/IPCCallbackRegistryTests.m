#import <XCTest/XCTest.h>
#import "../../../Sources/SBTUITestTunnelCommon/DetoxIPC/DTXIPCConnection.h"
#import "../../../Sources/SBTUITestTunnelCommon/DetoxIPC/fno-objc-arc/_DTXIPCRemoteBlockRegistry.h"
#import "../../../Sources/SBTUITestTunnelClient/include/SBTUITestTunnelClient.h"

@interface SBTUITestTunnelClient (ReplyContractTests)
- (NSString*)sendSynchronousRequestWithPath:(NSString*)path params:(NSDictionary*)params assertOnError:(BOOL)assertOnError;
@end

// These private interfaces belong to the same pinned package under test.
@interface DTXIPCConnection (CallbackRegistryTests)
- (oneway void)_invokeRemoteBlock:(NSDictionary*)serializedBlock;
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
@property (nonatomic) NSInteger requests;
@property (nonatomic, copy) NSString* heldIdentifier;
- (id)rootProxy;
- (oneway void)_invokeFromRemote:(NSDictionary*)invocation;
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

@end
