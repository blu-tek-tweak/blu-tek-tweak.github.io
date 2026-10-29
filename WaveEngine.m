#import "WaveEngine.h"
#import "WaveTable.h"

#pragma mark - Tuning

static const CGFloat kSpringStiffness  = 155.0;
static const CGFloat kSpringMass       = 1.501;
static const CGFloat kSpringVelocity   = 0.0;
// Dock: damping now tracks pull speed (like the icons). p=0 (slowest) -> max
// damping (25, snappy); p=1 (fastest) -> min damping (21, bouncier). The old
// fixed 22 sits near the midpoint of this range.
static const CGFloat kDockDampingMin   = 21.0;
static const CGFloat kDockDampingMax   = 25.0;

// The first N waves (center-out) should land with almost no bounce AND be fast.
// A stiffer spring settles quickly; damping at ~92% of critical keeps overshoot
// to ~0.07% (invisible) while staying snappy.
static const NSInteger kNoBounceWaves     = 3;
static const CGFloat   kNoBounceStiffness = 250.0;  // fast take-off + quick settle

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
static const CGFloat kOuterWaveStiffness  = 35.31;  // softer -> slower bounce
static const CGFloat kOuterWaveDampingMin = 10.6;   // fastest pull (z~0.70) [iPad]
static const CGFloat kOuterWaveDampingMax = 11.5;   // slowest pull (z~0.76)
// iPhone only: waves 8..9.
static const CGFloat kIPhoneOuterWaveDampingMin = 10.5;
static const CGFloat kIPhoneOuterWaveDampingMax = 12.97;
static const CGFloat kIPhoneOuterStartVelocity  = 0.803;
// Waves 4..7 (mid-outer): share ONE damping range (identical bounce feel). Only
// their STIFFNESS differs (4..5 slightly stiffer than 6..7).
static const CGFloat kFirstWaveStiffness  = 234.28; // 1..3: slightly stiffer than the mid ring
static const CGFloat kFirstWaveDampingMin = 26.23;  // 1..3 fastest pull
static const CGFloat kFirstWaveDampingMax = 34.5;   // 1..3 slowest pull
static const CGFloat kFirstWaveStartVelocity = 0.663; // 1..3
static const CGFloat kMidWaveStiffness    = 100.75; // 4..5
static const CGFloat kMidWave67Stiffness  = 100.75; // 6..7
static const CGFloat kMidWaveDampingMin   = 17.03;  // 4..7 fastest pull
static const CGFloat kMidWaveDampingMax   = 22.9;   // 4..7 slowest pull
// Pull speed (pts/s) at which p hits 1.0 -> minimum damping (bounciest). A faster
// flick is required to reach the min-damping end; a default ~1250 swipe sits at
// ~0.19 of the range.
static const CGFloat kPullVelocityFull  = 6500.0;

// ORIGINAL pre-merge first-wave damping (32..40), kept for reference.
static const CGFloat kOldFirstWaveDampingMin = 32.0;
static const CGFloat kOldFirstWaveDampingMax = 40.0;
// iPad only: waves 1..3 keep the ORIGINAL (pre-iPhone-tuning) range 34..39 so
// the iPhone's 32..39 tightening does not bleed into the iPad.
static const CGFloat kIPadFirstWaveDampingMin = 34.0;
static const CGFloat kIPadFirstWaveDampingMax = 39.0;

// Early waves (1..3) get a forward initial velocity so they launch quickly
// (start fast); the high damping then slows them into a soft stop (ease-out).
// CASpringAnimation's initialVelocity scale is far smaller than it looks —
// even 50 overshot the scale spring into negative (mirrored icon). Testing 12.
static const CGFloat kEarlyStartVelocity = 12.0;    // waves 1..3 only

// Waves 1..3 currently share the mid-wave (4..7) ranges; the first-wave
// constants above are kept for later tuning. Reference them so -Werror does not
// flag them as unused.
static void __attribute__((used)) wave26_keepFirstWaveConstants(void) {
    (void)kNoBounceWaves;
    (void)kNoBounceStiffness;
    (void)kOldFirstWaveDampingMin;
    (void)kOldFirstWaveDampingMax;
    (void)kIPadFirstWaveDampingMin;
    (void)kIPadFirstWaveDampingMax;
    (void)kEarlyStartVelocity;
}

// NOTE: kFirstWaveDampingMin/Max (32/40) and kEarlyStartVelocity (12.0) are the
// ORIGINAL pre-merge values, kept for reference. The active first-wave values are
// kFirstWaveStiffness / kFirstWaveDampingMin..Max (20/26) / kFirstWaveStartVelocity (0.9).
// The guard above silences -Werror for the kept-but-unused originals.

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

static NSString * const kKeyPos   = @"wave26.pos";
static NSString * const kKeyPosX  = @"wave26.posx";
static NSString * const kKeyPosY  = @"wave26.posy";
static NSString * const kKeyScale = @"wave26.scale";
static NSString * const kKeyDepth = @"wave26.depth";
static NSString * const kKeyDock  = @"wave26.dock";

#pragma mark - Prefs

static NSString *const kWavePrefsFileName = @"com.blu-tek.26waveprefs.plist";

// The prefs file is written by the Settings app, which always triggers a
// respring, so it never changes during a SpringBoard session. Load it ONCE
// (lazily) and cache the dictionary; every subsequent Wave26PrefDouble call is
// a simple dictionary lookup instead of re-enumerating /private/preboot and
// re-reading the file. This keeps the per-icon cost minimal.
static NSDictionary *sWavePrefsCache = nil;

static void Wave26LoadPrefsOnce(void) {
    NSMutableArray *paths = [NSMutableArray array];
    [paths addObject:[NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kWavePrefsFileName]];
    [paths addObject:[NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@", kWavePrefsFileName]];
    NSString *preboot = @"/private/preboot";
    NSArray *uuidDirs = [NSFileManager.defaultManager contentsOfDirectoryAtPath:preboot error:NULL];
    for (NSString *uuid in uuidDirs) {
        NSString *base = [NSString stringWithFormat:@"%@/%@", preboot, uuid];
        NSArray *dopamineDirs = [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:NULL];
        for (NSString *dop in dopamineDirs) {
            if (![dop hasPrefix:@"dopamine"]) continue;
            NSString *p = [NSString stringWithFormat:@"%@/%@/procursus/var/mobile/Library/Preferences/%@", base, dop, kWavePrefsFileName];
            [paths addObject:p];
        }
    }
    for (NSString *p in paths) {
        id dict = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            sWavePrefsCache = dict;
            return;
        }
    }
    sWavePrefsCache = @{};
}

static double Wave26PrefDouble(NSString *key, double defaultValue) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Wave26LoadPrefsOnce();
    });
    id raw = [sWavePrefsCache objectForKey:key];
    if (!raw) return defaultValue;
    return [raw doubleValue];
}

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
// Per-wave shared duration (seconds). Every icon in a wave uses the SAME
// duration (the max settlingDuration of that wave) so the whole wave finishes
// its animation at the same instant. Without this, per-icon settlingDuration
// (which varies with each icon's damping/stiffness/initialVelocity) made some
// icons' springs run longer and "land very briefly after" their neighbors.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *waveDurations;
// A single shared "now" captured ONCE per play (in the first icon's layer time
// base). Every icon's beginTime is derived from this one value (not from its
// own, per-call CACurrentMediaTime), so same-wave icons get an identical
// beginTime and land together.
@property (nonatomic, assign) CFTimeInterval sharedNow;
@end

@implementation WaveEngine

- (instancetype)init {
    if ((self = [super init])) {
        _icons = [NSMutableArray array];
        _waveDurations = [NSMutableDictionary dictionary];
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

// For each present wave, compute the max settlingDuration across its icons and
// store it as that wave's shared duration. animateIcon then uses this instead of
// the per-icon settlingDuration, so every icon in a wave finishes at the same
// instant (no icon "lands very briefly after" the rest).
- (void)prepareWaveDurationsWithPullVelocity:(CGFloat)velocity {
    [self.waveDurations removeAllObjects];
    NSMutableDictionary<NSNumber *, NSMutableSet *> *byWave = [NSMutableDictionary dictionary];
    for (WaveIcon *ic in self.icons) {
        NSInteger w = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];
        if (w < 1) continue;
        NSMutableSet *set = byWave[@(w)];
        if (!set) { set = [NSMutableSet set]; byWave[@(w)] = set; }
        [set addObject:ic];
    }
    for (NSNumber *w in byWave) {
        CGFloat maxD = 0.0;
        for (WaveIcon *ic in byWave[w]) {
            CASpringAnimation *probe = [CASpringAnimation animationWithKeyPath:@"position"];
            probe.damping   = [self dampingForIcon:ic pullVelocity:velocity];
            probe.stiffness = [self stiffnessForIcon:ic];
            probe.mass      = [self massForIcon:ic];
            probe.initialVelocity = [self initialVelocityForIcon:ic];
            maxD = MAX(maxD, probe.settlingDuration);
        }
        self.waveDurations[w] = @(maxD);
    }
}

- (void)playWithPullVelocity:(CGFloat)velocity {
    [self prepareWaveDurationsWithPullVelocity:velocity];

    // Capture "now" ONCE, in the first icon's layer time base, and use it for
    // every icon. animateIcon is called sequentially in a loop, so calling
    // CACurrentMediaTime() per icon advanced the clock 10-40ms across the loop;
    // that drift, added onto each icon's (possibly large, negative) delay, made
    // same-wave icons start their springs at different points and land at
    // different times. A single shared "now" removes the drift.
    UIView *refView = nil;
    for (WaveIcon *ic in self.icons) {
        if (ic.view && ic.view.window) { refView = ic.view; break; }
    }
    if (refView) {
        self.sharedNow = [refView.layer convertTime:CACurrentMediaTime() fromLayer:nil];
    } else {
        self.sharedNow = CACurrentMediaTime();
    }

    if (self.isPad) {
        // iPad: keep the WaveTable 50ms-per-wave schedule (absolute offsets).
        for (WaveIcon *ic in self.icons) {
            NSTimeInterval delay = [WaveTable delayForCol:ic.col row:ic.row
                                               waveInterval:0.0
                                                      isPad:YES
                                                 orientation:self.orientation];
            [self animateIcon:ic delay:delay pullVelocity:velocity];
        }
        [self animateDock:velocity];
        return;
    }

    // iPhone: relative delays. Each wave's value (from prefs, or the default
    // below when the pref is absent) is the delay AFTER the previous wave. A
    // wave's landing time is the sum of waves 1..w — accumulated over ALL waves
    // 1..w, NOT just the waves present on this page. That keeps the prefs
    // reading as relative gaps (a slider still means "the gap after wave N-1")
    // while making each wave's timing independent of which waves are present:
    // a page missing the last row (wave 9 absent) no longer shifts the earlier
    // waves, so wave 6 lands at the same time it does on a full page. (The old
    // scheme accumulated only over present waves, so a missing wave 9 pulled
    // wave 6 ~126ms later.)
    static const double kRelativeDelays[10] = {
        0.0,      // wave 0 (unused)
        -0.0343,  // wave 1
        0.03,     // wave 2 (no pref exposed; keep the default)
        0.0197,   // wave 3
        -0.1257,  // wave 4
        0.071,    // wave 5
        -0.0537,  // wave 6
        0.0703,   // wave 7
        -0.1263,  // wave 8
        0.071,    // wave 9
    };
    // Precompute every wave's landing time as the sum of waves 1..w (accumulated
    // over all waves, so it does not depend on which waves are present).
    NSMutableDictionary<NSNumber *, NSNumber *> *waveTotal = [NSMutableDictionary dictionary];
    NSTimeInterval running = 0.0;
    for (NSInteger w = 1; w <= 9; w++) {
        running += Wave26PrefDouble([NSString stringWithFormat:@"w%ld_delay", (long)w], kRelativeDelays[w]);
        waveTotal[@(w)] = @(running);
    }
    // Apply each icon's wave's landing time.
    for (WaveIcon *ic in self.icons) {
        NSInteger w = [WaveTable waveForCol:ic.col row:ic.row isPad:NO orientation:self.orientation];
        NSNumber *total = waveTotal[@(w)];
        NSTimeInterval delay = total ? total.doubleValue : 0.0;
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

    // Prefs override (iPhone only): per-group damping.
    if (!self.isPad) {
        NSString *prefix;
        double defMin, defMax;
        if (wave >= 1 && wave <= 3)      { prefix = @"w13"; defMin = kFirstWaveDampingMin;  defMax = kFirstWaveDampingMax;  }
        else if (wave >= 4 && wave <= 7) { prefix = @"w47"; defMin = kMidWaveDampingMin;    defMax = kMidWaveDampingMax;    }
        else                             { prefix = @"w89"; defMin = kIPhoneOuterWaveDampingMin; defMax = kIPhoneOuterWaveDampingMax; }
        double minD = Wave26PrefDouble([NSString stringWithFormat:@"%@_dampingMin", prefix], defMin);
        double maxD = Wave26PrefDouble([NSString stringWithFormat:@"%@_dampingMax", prefix], defMax);
        return maxD + (minD - maxD) * p;
    }

    if (wave >= 1 && wave <= 3) {
        // Waves 1..3: their own (wider) damping range.
        return kFirstWaveDampingMax + (kFirstWaveDampingMin - kFirstWaveDampingMax) * p;
    }
    if (wave >= 8) {
        // Waves 8..9 (outermost ring).
        CGFloat minD = self.isPad ? kOuterWaveDampingMin : kIPhoneOuterWaveDampingMin;
        CGFloat maxD = self.isPad ? kOuterWaveDampingMax : kIPhoneOuterWaveDampingMax;
        return maxD + (minD - maxD) * p;
    }
    // Waves 4..7: identical damping (only stiffness differs between 4..5 and 6..7).
    return kMidWaveDampingMax + (kMidWaveDampingMin - kMidWaveDampingMax) * p;
}

- (CGFloat)massForIcon:(WaveIcon *)ic {
    // The prefs UI exposes a single mass slider (w47_mass); apply it globally.
    if (!self.isPad) {
        return Wave26PrefDouble(@"w47_mass", kSpringMass);
    }
    return kSpringMass;
}

- (CGFloat)stiffnessForIcon:(WaveIcon *)ic {
    NSInteger wave = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];
    if (!self.isPad) {
        NSString *prefix;
        double defS;
        if (wave >= 1 && wave <= 3)      { prefix = @"w13"; defS = kFirstWaveStiffness; }
        else if (wave >= 4 && wave <= 7) { prefix = @"w47"; defS = kMidWaveStiffness;   }
        else                             { prefix = @"w89"; defS = kOuterWaveStiffness; }
        return Wave26PrefDouble([NSString stringWithFormat:@"%@_stiffness", prefix], defS);
    }
    if (wave >= 8) return kOuterWaveStiffness;                          // waves 8..9: softer/slower bounce
    if (wave >= 6 && wave <= 7) return kMidWave67Stiffness;             // waves 6..7
    if (wave >= 1 && wave <= 3) return kFirstWaveStiffness;             // waves 1..3: slightly stiffer
    return kMidWaveStiffness;                                          // waves 4..5
}

- (CGFloat)initialVelocityForIcon:(WaveIcon *)ic {
    NSInteger wave = [WaveTable waveForCol:ic.col row:ic.row isPad:self.isPad orientation:self.orientation];
    if (!self.isPad) {
        NSString *prefix;
        double defV;
        if (wave >= 1 && wave <= 3)      { prefix = @"w13"; defV = kFirstWaveStartVelocity; }
        else if (wave >= 4 && wave <= 7) { prefix = @"w47"; defV = 0.95; }
        else                             { prefix = @"w89"; defV = kIPhoneOuterStartVelocity; }
        return Wave26PrefDouble([NSString stringWithFormat:@"%@_velocity", prefix], defV);
    }
    if (wave >= 1 && wave <= 3) return kFirstWaveStartVelocity;          // waves 1..3
    if (wave >= 4 && wave <= 7) return 0.0;                              // waves 4..7 (pre-merge)
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
    CGPoint start;
    CATransform3D startTransform;
    if (self.startFromOffscreen) {
        // Icons were moved off-screen (below the bottom edge) by the lock-screen
        // hide; fly them in from there. The transform stays at home scale so only
        // the position animates (a straight fly-in from below).
        start = CGPointMake(cameraCenter.x,
                            cameraCenter.y + (home.y - cameraCenter.y) + screenBounds.size.height);
        startTransform = homeTransform;
    } else {
        // Camera zoom: fly in from a 4.5x magnification of the screen center.
        // Every icon (app icon or widget) starts at the same 4.5x scale, so the
        // wave is a uniform "zoom out from the camera" effect.
        start = CGPointMake(cameraCenter.x + (home.x - cameraCenter.x) * kCameraStartZoom,
                             cameraCenter.y + (home.y - cameraCenter.y) * kCameraStartZoom);
        startTransform = CATransform3DScale(homeTransform,
                                            kCameraStartZoom, kCameraStartZoom, 1.0);
    }

    // Use the single shared "now" (captured once in playWithPullVelocity) rather
    // than a per-call CACurrentMediaTime(). This keeps every icon's beginTime on
    // the same reference so same-wave icons land together.
    CFTimeInterval beginAt = self.sharedNow + delay;

    CASpringAnimation *pos = [CASpringAnimation animationWithKeyPath:@"position"];
    pos.fromValue = [NSValue valueWithCGPoint:start];
    pos.toValue   = [NSValue valueWithCGPoint:home];
    pos.damping   = damping;
    pos.stiffness = stiffness;
    pos.mass      = [self massForIcon:ic];
    pos.initialVelocity = startVel;
    // Use the wave's shared duration (max settlingDuration of the wave) so every
    // icon in the wave finishes at the same instant.
    NSNumber *waveDur = self.waveDurations[@(wave)];
    pos.duration  = waveDur ? waveDur.doubleValue : pos.settlingDuration;
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
    scl.mass      = [self massForIcon:ic];
    scl.initialVelocity = startVel;
    // Same shared duration as the position spring so position and scale stay in
    // lockstep and the whole wave ends together.
    scl.duration  = pos.duration;
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

    // Map pull speed to p in [0,1] (same scale as the icons): p=0 (slowest) ->
    // max damping (snappy); p=1 (fastest) -> min damping (bouncier).
    CGFloat p = MIN(1.0, fabs(velocity) / kPullVelocityFull);
    CGFloat dockDamping = kDockDampingMax + (kDockDampingMin - kDockDampingMax) * p;

    CASpringAnimation *pos = [CASpringAnimation animationWithKeyPath:@"position"];
    pos.fromValue = [NSValue valueWithCGPoint:start];
    pos.toValue   = [NSValue valueWithCGPoint:home];
    pos.damping   = dockDamping;
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
