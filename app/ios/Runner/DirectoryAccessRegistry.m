#import "DirectoryAccessRegistry.h"
#import <string.h>

@interface LSDirectoryLease : NSObject
@property (nonatomic, strong) NSURL *originalURL;
@property (nonatomic) NSUInteger refCount;
@end

@implementation LSDirectoryLease
@end

static NSMutableDictionary<NSString *, LSDirectoryLease *> *leases;

static NSString *LSValidatedToken(const char *token) {
    if (token == NULL || strnlen(token, 37) != 36) return nil;
    return [[NSString alloc] initWithBytes:token length:36 encoding:NSASCIIStringEncoding];
}

NSString *LSInsertDirectoryLease(NSURL *originalURL) {
    LSDirectoryLease *lease = [[LSDirectoryLease alloc] init];
    lease.originalURL = originalURL;
    lease.refCount = 1;
    NSString *token;
    @synchronized([LSDirectoryLease class]) {
        if (leases == nil) leases = [[NSMutableDictionary alloc] init];
        do {
            token = [NSUUID UUID].UUIDString;
        } while (leases[token] != nil);
        leases[token] = lease;
    }
    return token;
}

bool localsend_directory_access_retain_v1(const char *token, const char *expected_root_path) {
    @autoreleasepool {
        NSString *key = LSValidatedToken(token);
        if (key == nil || expected_root_path == NULL) return false;
        size_t length = strnlen(expected_root_path, 4097);
        if (length == 0 || length > 4096 || expected_root_path[0] != '/') return false;
        NSString *path = [[NSString alloc] initWithBytes:expected_root_path length:length encoding:NSUTF8StringEncoding];
        if (path == nil) return false;
        BOOL valid;
        @synchronized([LSDirectoryLease class]) {
            LSDirectoryLease *lease = leases[key];
            valid = lease != nil && lease.refCount < NSUIntegerMax &&
                    [lease.originalURL.path isEqualToString:path];
            if (valid) lease.refCount++;
        }
        return valid;
    }
}

void localsend_directory_access_release_v1(const char *token) {
    @autoreleasepool {
        NSString *key = LSValidatedToken(token);
        if (key == nil) return;
        NSURL *urlToStop = nil;
        @synchronized([LSDirectoryLease class]) {
            LSDirectoryLease *lease = leases[key];
            if (lease != nil) {
                lease.refCount--;
                if (lease.refCount == 0) {
                    urlToStop = lease.originalURL;
                    [leases removeObjectForKey:key];
                }
            }
        }
        if (urlToStop != nil) [urlToStop stopAccessingSecurityScopedResource];
    }
}
