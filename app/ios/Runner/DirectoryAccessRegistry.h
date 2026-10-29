#import <Foundation/Foundation.h>
#include <stdbool.h>

// Insert only after starting access on the original picker URL. Owns one reference.
NSString * _Nonnull LSInsertDirectoryLease(NSURL * _Nonnull originalURL);

// These process-local symbols are resolved by Rust with dlsym. Keep them even
// when the linker strips code without a static caller.
__attribute__((used, visibility("default"))) bool localsend_directory_access_retain_v1(
    const char * _Nullable token, const char * _Nullable expected_root_path);
__attribute__((used, visibility("default"))) void localsend_directory_access_release_v1(
    const char * _Nullable token);
