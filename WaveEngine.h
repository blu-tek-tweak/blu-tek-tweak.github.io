#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveEngine : NSObject

- (void)registerButton:(UIView *)view col:(NSInteger)col row:(NSInteger)row;
- (void)clearButtons;

// Play the center-out zoom+bounce fly-in for all registered buttons.
- (void)play;

// Remove any in-flight animations.
- (void)reset;

// Start suppressing the native fly-in animation on the given views.
// The native animator re-adds animations every frame, so we need to keep
// killing them for the duration of our animation.
- (void)startNativeAnimationSuppression:(NSArray<UIView *> *)views;

@end

NS_ASSUME_NONNULL_END
