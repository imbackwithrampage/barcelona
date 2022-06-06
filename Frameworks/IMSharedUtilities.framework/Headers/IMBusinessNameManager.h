//
//     Generated by class-dump 3.5 (64 bit).
//
//     class-dump is Copyright (C) 1997-1998, 2000-2001, 2004-2013 by Steve Nygard.
//

#import <Foundation/Foundation.h>

@class NSLock, NSMutableDictionary;

@interface IMBusinessNameManager : NSObject
{
    NSLock *_cacheLock;
    NSMutableDictionary *_cache;
    NSMutableDictionary *_pendingRequests;
}

+ (instancetype)sharedInstance;

@property(retain) NSMutableDictionary *pendingRequests; // @synthesize pendingRequests=_pendingRequests;
@property(retain) NSMutableDictionary *cache; // @synthesize cache=_cache;
@property(retain) NSLock *cacheLock; // @synthesize cacheLock=_cacheLock;
- (id)businessNameForUID:(id)arg1 updateHandler:(void (^)(NSString *name))arg2;
- (id)init;

@end

