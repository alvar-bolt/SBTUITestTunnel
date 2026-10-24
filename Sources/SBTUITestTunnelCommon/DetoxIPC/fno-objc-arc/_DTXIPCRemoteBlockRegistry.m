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
#import <TargetConditionals.h>
#import <time.h>
@import ObjectiveC;
@import Darwin;

#if DEBUG && TARGET_OS_SIMULATOR
enum { DTXLifetimeCapacity = 1024, DTXLifetimeDumpLimit = 64 };
typedef struct {
    uint64_t sequence, monotonicNS, threadID;
    int64_t value;
    char event[32], identifier[64];
    BOOL identifierTruncated;
} DTXLifetimeEntry;
static DTXLifetimeEntry _lifetimeEntries[DTXLifetimeCapacity];
static uint64_t _lifetimeSequence;
static pthread_mutex_t _lifetimeMutex = PTHREAD_MUTEX_INITIALIZER;
#endif

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
    [self recordLifetimeEvent:"registered" identifier:identifier value:entry.blockRetainCount];
    pthread_mutex_unlock(&_registryMutex);
    [entry release];
    return identifier;
}

+ (_DTXIPCRemoteBlockSnapshot*)snapshotForIdentifier:(NSString*)identifier
{
    pthread_mutex_lock(&_registryMutex);
    _DTXIPCRemoteBlockSnapshot* entry = [[_registry objectForKey:identifier] retain];
    [self recordLifetimeEvent:entry ? "snapshot_hit" : "snapshot_miss" identifier:identifier value:entry.blockRetainCount];
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
    [self recordLifetimeEvent:entry ? "retained" : "retain_missing" identifier:identifier value:entry.blockRetainCount];
}

+ (oneway void)releaseRemoteBlock:(NSString*)identifier
{
    _DTXIPCRemoteBlockSnapshot* retired = nil;
    pthread_mutex_lock(&_registryMutex);
    _DTXIPCRemoteBlockSnapshot* entry = [_registry objectForKey:identifier];
    if (entry != nil) { --entry.blockRetainCount; }
    [self recordLifetimeEvent:entry ? "released" : "release_missing" identifier:identifier value:entry.blockRetainCount];
    if (entry != nil && entry.blockRetainCount == 0) {
        retired = [entry retain];
        [_registry removeObjectForKey:identifier];
        [self recordLifetimeEvent:"removed" identifier:identifier value:0];
    }
    pthread_mutex_unlock(&_registryMutex);
    // Block destruction and reply completion must never run while holding the registry lock.
    [retired release];
}

+ (BOOL)lifetimeTracingEnabled
{
#if DEBUG && TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

+ (void)recordLifetimeEvent:(const char*)event identifier:(NSString*)identifier value:(NSInteger)value
{
#if DEBUG && TARGET_OS_SIMULATOR
    // No callback/owner references, logging, symbol lookup, or unbounded allocation.
    DTXLifetimeEntry entry = {0};
    strlcpy(entry.event, event, sizeof(entry.event));
    entry.identifierTruncated = strlcpy(entry.identifier, (identifier ?: @"<missing>").UTF8String,
                                       sizeof(entry.identifier)) >= sizeof(entry.identifier);
    entry.value = value;
    pthread_threadid_np(NULL, &entry.threadID);
    pthread_mutex_lock(&_lifetimeMutex);
    struct timespec time = {0};
    clock_gettime(CLOCK_MONOTONIC_RAW, &time);
    entry.monotonicNS = (uint64_t)time.tv_sec * NSEC_PER_SEC + time.tv_nsec;
    entry.sequence = ++_lifetimeSequence;
    _lifetimeEntries[(entry.sequence - 1) % DTXLifetimeCapacity] = entry;
    pthread_mutex_unlock(&_lifetimeMutex);
#endif
}

+ (NSDictionary*)lifetimeHistoryForIdentifier:(NSString*)identifier
{
#if DEBUG && TARGET_OS_SIMULATOR
    char key[64] = {0};
    strlcpy(key, (identifier ?: @"<missing>").UTF8String, sizeof(key));
    DTXLifetimeEntry selected[DTXLifetimeDumpLimit] = {0};
    NSUInteger selectedCount = 0, matchingCount = 0;
    pthread_mutex_lock(&_lifetimeMutex);
    uint64_t last = _lifetimeSequence;
    uint64_t first = last > DTXLifetimeCapacity ? last - DTXLifetimeCapacity + 1 : (last ? 1 : 0);
    for (uint64_t sequence = last; first && sequence >= first; sequence--) {
        DTXLifetimeEntry entry = _lifetimeEntries[(sequence - 1) % DTXLifetimeCapacity];
        if (strcmp(entry.identifier, key) != 0) { continue; }
        matchingCount++;
        if (selectedCount < DTXLifetimeDumpLimit) { selected[selectedCount++] = entry; }
    }
    pthread_mutex_unlock(&_lifetimeMutex);
    NSMutableArray* events = [NSMutableArray arrayWithCapacity:selectedCount];
    for (NSUInteger index = selectedCount; index > 0; index--) {
        DTXLifetimeEntry entry = selected[index - 1];
        [events addObject:@{@"sequence": @(entry.sequence), @"monotonic_raw_ns": @(entry.monotonicNS),
                           @"thread_id": @(entry.threadID), @"event": @(entry.event),
                           @"callback_id": @(entry.identifier), @"value": @(entry.value),
                           @"identifier_truncated": @(entry.identifierTruncated)}];
    }
    return @{@"enabled": @YES, @"pid": @(getpid()), @"capacity": @(DTXLifetimeCapacity),
             @"first_retained_sequence": @(first), @"last_sequence": @(last),
             @"overwritten_entries": @(last > DTXLifetimeCapacity ? last - DTXLifetimeCapacity : 0),
             @"omitted_matching_entries": @(matchingCount - selectedCount), @"events": events};
#else
    return @{@"enabled": @NO, @"events": @[]};
#endif
}

+ (void)dumpLifetimeHistoryForIdentifier:(NSString*)identifier reason:(NSString*)reason
{
#if DEBUG && TARGET_OS_SIMULATOR
    NSDictionary* history = [self lifetimeHistoryForIdentifier:identifier];
    NSString* dumpID = NSUUID.UUID.UUIDString;
    NSMutableDictionary* header = [[history mutableCopy] autorelease];
    [header removeObjectForKey:@"events"];
    header[@"event"] = @"history_started";
    header[@"dump_id"] = dumpID;
    header[@"callback_id"] = identifier ?: @"<missing>";
    header[@"reason"] = reason;
    header[@"wall_time_s"] = @(NSDate.date.timeIntervalSince1970);
    header[@"anchor_before_uptime_s"] = @(NSProcessInfo.processInfo.systemUptime);
    header[@"anchor_monotonic_raw_ns"] = @(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW));
    header[@"anchor_after_uptime_s"] = @(NSProcessInfo.processInfo.systemUptime);
    header[@"clock"] = @"CLOCK_MONOTONIC_RAW";
    void (^emit)(NSDictionary*) = ^(NSDictionary* value) {
        NSData* data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
        NSString* line = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        NSLog(@"[DTXIPC_LIFETIME] %@", line);
    };
    emit(header);
    for (NSDictionary* event in history[@"events"]) {
        emit(@{@"event": @"history_entry", @"dump_id": dumpID, @"pid": @(getpid()), @"entry": event});
    }
    emit(@{@"event": @"history_finished", @"dump_id": dumpID, @"pid": @(getpid()),
           @"entries": @([history[@"events"] count])});
#endif
}

@end
