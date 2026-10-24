//
//  DTXIPCConnection-Private.h
//  DetoxIPC
//
//  Created by Leo Natan (Wix) on 9/25/19.
//  Copyright © 2019 LeoNatan. All rights reserved.
//

#import "DTXIPCConnection.h"

@protocol _DTXIPCImpl <NSObject>

- (oneway void)_slaveDidConnectWithName:(NSString*)slaveServiceName;
- (oneway void)_invokeFromRemote:(NSDictionary*)serializedInvocation;
// Receipt is returned after callback ownership has transferred to the receiver.
- (BOOL)_invokeRemoteBlock:(NSDictionary*)serializedBlock;
- (oneway void)_cleanupRemoteBlock:(NSString*)identifier;
- (oneway void)_dumpRemoteBlockHistory:(NSString*)identifier;
- (BOOL)_ping;

@end

@interface DTXIPCConnection ()

@property (readonly, getter=isValid) BOOL valid;
@property (atomic, strong, nullable) NSError* failureError;
- (void)_failWithMissingRemoteBlock:(nullable NSString*)identifier;

@property (nonatomic, getter=isSlave) BOOL slave;

@property (nonatomic, strong) NSConnection* connection;
@property (nonatomic, strong) NSConnection* otherConnection;

@end
