#import "WaveEngine.h"
#import "WaveTable.h"
#import <objc/runtime.h>

#pragma mark - Tuning

// Spring for every button. Damping ~0.95 of critical gives a subtle,
// graceful overshoot (the "bounce") before settling at the home position.
static const CGFloat kStiffness = 200.0;
static const CGFloat kMass      = 1.0;
static const CGFloat kDamping   = 15.0;

// The 0 button (bottom-center, col=1, row=3) gets a softer spring.
static const CGFloat kZeroStiffness = 150.0;
static const CGFloat kZeroDamping   = 12.0;

// The fly-in starts at a small scale (zoomed OUT) and springs in to 1.0.
static const CGFloat kStartZoom = 0.15;

// Every button starts at the same magnification of the pad's center, so the
// wave reads as a uniform "zoom out from the center" entrance.
static NSString * const kKeyPos   = @"passcode.pos";
static NSString * const kKeyScale = @"passcode.scale";

#pragma mark -

@interface WaveButton : NSObject
@property (nonatomic, weak)   UIView *view;
@property (nonatomic, assign) NSInteger col;
@property (nonatomic, assign) NSInteger row;
@end

@implementation WaveButton
@end

@interface WaveEngine ()
@property (nonatomic, strong) NSMutableArray<WaveButton *> *buttons;
@property (nonatomic, assign) CFTimeInterval sharedNow;
@end

@implementation WaveEngine

- (instancetype)init {
    if ((self = [super init])) {
        _buttons = [NSMutableArray array];
    }
    return self;
}

- (void)registerButton:(UIView *)view col:(NSInteger)col row:(NSInteger)row {
    if (!view) return;
    if (![WaveTable isValidCol:col row:row]) return;
    // Re-registering the same view (every presentation) updates the existing
    // entry instead of appending, so the array stays bounded.
    for (WaveButton *existing in self.buttons) {
        if (existing.view == view) {
            existing.col = col;
            existing.row = row;
            return;
        }
    }
    WaveButton *b = [[WaveButton alloc] init];
    b.view = view;
    b.col = col;
    b.row = row;
    [self.buttons addObject:b];
}

- (void)clearButtons {
    [self.buttons removeAllObjects];
}

- (void)play {
    if (self.buttons.count == 0) return;

    // Capture "now" ONCE, in the first button's layer time base, and use it for
    // every button. animateButton is called sequentially in a loop; a per-call
    // CACurrentMediaTime() would advance the clock across the loop and make
    // same-wave buttons start at different points.
    UIView *refView = nil;
    for (WaveButton *b in self.buttons) {
        if (b.view && b.view.window) { refView = b.view; break; }
    }
    if (refView) {
        self.sharedNow = [refView.layer convertTime:CACurrentMediaTime() fromLayer:nil];
    } else {
        self.sharedNow = CACurrentMediaTime();
    }

    for (WaveButton *b in self.buttons) {
        [self animateButton:b];
    }
}

- (void)animateButton:(WaveButton *)b {
    UIView *view = b.view;
    CALayer *layer = view.layer;
    if (!view || !layer || !view.superview || !view.window) return;

    NSInteger wave = [WaveTable waveForCol:b.col row:b.row];
    if (wave < 1) return;

    // Lower wave numbers get higher z-positions (appear on top).
    // Wave 1 = topmost, wave 4 = bottommost.
    layer.zPosition = 100.0 - (wave * 10.0);

    CGPoint home = layer.position;
    CATransform3D homeTransform = layer.transform;

    // The pad's center in the layer's superlayer coordinate space.
    // Walk up to find the passcode pad (SBUIPasscodeLockViewSimpleFixedDigitKeypad)
    // and use its center as the zoom origin.
    UIView *pad = view;
    while (pad) {
        NSString *cls = [NSString stringWithUTF8String:class_getName(object_getClass((id)pad))];
        if ([cls isEqualToString:@"SBUIPasscodeLockViewSimpleFixedDigitKeypad"]) {
            break;
        }
        pad = pad.superview;
    }
    if (!pad) pad = view.window;
    CGRect padBounds = [pad convertRect:pad.bounds toView:view.superview];
    CGPoint cameraCenter = CGPointMake(CGRectGetMidX(padBounds), CGRectGetMidY(padBounds));

    // Zoom-in start: the same magnification of the screen center for every
    // button, so the wave is a uniform "zoom out from the center".
    CGPoint start = CGPointMake(cameraCenter.x + (home.x - cameraCenter.x) * kStartZoom,
                                cameraCenter.y + (home.y - cameraCenter.y) * kStartZoom);
    CATransform3D startTransform = CATransform3DScale(homeTransform, kStartZoom, kStartZoom, 1.0);

    CFTimeInterval beginAt = self.sharedNow + [WaveTable delayForWave:wave];

    // The 0 button (col=1, row=3) gets a softer, bouncier spring.
    BOOL isZero = (b.col == 1 && b.row == 3);
    CGFloat stiffness = isZero ? kZeroStiffness : kStiffness;
    CGFloat damping   = isZero ? kZeroDamping   : kDamping;

    CASpringAnimation *pos = [CASpringAnimation animationWithKeyPath:@"position"];
    pos.fromValue = [NSValue valueWithCGPoint:start];
    pos.toValue   = [NSValue valueWithCGPoint:home];
    pos.damping   = damping;
    pos.stiffness = stiffness;
    pos.mass      = kMass;
    pos.duration  = pos.settlingDuration;
    pos.beginTime = beginAt;
    pos.fillMode  = kCAFillModeBackwards;
    pos.removedOnCompletion = YES;
    [layer addAnimation:pos forKey:kKeyPos];

    // Identical spring parameters and start time keep position and scale in
    // lockstep: P(t) = C + zoom(t) * (home - C).
    CASpringAnimation *scl = [CASpringAnimation animationWithKeyPath:@"transform"];
    scl.fromValue = [NSValue valueWithCATransform3D:startTransform];
    scl.toValue   = [NSValue valueWithCATransform3D:homeTransform];
    scl.damping   = damping;
    scl.stiffness = stiffness;
    scl.mass      = kMass;
    scl.duration  = pos.duration;
    scl.beginTime = beginAt;
    scl.fillMode  = kCAFillModeBackwards;
    scl.removedOnCompletion = YES;
    [layer addAnimation:scl forKey:kKeyScale];
}

#pragma mark - Cleanup

- (void)reset {
    for (WaveButton *b in self.buttons) {
        if (!b.view) continue;
        [b.view.layer removeAnimationForKey:kKeyPos];
        [b.view.layer removeAnimationForKey:kKeyScale];
    }
}

#pragma mark - Native animation suppression

- (void)startNativeAnimationSuppression:(NSArray<UIView *> *)views {
    // The native fly-in animator re-adds animations every frame. We need to
    // keep killing them for the duration of our animation. Use a dispatch
    // source timer on the main queue to strip animations every frame.
    // IMPORTANT: Only remove animations that aren't ours (kKeyPos, kKeyScale).
    if (views.count == 0) return;

    // Kill the native animations immediately (but keep ours).
    for (UIView *v in views) {
        [self removeNativeAnimationsFromLayer:v.layer];
    }

    // Keep killing them for 1.5s (the max settling time of our spring).
    __block int ticks = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 16 * 1000 * 1000, 0); // ~60fps
    dispatch_source_set_event_handler(timer, ^{
        ticks++;
        if (ticks > 90) { // ~1.5s at 60fps
            dispatch_source_cancel(timer);
            return;
        }
        for (UIView *v in views) {
            if (v.window) {
                [self removeNativeAnimationsFromLayer:v.layer];
            }
        }
    });
    dispatch_resume(timer);
}

- (void)removeNativeAnimationsFromLayer:(CALayer *)layer {
    // Remove all animations EXCEPT ours (kKeyPos, kKeyScale).
    NSArray *keys = [layer animationKeys];
    for (NSString *key in keys) {
        if (![key isEqualToString:kKeyPos] && ![key isEqualToString:kKeyScale]) {
            [layer removeAnimationForKey:key];
        }
    }
}

@end
