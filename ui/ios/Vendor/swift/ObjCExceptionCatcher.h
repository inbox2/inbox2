#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Run `block`, catching any Objective-C NSException it raises — Swift's `try`/`try?`
/// only catch Swift errors, so an NSException out of a Cocoa API terminates the app.
/// Returns nil on success, or "name: reason" when an exception was caught. Used to
/// guard AVAudioEngine graph mutations (setVoiceProcessingEnabled and friends raise
/// from AVAudioEngineGraph::_Connect while the audio hardware/route is settling).
NSString * _Nullable Inbox2CatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
