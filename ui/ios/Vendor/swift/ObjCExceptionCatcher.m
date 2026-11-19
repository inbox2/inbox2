#import "ObjCExceptionCatcher.h"

NSString * _Nullable Inbox2CatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
    }
}
