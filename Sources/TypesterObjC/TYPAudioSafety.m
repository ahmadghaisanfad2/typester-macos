#import "TYPAudioSafety.h"

NSErrorDomain const TYPAudioSafetyErrorDomain = @"com.typester.audio-safety";

static NSError *TYPErrorFromException(NSException *exception) {
    NSString *reason = exception.reason ?: exception.name;
    return [NSError errorWithDomain:TYPAudioSafetyErrorDomain
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey : reason,
                               @"exceptionName" : exception.name,
                           }];
}

@implementation TYPAudioSafety

+ (nullable AVAudioInputNode *)inputNodeOfEngine:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        return engine.inputNode;
    } @catch (NSException *exception) {
        if (error) { *error = TYPErrorFromException(exception); }
        return nil;
    }
}

+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        return [engine startAndReturnError:error];
    } @catch (NSException *exception) {
        if (error) { *error = TYPErrorFromException(exception); }
        return NO;
    }
}

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(nullable AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError **)error {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error) { *error = TYPErrorFromException(exception); }
        return NO;
    }
}

@end
