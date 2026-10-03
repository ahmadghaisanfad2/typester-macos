#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const TYPAudioSafetyErrorDomain;

/// AVFAudio reports misuse and device races by raising Objective-C exceptions,
/// which Swift cannot catch and which abort the process. These wrappers make
/// the raising calls in Objective-C and hand back an NSError instead, so no
/// exception ever unwinds through Swift frames.
@interface TYPAudioSafety : NSObject

+ (nullable AVAudioInputNode *)inputNodeOfEngine:(AVAudioEngine *)engine
                                           error:(NSError **)error
    NS_SWIFT_NAME(inputNode(of:));

+ (BOOL)startEngine:(AVAudioEngine *)engine
              error:(NSError **)error
    NS_SWIFT_NAME(start(_:));

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(nullable AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError **)error
    NS_SWIFT_NAME(installTap(on:bus:bufferSize:format:block:));

@end

NS_ASSUME_NONNULL_END
