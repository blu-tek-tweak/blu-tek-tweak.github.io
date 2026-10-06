#import <UIKit/UIKit.h>
#import "WaveTable.h"

NS_ASSUME_NONNULL_BEGIN

@interface WaveEngine : NSObject

// Device idiom + orientation. Set before playWithPullVelocity:. The engine uses
// these to pick the correct wave table (iPhone 4x6 vs iPad 5x6 horizontal/vertical)
// and grid center. Defaults to iPhone / vertical.
@property (nonatomic, assign) BOOL isPad;
@property (nonatomic, assign) WaveOrientation orientation;

- (void)registerIcon:(UIView *)view col:(NSInteger)col row:(NSInteger)row;
- (void)clearIcons;
- (void)setDockView:(nullable UIView *)dock;

- (void)playWithPullVelocity:(CGFloat)velocity;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
