//
//  _DTXIPCRemoteBlockRegistry.m
//  DetoxIPC
//
//  Created by Leo Natan (Wix) on 9/25/19.
//  Copyright © 2019 LeoNatan. All rights reserved.
//

/***
*    ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗
*    ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝
*    ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗
*    ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║
*    ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝
*     ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝
*
*
* WARNING: This file compiles with ARC disabled! Take extra care when modifying or adding functionality.
*/

#import "_DTXIPCRemoteBlockRegistry.h"
#import "_DTXIPCDistantObject.h"
#import "../DTXObjectiveCHelpers/Swiftier.h"
@import ObjectiveC;
@import Darwin;

@interface _DTXIPCRemoteBlockSnapshot ()
@property (nonatomic) NSInteger blockRetainCount;
- (instancetype)initWithBlock:(id)block distantObject:(_DTXIPCDistantObject*)distantObject;
@end

@implementation _DTXIPCRemoteBlockSnapshot
{
    dispatch_group_t _replyGroup;
}
- (instancetype)initWithBlock:(id)block distantObject:(_DTXIPCDistantObject*)distantObject
{
    self = [super init];
    if (self) {
        _block = _Block_copy(block);
        _distantObject = [distantObject retain];
        _blockRetainCount = 1;
        _replyGroup = [_distantObject _enterReplyGroup];
        if (_replyGroup) { dispatch_retain(_replyGroup); }
    }
    return self;
}

- (void)dealloc
{
    // A callback acquired before cleanup must be enqueued before its caller resumes.
    if (_replyGroup) {
        dispatch_group_leave(_replyGroup);
        dispatch_release(_replyGroup);
    }
    _Block_release(_block);
    [_distantObject release];
    [super dealloc];
}
@end

pthread_mutex_t _registryMutex;

static NSMutableDictionary* _registry;

@implementation _DTXIPCRemoteBlockRegistry

+ (void)load
{
	@autoreleasepool
	{
		_registry = [NSMutableDictionary new];
		pthread_mutex_init(&_registryMutex, NULL);
	}
}

+ (NSString*)registerRemoteBlock:(id)block distantObject:(_DTXIPCDistantObject*)distantObject
{
    NSString* identifier = [NSUUID UUID].UUIDString;
    _DTXIPCRemoteBlockSnapshot* entry = [[_DTXIPCRemoteBlockSnapshot alloc] initWithBlock:block distantObject:distantObject];
    pthread_mutex_lock(&_registryMutex);
    _registry[identifier] = entry;
    pthread_mutex_unlock(&_registryMutex);
    [entry release];
    return identifier;
}

+ (_DTXIPCRemoteBlockSnapshot*)snapshotForIdentifier:(NSString*)identifier
{
    pthread_mutex_lock(&_registryMutex);
    _DTXIPCRemoteBlockSnapshot* entry = [[_registry objectForKey:identifier] retain];
    pthread_mutex_unlock(&_registryMutex);
    return [entry autorelease];
}

+ (id)remoteBlockForIdentifier:(NSString*)identifier distantObject:(_DTXIPCDistantObject* __nullable * __nullable)distantObject
{
    _DTXIPCRemoteBlockSnapshot* snapshot = [self snapshotForIdentifier:identifier];
    if (distantObject != NULL) {
        *distantObject = snapshot.distantObject;
    }
    return snapshot.block;
}

+ (oneway void)retainRemoteBlock:(NSString*)identifier
{
	pthread_mutex_lock_deferred_unlock(&_registryMutex);
	
	_DTXIPCRemoteBlockSnapshot* entry = [_registry objectForKey:identifier];
	entry.blockRetainCount += 1;
}

+ (oneway void)releaseRemoteBlock:(NSString*)identifier
{
    _DTXIPCRemoteBlockSnapshot* retired = nil;
    pthread_mutex_lock(&_registryMutex);
    _DTXIPCRemoteBlockSnapshot* entry = [_registry objectForKey:identifier];
    if (entry != nil && --entry.blockRetainCount == 0) {
        retired = [entry retain];
        [_registry removeObjectForKey:identifier];
    }
    pthread_mutex_unlock(&_registryMutex);
    // Block destruction and reply completion must never run while holding the registry lock.
    [retired release];
}

@end
