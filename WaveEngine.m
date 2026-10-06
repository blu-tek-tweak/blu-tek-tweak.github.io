#import "WaveEngine.h"
#import "WaveTable.h"

#pragma mark - Tuning

static const CGFloat kSpringStiffness  = 155.0;
static const CGFloat kSpringMass       = 1.5;
static const CGFloat kSpringDamping    = 22.0;
static const CGFloat kSpringVelocity   = 0.0;

// The first N waves (center-out) should land with almost no bounce AND be fast.
// A stiffer spring settles quickly; damping at ~92% of critical keeps overshoot
// to ~0.07% (invisible) while staying snappy.
static const NSInteger kNoBounceWaves     = 3;
static const CGFloat   kNoBounceStiffness = 300.0;  // fast take-off + quick settle

// Waves 7..8 (outermost): iOS-26-style SLOW, DEEP settle. A soft spring (low
// stiffness) gives a low natural frequency -> slow, floaty motion. Damping a bit
// below critical (z~0.78) gives a SMALL graceful overshoot ("deep settle") rather
// than the big bounce before. The real overshoot killer is initialVelocity (see
// kOuterStartVelocity) -> dropped so the give comes from the spring, not momentum.
// Waves 7..8 (outermost): the BOUNCIEST ring. Softer stiffness -> slower bounce,
// and damping well below critical (z~0.68) gives a clear, deep give.
// Waves 8..9 (outermost): SLOWER but LESS DEEP. Lower stiffness drops the natural
// frequency -> slower, floatier motion; higher damping (closer to critical) makes
// the overshoot smaller -> a shallower give. Was stiffness 55 / damping 12-14.
static const CGFloat kOuterWaveStiffness  = 38.0;   // softer -> slower bounce
static const CGFloat kOuterWaveDampingMin = 10.6;   // fastest pull (z~0.70)
static const CGFloat kOuterWaveDampingMax = 11.5;   // slowest pull (z~0.76)
// Waves 4..7 (mid-outer): share ONE damping range (identical bounce feel). Only
// their STIFFNESS differs (4..5 slightly stiffer than 6..7).
static const CGFloat kMidWaveStiffness    = 112.0;  // 4..5: bumped from 100 -> a touch faster
static const CGFloat kMidWave67Stiffness  = 112.0;  // 6..7: now equal to 4..5
static const CGFloat kMidWaveDampingMin   = 18.0;   // 4..7 fastest pull
static const CGFloat kMidWaveDampingMax   = 22.0;   // 4..7 slowest pull
// Pull speed (pts/s) at which p hits 1.0 -> minimum damping (bounciest). A faster
// flick is required to reach the min-damping end; a default ~1250 swipe sits at
// ~0.19 of the range.
static const CGFloat kPullVelocityFull  = 6500.0;

// Waves 1..3 get the SAME variable damping but MUCH narrower (centered on the
// base 45, +/-2) so the effect is barely noticeable on the center.
static const CGFloat kFirstWaveDampingMin = 34.0;   // fastest pull
static const CGFloat kFirstWaveDampingMax = 39.0;   // slowest pull

// Early waves (1..3) get a forward initial velocity so they launch quickly
// (start fast); the high damping then slows them into a soft stop (ease-out).
// CASpringAnimation's initialVelocity scale is far smaller than it looks —
// even 50 overshot the scale spring into negative (mirrored icon). Testing 12.
static const CGFloat kEarlyStartVelocity = 12.0;    // waves 1..3 only

// Waves 4..8: initialVelocity is NORMALIZED by the fly distance, so even a small
// number is a big launch — the old 12 flung the icons well past home, which is
// what read as "overshoots far too much". A small value lets the spring itself
// (stiffness+damping) shape the slow, deep settle instead of raw momentum.
static const CGFloat kOuterStartVelocity = 1.0;     // waves 4..8 (tiny; keeps scale from collapsing)

// One camera magnification for every icon. Size and distance from the camera
// center must use the same factor, regardless of grid cell or wave number.
static const CGFloat kCameraStartZoom = 4.50;

// Dock: fly up from below.
static const CGFloat kDockFlyDistance   = 380.0;

static const NSTimeInterval kWaveInterval = 0.055;

static NSString * const kKeyPos   = @"wave26.pos";
static NSString * const kKeyPosX  = @"wave26.posx";
static NSString * const kKeyPosY  = @"wave26.posy";
static NSString * const kKeyScale = @"wave26.scale";
static NSString * const kKeyDepth = @"wave26.depth";
static NSString * const kKeyDock  = @"wave26.dock";

#pragma mark -

@interface WaveIcon : NSObject
@property (nonatomic, weak)   UIView *view;
@property (nonatomic, assign) NSInteger col;
@property (nonatomic, assign) NSInteger row;
@end

@implementation WaveIcon
@end

@interface WaveEngine ()
@property (nonatomic, strong) NSMutableArray<WaveIcon *> *icons;
@property (nonatomic, weak)   UIView *dock;
@end

@implementation WaveEngine

- (instancetype)init {
    if ((self = [super init])) {
        _icons = [NSMutableArray array];
    }
    return self;
}

- (void)registerIcon:(UIView *)view col:(NSInteger)col row:(NSInteger)row {
    if (!view) return;
    if (![WaveTable isValidCol:col row:row isPad:self.isPad]) return;
    // Re-registering the same view (every unlock) updates the existing entry
    // instead of appending, so the array stays bounded to the live icon count.
    for (WaveIcon *existing in self.icons) {
        if (existing.view == view) {
            existing.col = col;
            existing.row = row;
            return;
        }
    }
    WaveIcon *ic = [[WaveIcon alloc] init];
    ic.view = view;
    ic.col = col;
    ic.row = row;
    [self.icons addObject:ic];
}

- (void)clearIcons {
    [self.icons removeAllObjects];
}

- (void)setDockView:(UIView *)dock {
    self.dock = dock;
}

- (void)playWithPullVelocity:(CGFloat)velocity {
    for (WaveIcon *ic in self.icons) {
        NSTimeInterval delay = [WaveTable delayForCol:ic.col row:ic.row
                                       waveInterval:(self.isPad ? 0.0 : kWaveInterval)
                                              isPad:self.isPad
                                         orientation:self.orientation];
        [self animateIcon:ic delay:delay pullVelocity:velocity];
    }
    [self animateDock:velocity];
}

- (CGFloat)dampingForIcon:(WaveIcon *)ic pullVelocity:(CGFloat)velocity {
    NSInteger wave = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];

    // Map pull speed to p in [0,1]: p=0 (slowest) -> max damping; p=1 (fastest)
    // -> min damping. p reaches 1.0 (min damping) only at kPullVelocityFull, so a
    // genuinely fast flick is needed before the bounciest (min-damping) end is
    // reached; ordinary swipes stay in the middle of the range.
    CGFloat speed = fabs(velocity);
    CGFloat p = MIN(1.0, speed / kPullVelocityFull);

    if (wave >= 1 && wave <= kNoBounceWaves) {
        // Waves 1..3: subtle variation around the base 45.
        return kFirstWaveDampingMax + (kFirstWaveDampingMin - kFirstWaveDampingMax) * p;
    }
    if (wave >= 8) {
        // Waves 8..9 (outermost ring): bounciest.
        return kOuterWaveDampingMax + (kOuterWaveDampingMin - kOuterWaveDampingMax) * p;
    }
    // Waves 4..7: identical damping (only stiffness differs between 4..5 and 6..7).
    return kMidWaveDampingMax + (kMidWaveDampingMin - kMidWaveDampingMax) * p;
}

- (CGFloat)stiffnessForIcon:(WaveIcon *)ic {
    NSInteger wave = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];
    if (wave >= 1 && wave <= kNoBounceWaves) return kNoBounceStiffness; // waves 1..3
    if (wave >= 8) return kOuterWaveStiffness;                          // waves 8..9: softer/slower bounce
    if (wave >= 6 && wave <= 7) return kMidWave67Stiffness;             // waves 6..7
    return kMidWaveStiffness;                                          // waves 4..5: slightly stiffer
}

- (CGFloat)initialVelocityForIcon:(WaveIcon *)ic {
    NSInteger wave = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];
    if (wave >= 1 && wave <= kNoBounceWaves) return kEarlyStartVelocity; // waves 1..3
    // CASpringAnimation.initialVelocity is normalized by travel distance, so the
    // same value yields a DIFFERENT real launch speed for each icon (icons travel
    // different distances because their startScale and home-radius differ). That
    // made waves 4-7 overshoot by different amounts despite identical spring
    // constants. With initialVelocity = 0 the overshoot ratio depends only on the
    // damping ratio (identical across 4-7), so they all bounce the same way.
    if (wave >= 4 && wave <= 7) return 0.0;
    return kOuterStartVelocity;                                          // waves 8..9
}

- (void)animateIcon:(WaveIcon *)ic delay:(NSTimeInterval)delay pullVelocity:(CGFloat)velocity {
    UIView *view = ic.view;
    CALayer *layer = view.layer;
    if (!view || !layer || !view.superview || !view.window) return;

    CGFloat damping   = [self dampingForIcon:ic pullVelocity:velocity];
    CGFloat stiffness = [self stiffnessForIcon:ic];
    CGFloat startVel  = [self initialVelocityForIcon:ic];

    CGPoint home = layer.position;
    CATransform3D homeTransform = layer.transform;

    NSInteger wave = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];

    // Restore the original depth rule: the bottom row tucks behind the center.
    NSInteger bottomRow = [WaveTable rowsForIsPad:self.isPad orientation:self.orientation] - 1;
    if (ic.row == bottomRow) layer.zPosition = -1;

    UIScreen *screen = view.window.screen;
    CGRect screenBounds = screen.coordinateSpace.bounds;
    CGPoint screenCenter = CGPointMake(CGRectGetMidX(screenBounds), CGRectGetMidY(screenBounds));
    // layer.position is in its superlayer's coordinates, not screen coordinates.
    CGPoint cameraCenter = [view.superview convertPoint:screenCenter
                                   fromCoordinateSpace:screen.coordinateSpace];
    CGPoint start = CGPointMake(cameraCenter.x + (home.x - cameraCenter.x) * kCameraStartZoom,
                                cameraCenter.y + (home.y - cameraCenter.y) * kCameraStartZoom);
    CATransform3D startTransform = CATransform3DScale(homeTransform,
                                                    kCameraStartZoom, kCameraStartZoom, 1.0);

    CFTimeInterval layerNow = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
    CFTimeInterval beginAt  = layerNow + delay;

    CASpringAnimation *pos = [CASpringAnimation animationWithKeyPath:@"position"];
    pos.fromValue = [NSValue valueWithCGPoint:start];
    pos.toValue   = [NSValue valueWithCGPoint:home];
    pos.damping   = damping;
    pos.stiffness = stiffness;
    pos.mass      = kSpringMass;
    pos.initialVelocity = startVel;
    pos.duration  = pos.settlingDuration;
    pos.beginTime = beginAt;
    pos.fillMode  = kCAFillModeBackwards;
    pos.removedOnCompletion = YES;
    [layer addAnimation:pos forKey:kKeyPos];

    // Identical spring parameters and start time give position and magnification
    // the same progress: P(t) = C + zoom(t) * (home - C).
    CASpringAnimation *scl = [CASpringAnimation animationWithKeyPath:@"transform"];
    scl.fromValue = [NSValue valueWithCATransform3D:startTransform];
    scl.toValue   = [NSValue valueWithCATransform3D:homeTransform];
    scl.damping   = damping;
    scl.stiffness = stiffness;
    scl.mass      = kSpringMass;
    scl.initialVelocity = startVel;
    scl.duration  = scl.settlingDuration;
    scl.beginTime = beginAt;
    scl.fillMode  = kCAFillModeBackwards;
    scl.removedOnCompletion = YES;
    [layer addAnimation:scl forKey:kKeyScale];

    // Only the last two waves tuck behind the existing waves. A temporary
    // animation restores the layer's original depth automatically on completion.
    if (wave >= 8) {
        CABasicAnimation *depth = [CABasicAnimation animationWithKeyPath:@"zPosition"];
        depth.fromValue = @(-2.0);
        depth.toValue = @(-2.0);
        depth.beginTime = beginAt;
        depth.duration = MAX(pos.duration, scl.duration);
        depth.fillMode = kCAFillModeBackwards;
        depth.removedOnCompletion = YES;
        [layer addAnimation:depth forKey:kKeyDepth];
    }
}

- (void)animateDock:(CGFloat)velocity {
    UIView *dock = self.dock;
    if (!dock) return;
    CALayer *layer = dock.layer;
    if (!layer) return;

    CGPoint home  = layer.position;
    CGPoint start = CGPointMake(home.x, home.y + kDockFlyDistance);

    CFTimeInterval layerNow = [layer convertTime:CACurrentMediaTime() fromLayer:nil];

    CASpringAnimation *pos = [CASpringAnimation animationWithKeyPath:@"position"];
    pos.fromValue = [NSValue valueWithCGPoint:start];
    pos.toValue   = [NSValue valueWithCGPoint:home];
    pos.damping   = kSpringDamping;
    pos.stiffness = kSpringStiffness;
    pos.mass      = kSpringMass;
    pos.initialVelocity = kSpringVelocity;
    pos.duration  = pos.settlingDuration;
    pos.beginTime = layerNow;
    pos.fillMode  = kCAFillModeBackwards;
    pos.removedOnCompletion = YES;
    [layer addAnimation:pos forKey:kKeyDock];
}

#pragma mark - Cleanup

- (void)reset {
    for (WaveIcon *ic in self.icons) {
        if (!ic.view) continue;
        [ic.view.layer removeAnimationForKey:kKeyPos];
        [ic.view.layer removeAnimationForKey:kKeyPosX];
        [ic.view.layer removeAnimationForKey:kKeyPosY];
        [ic.view.layer removeAnimationForKey:kKeyScale];
        [ic.view.layer removeAnimationForKey:kKeyDepth];
    }
    if (self.dock) {
        [self.dock.layer removeAnimationForKey:kKeyDock];
    }
}

@end
