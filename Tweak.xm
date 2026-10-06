#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <string.h>
#import "WaveEngine.h"
#import "WaveTable.h"

@interface NSDistributedNotificationCenter : NSObject
+ (instancetype)defaultCenter;
- (void)addObserverForName:(NSString *)name object:(id)object queue:(NSOperationQueue *)queue usingBlock:(void (^)(NSNotification *note))block;
@end

#pragma mark - Debug logging

static void wave26_log(NSString *msg) {
    // Logging disabled for release build.
    (void)msg;
}

#pragma mark - Tuning

static const CGFloat kDefaultPullVelocity = 1250.0;

#pragma mark - Device idiom / orientation

// Cached once at init. The grid dimensions come from WaveTable (iPhone 4x6,
// iPad 5x6); the orientation selects the iPad's horizontal vs vertical map.
static BOOL g_isPad = NO;

static BOOL wave26_isPad(void) {
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}

// Current orientation as a WaveOrientation. Portrait -> vertical; landscape ->
// horizontal. (Used only for the iPad; the iPhone map is orientation-agnostic.)
static WaveOrientation wave26_currentOrientation(void) {
    UIDeviceOrientation o = [UIDevice currentDevice].orientation;
    switch (o) {
        case UIDeviceOrientationLandscapeLeft:
        case UIDeviceOrientationLandscapeRight:
        case UIDeviceOrientationFaceUp:      // treat face-up as landscape (default iPad)
            return WaveOrientationHorizontal;
        case UIDeviceOrientationPortrait:
        case UIDeviceOrientationPortraitUpsideDown:
        case UIDeviceOrientationFaceDown:
        default:
            return WaveOrientationVertical;
    }
}

#pragma mark - State

static WaveEngine *g_engine = nil;
static CGPoint g_lastVel = {0, 0};
static BOOL g_haveVel = NO;
static CFAbsoluteTime g_lastFireTime = 0;
static CFAbsoluteTime g_lockScreenDismissed = 0;
static BOOL g_panFired = NO;   // set when the swipe-up gesture fires this unlock
static BOOL g_sheetMovedFired = NO;  // set when we've already fired via sheet-move
static BOOL g_rootFired = NO;   // set once the root-folder path fired this unlock
static BOOL g_sheetSeenOnScreen = NO;  // cover sheet observed fully on-screen this lock cycle

// Cached class lookups (resolved once at init).
static Class g_panClass = nil;
static Class g_iconClass = nil;
static Class g_dockClass = nil;
static Class g_floatingDockClass = nil;
static Class g_atNavClass = nil;
static Class g_sbClass = nil;
static NSArray<Class> *g_appLibraryClasses = nil;  // App Library container views

#pragma mark - Icon discovery

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
static NSArray<UIWindow *> *allWindows(void) {
    return [[UIApplication sharedApplication] windows];
}
#pragma GCC diagnostic pop

static void wave26_collectViewsOfClass(Class cls, UIView *view, NSMutableArray *out) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:cls]) {
            [out addObject:sub];
        }
        wave26_collectViewsOfClass(cls, sub, out);
    }
}

static BOOL wave26_isLibraryView(UIView *view) {
    for (Class cls in g_appLibraryClasses) {
        if ([view isKindOfClass:cls]) return YES;
    }
    // Also handles classes loaded after our constructor.
    return [NSStringFromClass(view.class) isEqualToString:@"SBHLibraryCategoryPodIconListView"];
}

static BOOL wave26_isLibraryIcon(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (wave26_isLibraryView(ancestor)) return YES;
    }
    return NO;
}

static BOOL wave26_viewOnScreen(UIView *view) {
    UIWindow *window = view.window;
    if (!window || window.hidden || window.alpha < 0.5) return NO;
    CGRect visible = [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(visible) || CGRectIsNull(visible)) return NO;
    CGFloat originalArea = visible.size.width * visible.size.height;
    visible = CGRectIntersection(visible, window.bounds);
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.5) return NO;
        if (ancestor.clipsToBounds) {
            visible = CGRectIntersection(visible, [ancestor convertRect:ancestor.bounds toView:window]);
        }
        if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return NO;
    }
    return visible.size.width * visible.size.height > originalArea * 0.5;
}

static NSMutableArray *collectIconViews(void) {
    NSMutableArray *icons = [NSMutableArray array];
    if (!g_iconClass) return icons;
    for (UIWindow *win in allWindows()) {
        if (win.hidden || win.alpha < 0.5) continue;
        wave26_collectViewsOfClass(g_iconClass, win, icons);
    }
    NSMutableArray *homeIcons = [NSMutableArray array];
    for (UIView *icon in icons) {
        // Only the CURRENT page's icons are on-screen. Off-screen (adjacent)
        // pages' icons remain attached to the hierarchy during a page change;
        // animating them would make the wrong page's icons fly in / carry the
        // animation in the wrong place. Skip anything not visible on-screen.
        if (wave26_isLibraryIcon(icon)) continue;
        if (!wave26_viewOnScreen(icon)) continue;
        [homeIcons addObject:icon];
    }
    return homeIcons;
}

// YES when the App Library page is currently on-screen. We must NOT run the wave
// there: its layout is a few large category tiles, not the 4x6 icon grid, so the
// grid binning is meaningless and the animation looks wrong. Detect it by the
// presence of a visible App Library container view.
static BOOL wave26_appLibraryVisible(void) {
    if (g_appLibraryClasses.count == 0) return NO;
    for (UIWindow *win in allWindows()) {
        if (win.hidden || win.alpha < 0.5) continue;
        for (Class c in g_appLibraryClasses) {
            NSMutableArray *found = [NSMutableArray array];
            wave26_collectViewsOfClass(c, win, found);
            for (UIView *v in found) {
                if (wave26_viewOnScreen(v)) return YES;
            }
        }
    }
    return NO;
}

// YES when any Control Center module view (CCUIButtonModuleView) is on-screen.
// Tapping the screen-recording button (or opening Control Center) presents these
// views; firing the wave then would animate the home icons behind/under the CC
// UI, which is wrong. Skip the wave whenever CC is up.
static BOOL wave26_controlCenterVisible(void) {
    Class ccClass = NSClassFromString(@"CCUIButtonModuleView");
    if (!ccClass) return NO;
    for (UIWindow *win in allWindows()) {
        if (win.hidden || win.alpha < 0.5) continue;
        NSMutableArray *found = [NSMutableArray array];
        wave26_collectViewsOfClass(ccClass, win, found);
        for (UIView *v in found) {
            if (wave26_viewOnScreen(v)) return YES;
        }
    }
    return NO;
}

static UIView *findDockView(void) {
    // FloatingDockXVI uses SBFloatingDockView rather than SBDockView. Resolve
    // again here if necessary so discovery does not depend on tweak load order.
    if (!g_floatingDockClass) g_floatingDockClass = NSClassFromString(@"SBFloatingDockView");
    if (!g_dockClass) g_dockClass = NSClassFromString(@"SBDockView");
    NSArray<UIWindow *> *windows = allWindows();
    // Prefer the visible floating dock: a hidden stock dock can remain attached
    // to the hierarchy when FloatingDockXVI is enabled.
    Class dockClasses[] = { g_floatingDockClass, g_dockClass };
    for (NSUInteger i = 0; i < sizeof(dockClasses) / sizeof(dockClasses[0]); i++) {
        Class cls = dockClasses[i];
        if (!cls) continue;
        for (UIWindow *win in windows) {
            if (win.hidden || win.alpha < 0.5) continue;
            NSMutableArray *found = [NSMutableArray array];
            wave26_collectViewsOfClass(cls, win, found);
            for (UIView *dock in found) {
                if (wave26_viewOnScreen(dock)) return dock;
            }
        }
    }
    return nil;
}

static BOOL isInDock(UIView *view, UIView *dock) {
    for (UIView *v = view; v; v = v.superview) {
        if (v == dock) return YES;
        // Exclude all dock icons from grid binning, including floating-dock
        // recents/suggestions and icons in any dock other than the chosen one.
        if (g_floatingDockClass && [v isKindOfClass:g_floatingDockClass]) return YES;
        if (g_dockClass && [v isKindOfClass:g_dockClass]) return YES;
    }
    return NO;
}

static void wave26_stripAnimations(UIView *view) {
    if (!view) return;
    [view.layer removeAllAnimations];
    for (CALayer *sub in view.layer.sublayers) {
        [sub removeAllAnimations];
    }
}

#pragma mark - Register + fire

static void wave26_registerHome(NSArray *icons, UIView *dock) {
    // A sparse home page may not have enough icons for grid registration, but
    // its dock should still animate (and must replace the previous dock).
    [g_engine setDockView:dock];
    CGRect screen = [UIScreen mainScreen].bounds;
    NSMutableArray *filtered = [NSMutableArray array];
    for (UIView *v in icons) {
        if (isInDock(v, dock)) continue;
        CGRect f = [v convertRect:v.bounds toView:nil];
        if (CGRectIsNull(f)) continue;
        CGPoint c = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        if (c.x < 0 || c.x > screen.size.width || c.y < 0 || c.y > screen.size.height) continue;
        [filtered addObject:v];
    }
    if (filtered.count < 4) return;

    UIView *pageView = filtered[0];
    while (pageView.superview && pageView.bounds.size.width < screen.size.width * 0.9) {
        pageView = pageView.superview;
    }
    if (!pageView) return;

    const NSInteger MAXI = 64;
    CGFloat cxArr[MAXI], cyArr[MAXI];
    UIView *iconArr[MAXI];
    NSInteger n = 0;
    CGFloat minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
    for (UIView *v in filtered) {
        if (n >= MAXI) break;
        CGPoint c = [v convertPoint:v.center toView:pageView];
        cxArr[n] = c.x; cyArr[n] = c.y;
        iconArr[n] = v;
        minX = MIN(minX, c.x); maxX = MAX(maxX, c.x);
        minY = MIN(minY, c.y); maxY = MAX(maxY, c.y);
        n++;
    }
    if (n < 4) return;

    // Idiom + orientation-aware grid dimensions (iPhone 4x6; iPad vertical 5x6,
    // horizontal 6x5).
    WaveOrientation orient = wave26_currentOrientation();
    NSInteger gridCols = [WaveTable colsForIsPad:g_isPad orientation:orient];
    NSInteger gridRows = [WaveTable rowsForIsPad:g_isPad orientation:orient];

    // Detect the ACTUAL number of rows by clustering y-coordinates, then map
    // the present rows to the TOP of the grid (rows 0..rowCount-1). A page with
    // 5 rows maps to rows 0-4 (the wave table's row 5 is simply unused), which
    // is the natural look for a 5-row page — no wedged/missing waves.
    // Sort the y-values to find distinct row bands.
    CGFloat ys[MAXI];
    for (NSInteger i = 0; i < n; i++) ys[i] = cyArr[i];
    for (NSInteger i = 1; i < n; i++) {
        CGFloat key = ys[i]; NSInteger j = i - 1;
        while (j >= 0 && ys[j] > key) { ys[j + 1] = ys[j]; j--; }
        ys[j + 1] = key;
    }
    CGFloat spanY = MAX(1.0, maxY - minY);
    CGFloat gapThreshold = (spanY / gridRows) * 0.5;  // a half-row gap starts a new band
    NSInteger rowCount = 1;
    for (NSInteger i = 1; i < n; i++) {
        if (ys[i] - ys[i - 1] > gapThreshold) rowCount++;
    }
    if (rowCount < 1) rowCount = 1;
    if (rowCount > gridRows) rowCount = gridRows;

    // Columns: same clustering.
    CGFloat xs[MAXI];
    for (NSInteger i = 0; i < n; i++) xs[i] = cxArr[i];
    for (NSInteger i = 1; i < n; i++) {
        CGFloat key = xs[i]; NSInteger j = i - 1;
        while (j >= 0 && xs[j] > key) { xs[j + 1] = xs[j]; j--; }
        xs[j + 1] = key;
    }
    CGFloat spanX = MAX(1.0, maxX - minX);
    CGFloat colGapThreshold = (spanX / gridCols) * 0.5;
    NSInteger colCount = 1;
    for (NSInteger i = 1; i < n; i++) {
        if (xs[i] - xs[i - 1] > colGapThreshold) colCount++;
    }
    if (colCount < 1) colCount = 1;
    if (colCount > gridCols) colCount = gridCols;

    // Divide the bounding box by the ACTUAL counts and bin. The present rows
    // fill rows 0..rowCount-1 (top-anchored), so a 5-row page uses rows 0-4.
    CGFloat cellW = spanX / colCount;
    CGFloat cellH = spanY / rowCount;

    for (NSInteger i = 0; i < n; i++) {
        NSInteger c = (NSInteger)((cxArr[i] - minX) / cellW);
        NSInteger r = (NSInteger)((cyArr[i] - minY) / cellH);
        if (c < 0) c = 0; if (c >= colCount) c = colCount - 1;
        if (r < 0) r = 0; if (r >= rowCount) r = rowCount - 1;
        [g_engine registerIcon:iconArr[i] col:c row:r];
    }
}

// Walk up from a view to the window, collecting ancestor layers.
static void wave26_stripAncestors(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        [v.layer removeAllAnimations];
    }
}

static void wave26_scheduleFlyDiagnostics(void) {
    // Disabled for release: this enumerates every class + method in SpringBoard
    // (objc_copyClassList / class_copyMethodList) on a 30s timer, which is
    // expensive and unnecessary in production.
    return;
    static BOOL pending = NO;
    static CFAbsoluteTime lastScan = 0;
    if (pending) return;
    if (CFAbsoluteTimeGetCurrent() - lastScan < 30 &&
        [[NSFileManager defaultManager] fileExistsAtPath:@"/var/tmp/wave26-flyin-diagnostics.txt"]) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @autoreleasepool {
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            NSMutableString *report = [NSMutableString stringWithFormat:
                @"26Unlock fly-in diagnostics v273\nDate: %@\nLoaded classes: %u\n", [NSDate date], count];
            for (unsigned int i = 0; classes && i < count; i++) {
                Class cls = classes[i];
                const char *name = class_getName(cls);
                if (strncmp(name, "SB", 2) && strncmp(name, "CS", 2) && strncmp(name, "FB", 2)) continue;
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(cls, &methodCount);
                for (unsigned int j = 0; j < methodCount; j++) {
                    const char *selector = sel_getName(method_getName(methods[j]));
                    if (strcasestr(selector, "fly") ||
                        (strcasestr(selector, "icon") && strcasestr(selector, "animat"))) {
                        [report appendFormat:@"-[%s %s] types=%s\n", name, selector,
                            method_getTypeEncoding(methods[j])];
                    }
                }
                free(methods);
            }
            free(classes);
            NSError *error = nil;
            NSString *path = @"/var/tmp/wave26-flyin-diagnostics.txt";
            BOOL written = [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
            if (written) {
                wave26_log(@"flyin: v273 diagnostic report refreshed at /var/tmp/wave26-flyin-diagnostics.txt");
            } else {
                NSLog(@"26Unlock: diagnostic write failed: %@", error);
                wave26_log([NSString stringWithFormat:@"flyin: diagnostic write failed: %@", error]);
            }
        }
        lastScan = CFAbsoluteTimeGetCurrent();
        pending = NO;
    });
}

static void wave26_fire(void);

// Reliable "we arrived home" trigger. The root-folder (home screen) presentation
// is driven by SpringBoard for BOTH swipe-up and home-button unlocks, so it is
// a trustworthy unlock signal that does not depend on the pan gesture (which a
// home-button press never produces) nor on the lockstate distributed
// notification (whose userInfo/timing is not reliable for this). By the time the
// presentation is fully revealed the home screen is up and — because this tweak
// disables the default icon launch animation — the icons are already at their
// home positions, so the wave can anchor to them immediately.
static void wave26_homeArrived(void) {
    // The swipe-up pan path already fired this unlock; don't double-fire.
    if (g_panFired) return;
    // Presentation progress is delivered several times (0 -> 1); fire only once.
    if (g_rootFired) return;
    g_rootFired = YES;
    g_sheetMovedFired = YES;
    g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
    wave26_fire();
}

// The native fly-in's _setAnimationFraction: is called AFTER we fire (see the
// device log: "fire:" is followed by "flyprogress:"). That call re-adds the
// native fly-in animations on the same icon layers, clobbering our wave and
// holding the icons at the zoomed-out start (fraction 0.0) -> invisible. To win
// the animation race we re-assert our wave AFTER the fly-in updates: strip the
// fly-in's animations and replay ours so ours is the last animation on each
// layer. Called from wave26_flyProgress.
//
// We only re-assert while we are actually in an unlock sequence (g_rootFired or
// g_panFired was set this unlock). The fly-in also runs during ordinary
// app open/close transitions; re-asserting there would replay the wave on every
// app switch, which is wrong.
//
// The fly-in's _setAnimationFraction: is called many times over ~2s as the
// (suppressed) fly-in "settles"; re-asserting on every call restarted the wave
// repeatedly -> the "refires for no reason" bug. So we re-assert ONCE per
// unlock, on the fly-in's settled (0.0) update.
// (Re-assert removed: the fly-in is now a no-op, so it no longer clobbers our
// wave. The wave fires once from the unlock trigger and is not overridden.)

static void wave26_fire(void) {
    wave26_scheduleFlyDiagnostics();
    if (!g_engine) { wave26_log(@"fire: no engine"); return; }

    // Off-screen Library views remain attached while on a normal home page.
    // Only skip when Library content actually intersects the visible viewport.
    if (wave26_appLibraryVisible()) {
        wave26_log(@"fire: skipped (App Library visible)");
        return;
    }

    // Control Center (e.g. the screen-recording button) presents
    // CCUIButtonModuleView; don't fire the wave while CC is on-screen.
    if (wave26_controlCenterVisible()) {
        wave26_log(@"fire: skipped (Control Center visible)");
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastFireTime < 0.5) return;
    g_lastFireTime = now;

    [g_engine reset];
    // Rebuild the icon list from scratch each unlock. Icons from other home
    // pages linger in the array otherwise and get animated with stale col/row,
    // skewing the wave until a respring.
    [g_engine clearIcons];

    // Collect icons and dock once.
    NSArray *icons = collectIconViews();
    wave26_log([NSString stringWithFormat:@"fire: icons=%lu", (unsigned long)icons.count]);
    if (icons.count == 0) return;
    UIView *dock = findDockView();

    wave26_registerHome(icons, dock);

    CGFloat vel = g_haveVel ? g_lastVel.y : -kDefaultPullVelocity;
    g_haveVel = NO;

    // Strip existing animations on icon/dock layers (before we add ours).
    for (UIView *v in icons) {
        wave26_stripAnimations(v);
    }
    if (dock) wave26_stripAnimations(dock);

    // Strip ancestor layers (page view up to window) — one-shot.
    UIView *pageView = icons[0];
    CGRect screen = [UIScreen mainScreen].bounds;
    while (pageView.superview && pageView.bounds.size.width < screen.size.width * 0.9) {
        pageView = pageView.superview;
    }
    wave26_stripAncestors(pageView);
    if (dock) wave26_stripAncestors(dock);

    // Tell the engine the device idiom + orientation so it picks the right wave
    // table (iPhone 4x6 vs iPad 5x6 horizontal/vertical) and grid center.
    g_engine.isPad = g_isPad;
    g_engine.orientation = wave26_currentOrientation();

    // Play our wave.
    [g_engine playWithPullVelocity:vel];
}

#pragma mark - Hooks

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;

    if (!(g_panClass && [self isKindOfClass:g_panClass])) return;
    // Only a COMPLETED swipe (Ended) is a real unlock. A Cancelled edge-pan
    // means the user didn't finish the swipe (or pulled the cover sheet and
    // released) — firing on those caused constant false waves.
    if (state == UIGestureRecognizerStateEnded) {
        if ([self isKindOfClass:[UIPanGestureRecognizer class]]) {
            g_lastVel = [(UIPanGestureRecognizer *)self velocityInView:self.view];
            g_haveVel = YES;
        }
        wave26_log(@"pan: ended -> fire");
        g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
        g_panFired = YES;
        wave26_fire();
    } else if (state != UIGestureRecognizerStatePossible) {
        g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
    }
}
%end

// Kill the native lock->home icon "fly-in". SpringBoard reads this BOOL on the
// CoverSheet transition to decide whether to animate the icons flying into
// place; forcing NO drops them straight to their home positions so our wave
// engine owns the entrance animation exclusively.
//
// NOTE: this is installed at runtime via MSHookMessageEx in the constructor
// (see wave26_init), NOT a compile-time %hook. Speedster hooks this exact
// class+selector the same way and it works on-device, whereas our earlier
// Logos %hook apparently never bound (load-order: the CoverSheet class lookup
// Logos performs at our ctor time can miss). Resolving the class with
// objc_getClass + MSHookMessageEx at ctor time mirrors Speedster precisely.
static BOOL (*orig_iconsFlyIn)(id, SEL) = NULL;
static BOOL wave26_iconsFlyIn(id self, SEL _cmd) {
    wave26_log(@"iconsFlyIn queried -> forcing NO");
    return NO;
}

// The getter hook above was confirmed installed but NEVER invoked during a real
// unlock (logged via "iconsFlyIn queried" never appearing) — meaning whatever
// reads this flag during the transition does so by reading the ivar directly
// (self->_iconsFlyIn), not through the synthesized getter, so MSHookMessageEx on
// the getter can't intercept it. The setter writes that SAME ivar, though, so
// forcing every write to NO guarantees the ivar is NO by the time anything
// (getter OR direct ivar access) reads it — regardless of which path the
// consumer uses.
static void (*orig_setIconsFlyIn)(id, SEL, BOOL) = NULL;
static void wave26_setIconsFlyIn(id self, SEL _cmd, BOOL value) {
    wave26_log([NSString stringWithFormat:@"setIconsFlyIn: called value=%d -> forcing NO", value]);
    if (orig_setIconsFlyIn) orig_setIconsFlyIn(self, _cmd, NO);
}

// The cover sheet (lock screen) dismissal is the single most reliable unlock
// signal: it fires for EVERY unlock method — swipe-up, home-button, and
// AssistiveTouch — regardless of whether a pan gesture exists or the
// distributed lockstate notification arrives (which it never does on-device).
// SBLockScreenManager calls this when the cover sheet view controller is
// dismissed, i.e. when we've arrived home. We fire the wave here, after a short
// settle so the icons have reached their home positions.
// unlockWithRequest:completion: is a real instance method of SBLockScreenManager
// that fires for EVERY unlock (swipe, home-button, AssistiveTouch). We call %orig
// (the real unlock) then fire the wave after a short settle.
// Multiple unlock entry points exist; AT may use a different one than
// unlockWithRequest:. We hook several and log which fires, so we can identify
// the AT path. Each calls %orig then schedules the wave.
// unlockWithRequest:completion: is a real instance method of SBLockScreenManager
// that fires for EVERY unlock (swipe, home-button, AssistiveTouch). We call %orig
// (the real unlock) then fire the wave after a short settle.
static void (*orig_unlockWithRequest)(id, SEL, id, id) = NULL;
static void wave26_unlockWithRequest(id self, SEL _cmd, id request, id completion) {
    if (orig_unlockWithRequest) orig_unlockWithRequest(self, _cmd, request, completion);
    wave26_log(@"unlock: unlockWithRequest: fired");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
        wave26_fire();
    });
}
// SBLockStateAggregator._updateLockState is called whenever the lock state
// changes (lock OR unlock). It is a real instance method and fires for EVERY
// unlock method (swipe, home-button, AssistiveTouch) — more reliably than
// unlockWithRequest:, which is inconsistent for AT. We read the new state via
// the lockState getter; if it's unlocked (0), we fire the wave.
static void (*orig_updateLockState)(id, SEL) = NULL;
static void wave26_updateLockState(id self, SEL _cmd) {
    if (orig_updateLockState) orig_updateLockState(self, _cmd);
    SEL stateSel = NSSelectorFromString(@"lockState");
    if ([self respondsToSelector:stateSel]) {
        NSInteger state = ((NSInteger (*)(id, SEL))[self methodForSelector:stateSel])(self, stateSel);
        wave26_log([NSString stringWithFormat:@"lockstate: _updateLockState fired state=%ld", (long)state]);
        if (state == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
                wave26_fire();
            });
        }
    }
}


static void wave26_tracePreparedAnimator(id owner, SEL selector) {
    // Disabled for release: this dumped the animator's full method list
    // (class_copyMethodList) and call stack on every prepare call. Skip it all.
    (void)owner; (void)selector;
}

static void (*orig_preparePresentationAnimator)(id, SEL, BOOL) = NULL;
static void wave26_preparePresentationAnimator(id self, SEL cmd, BOOL presenting) {
    wave26_log([NSString stringWithFormat:@"flytrace: presentation prepare presenting=%d", presenting]);
    orig_preparePresentationAnimator(self, cmd, presenting);
    wave26_tracePreparedAnimator(self, cmd);
}

static void (*orig_prepareCoverAnimator)(id, SEL, BOOL) = NULL;
static void wave26_prepareCoverAnimator(id self, SEL cmd, BOOL includingLockScreen) {
    wave26_log([NSString stringWithFormat:@"flytrace: cover prepare includingLockScreen=%d", includingLockScreen]);
    orig_prepareCoverAnimator(self, cmd, includingLockScreen);
    wave26_tracePreparedAnimator(self, cmd);
}

// These signatures come from the device's concrete animator method dump.
// The native fly-in animator is driven by the presentation progress. We MUST
// hold the icons at their zoomed-out start (fraction 0.0) so that OUR wave
// engine owns the entrance animation. If we let the native fly-in run to
// completion first, the icons are already at home by the time we fire and our
// wave (home->home) is invisible. This is the one thing that makes the wave
// visible, so it is kept for ALL unlock methods (swipe-up, home-button, AT).
// Instead of holding the fly-in at fraction 0.0 (which leaves the icons at
// their zoomed-out start, so our wave's "home" anchor is wrong and the wave is
// invisible), we make the fly-in a NO-OP: don't call %orig at all. The icons
// then stay at their model position (true home), and our wave engine anchors to
// the real home and animates a visible entrance. We fire the wave from the
// unlock trigger; the fly-in can no longer clobber it because it does nothing.
static char g_flyProgressSampleKey;
static void (*orig_flyProgress)(id, SEL, double, CGPoint) = NULL;
static void wave26_flyProgress(id self, SEL cmd, double fraction, CGPoint center) {
    NSNumber *samples = objc_getAssociatedObject(self, &g_flyProgressSampleKey);
    NSUInteger count = samples.unsignedIntegerValue;
    if (count < 12) {
        wave26_log([NSString stringWithFormat:@"flyprogress: animator=%p requested=%.5f NOOP center=(%.1f,%.1f)",
                    (__bridge void *)self, fraction, center.x, center.y]);
        objc_setAssociatedObject(self, &g_flyProgressSampleKey, @(count + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Intentionally do NOT call orig_flyProgress. The fly-in is disabled so the
    // icons stay at their true home and our wave owns the entrance.
}

static void (*orig_flyDestination)(id, SEL, double, double, id) = NULL;
static void wave26_flyDestination(id self, SEL cmd, double fraction, double delay, id completion) {
    wave26_log([NSString stringWithFormat:@"flydestination: animator=%p target=%.5f delay=%.3f",
                (__bridge void *)self, fraction, delay]);
    orig_flyDestination(self, cmd, fraction, delay, completion);
}

%hook SBIconController

- (BOOL)hasAnimatedIconLayoutBefore {
    return YES;
}

- (BOOL)_shouldAnimateIconLaunch {
    return NO;
}

- (void)setRootFolderViewControllerPresentationProgress:(double)progress
                                      animated:(BOOL)animated
                                    completion:(id)completion {
    %orig(progress, NO, completion);
    wave26_log([NSString stringWithFormat:@"rootFolder progress=%.2f", progress]);
    // Fire the wave as soon as the home screen is substantially revealed.
    // This is the reliable unlock trigger for home-button / AssistiveTouch
    // unlocks (which never produce the pan gesture) and is a no-op for
    // swipe-up (the pan path already fired, so wave26_homeArrived returns).
    // We fire at 0.5 (NOT 0.99): by the time progress reaches 1.0 the native
    // fly-in is already finished and the icons are at rest, so we can no
    // longer own the entrance. At 0.5 the home screen is up and the icons are
    // close enough to their home positions to anchor the wave.
    if (progress >= 0.5) {
        wave26_homeArrived();
    }
}

%end

#pragma mark - Home-arrival detector (robust, no private method names)
//
// Polling-based unlock detection that works for EVERY unlock method (swipe-up,
// home button, AssistiveTouch) without depending on any private SpringBoard
// method name. It watches two observable facts:
//   1. Whether the home-screen icons are currently on-screen (frontmost).
//   2. Whether a lock-screen ("cover sheet") view is currently present.
// An unlock is the transition: cover sheet was present (locked) -> gone, and the
// home icons are now visible. We fire the wave on that transition.

static BOOL g_homeVisible = NO;      // home icons currently on-screen
static BOOL g_locked = NO;           // cover sheet (lock screen) currently present
static BOOL g_armed = NO;            // we saw a locked state, waiting for unlock
static dispatch_source_t g_watchTimer = nil;
static NSArray<Class> *g_coverClasses = nil;  // resolved once at init

// Single recursive pass that reports both whether a home icon and a cover-sheet
// (lock screen) view are present, so each tick is one hierarchy walk, not several.
static void wave26_scan(BOOL *outHome, BOOL *outCover) {
    *outHome = NO;
    *outCover = NO;
    for (UIWindow *win in allWindows()) {
        if (win.hidden || win.alpha < 0.5) continue;
        NSMutableArray *icons = [NSMutableArray array];
        wave26_collectViewsOfClass(g_iconClass, win, icons);
        for (UIView *v in icons) {
            if (!v.hidden && v.alpha > 0.5) { *outHome = YES; break; }
        }
        for (Class c in g_coverClasses) {
            NSMutableArray *found = [NSMutableArray array];
            wave26_collectViewsOfClass(c, win, found);
            if (found.count > 0) { *outCover = YES; break; }
        }
        if (*outHome && *outCover) return;
    }
}

// A brief "away" blip (cover-sheet peek, app-launch flash) must NOT arm the
// watcher, or releasing the peek would fire a false wave. A real lock/unlock or
// app visit keeps the device away for well over a second. We only arm once the
// away state has persisted past this threshold.
static const CFAbsoluteTime kAwayArmThreshold = 0.8;
static CFAbsoluteTime g_awaySince = 0;

static void wave26_watchTick(void) {
    BOOL home = NO, locked = NO;
    wave26_scan(&home, &locked);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // Arm only after the away state has persisted long enough. A cover-sheet
    // peek (pull the sheet down on home and release) is a brief away blip; we
    // must not arm on it or the release would fire a false wave.
    if (!home || locked) {
        if (g_awaySince == 0) g_awaySince = now;
        CFAbsoluteTime awayFor = now - g_awaySince;
        if (awayFor < kAwayArmThreshold) {
            // Too brief to be a real lock/app-visit; do not arm yet.
            return;
        }
        if (g_homeVisible || !g_armed) wave26_log(@"watch: armed (home icons absent / locked)");
        g_armed = YES;
        g_homeVisible = NO;
        g_locked = locked;
        g_panFired = NO;
        g_rootFired = NO;
        g_sheetMovedFired = NO;
        g_sheetSeenOnScreen = NO;
        return;
    }

    // home == YES here.
    g_awaySince = 0;
    g_sheetSeenOnScreen = NO;
    if (!g_armed) {
        // Never saw an "away" state (e.g. fresh boot already on home); just track.
        g_homeVisible = YES;
        g_locked = NO;
        return;
    }

    // Armed (icons had gone away). They're back -> we just arrived home: fire.
    // wave26_homeArrived (root-folder hook) will have already fired for a
    // home-button / AssistiveTouch unlock, so this is a no-op there.
    g_homeVisible = YES;
    g_locked = NO;
    g_armed = NO;
    wave26_log(@"watch: unlock/arrival detected (home icons returned)");
    // Let the settle finish a hair before we anchor the wave.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_panFired && !g_rootFired) wave26_fire();
    });
}

#pragma mark - Lock state notification

static void wave26_lockStateChanged(id note) {
    NSDictionary *info = [note userInfo];
    wave26_log([NSString stringWithFormat:@"lockstate note: info=%@", info]);

    // The distributed lockstate notification very often arrives with a nil or
    // empty userInfo (the "value" key is not reliably delivered across process
    // boundaries). The old code did `if (!info) return;`, which silently killed
    // the ENTIRE home-button / AssistiveTouch path (those never produce a pan, so
    // this notification was their only trigger). Instead of trusting userInfo,
    // treat any lockstate change as a possible unlock and decide by observing the
    // real screen: if the home icons are on-screen, we've arrived home -> fire.
    BOOL haveValue = (info != nil && info[@"value"] != nil);
    NSInteger val = haveValue ? [info[@"value"] integerValue] : -1;

    if (val == 1) {
        // Explicitly locked — reset state for next unlock.
        g_panFired = NO;
        g_sheetMovedFired = NO;
        g_rootFired = NO;
        return;
    }

    // val == 0 (explicit unlock) OR value unknown (nil userInfo). In both cases
    // check after a short settle whether the home screen is actually up and, if a
    // swipe-up pan didn't already fire, play the wave. wave26_fire's 0.5s
    // rate-limit dedupes against the pan / root-folder paths so this never
    // double-fires.
    if (!g_panFired) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (g_panFired) return;
                           BOOL home = NO, locked = NO;
                           wave26_scan(&home, &locked);
                           // Only fire if the home screen is genuinely visible; if
                           // the value was unknown and we're still locked/in an app
                           // this correctly does nothing.
                           if (home && !locked) {
                               wave26_fire();
                           }
                       });
    }
}

#pragma mark - Init

__attribute__((constructor))
static void wave26_init(void) {
    g_panClass  = NSClassFromString(@"SBCoverSheetScreenEdgePanGestureRecognizer");
    g_iconClass = NSClassFromString(@"SBIconView");
    g_dockClass = NSClassFromString(@"SBDockView");
    g_floatingDockClass = NSClassFromString(@"SBFloatingDockView");
    g_atNavClass = NSClassFromString(@"UIAccessibilityNavigation");
    g_sbClass = NSClassFromString(@"SpringBoard");
    NSMutableArray *covers = [NSMutableArray array];
    for (NSString *name in @[@"SBCoverSheet", @"SBCoverSheetController",
                             @"SBLockScreenView", @"SBCoverSheetBackgroundView",
                             @"SBCoverSheetView", @"SBCoverSheetPresentationManager",
                             @"SBLockScreen", @"SBCoverSheetTransitionSettings"]) {
        Class c = NSClassFromString(name);
        if (c) [covers addObject:c];
    }
    g_coverClasses = [covers copy];
    // (Init diagnostics — class/method dumps — disabled for release; they are
    // debug-only and the results are discarded when logging is off.)
    NSMutableArray *appLib = [NSMutableArray array];
    for (NSString *name in @[@"SBHLibraryCategoryPodIconListView",
                             @"SBHLibraryView",
                             @"SBRecommendationsPageView"]) {
        Class c = NSClassFromString(name);
        if (c && [c isSubclassOfClass:[UIView class]]) [appLib addObject:c];
    }
    g_appLibraryClasses = [appLib copy];
    g_isPad = wave26_isPad();
    g_engine = [[WaveEngine alloc] init];
    g_engine.isPad = g_isPad;
    {
        Class animator = NSClassFromString(@"SBCoverSheetIconFlyInAnimator");
        SEL progress = NSSelectorFromString(@"_setAnimationFraction:withCenter:");
        SEL destination = NSSelectorFromString(@"_animateToFraction:afterDelay:withSharedCompletion:");
        if (animator && class_getInstanceMethod(animator, progress)) {
            MSHookMessageEx(animator, progress, (IMP)wave26_flyProgress, (IMP *)&orig_flyProgress);
            wave26_log(@"flytrace: v277 concrete native fly-in endpoint hook installed");
        }
        if (animator && class_getInstanceMethod(animator, destination)) {
            MSHookMessageEx(animator, destination, (IMP)wave26_flyDestination, (IMP *)&orig_flyDestination);
            wave26_log(@"flytrace: v276 concrete animator destination trace installed");
        }
    }
    {
        Class manager = NSClassFromString(@"SBCoverSheetPresentationManager");
        SEL prepare = NSSelectorFromString(@"_prepareIconAnimatorForPresenting:");
        if (manager && class_getInstanceMethod(manager, prepare)) {
            MSHookMessageEx(manager, prepare, (IMP)wave26_preparePresentationAnimator,
                            (IMP *)&orig_preparePresentationAnimator);
            wave26_log(@"flytrace: v275 presentation preparation trace installed");
        }
        Class coverAnimator = NSClassFromString(@"SBCoverSheetAnimator");
        SEL coverPrepare = NSSelectorFromString(@"_prepareIconAnimatorIncludingLockScreen:");
        if (coverAnimator && class_getInstanceMethod(coverAnimator, coverPrepare)) {
            MSHookMessageEx(coverAnimator, coverPrepare, (IMP)wave26_prepareCoverAnimator,
                            (IMP *)&orig_prepareCoverAnimator);
            wave26_log(@"flytrace: v275 cover preparation trace installed");
        }
    }
    // The universal unlock trigger: hook SBLockScreenManager's cover-sheet
    // dismissal. This fires for EVERY unlock method (swipe, home-button,
    // AssistiveTouch) and is the reliable signal the pan/watcher paths lack for
    // AT.
    {
        Class lockMgr = NSClassFromString(@"SBLockScreenManager");
        // coverSheetViewControllerDidDismiss is a DELEGATE callback (called on the
        // manager's delegate, not on the manager itself), so it is not an instance
        // method of SBLockScreenManager and MSHookMessageEx can't bind it. Instead
        // hook unlockWithRequest:completion:, a real instance method that fires for
        // EVERY unlock (swipe, home-button, AssistiveTouch).
        // Hook several unlock entry points; log which fires so we can find the
        // AT path (unlockWithRequest: installed but never fired for AT).
        // Hook the unlock entry point. (The _finishUIUnlock / startUIUnlock
        // variants crashed SpringBoard into safe mode — their real signatures
        // don't match our (id,SEL,id,id) IMP — so we keep only unlockWithRequest:.)
        SEL s1 = NSSelectorFromString(@"unlockWithRequest:completion:");
        if (lockMgr && class_getInstanceMethod(lockMgr, s1)) {
            MSHookMessageEx(lockMgr, s1, (IMP)wave26_unlockWithRequest, (IMP *)&orig_unlockWithRequest);
            wave26_log(@"unlock: installed unlockWithRequest:");
        } else {
            wave26_log(@"unlock: unlockWithRequest: NOT FOUND");
        }
        // SBLockStateAggregator._updateLockState — fires on EVERY lock/unlock
        // state change, including AT. More reliable than unlockWithRequest:.
        Class lockAgg = NSClassFromString(@"SBLockStateAggregator");
        SEL s2 = NSSelectorFromString(@"_updateLockState");
        if (lockAgg && class_getInstanceMethod(lockAgg, s2)) {
            MSHookMessageEx(lockAgg, s2, (IMP)wave26_updateLockState, (IMP *)&orig_updateLockState);
            wave26_log(@"lockstate: installed _updateLockState");
        } else {
            wave26_log(@"lockstate: _updateLockState NOT FOUND");
        }
    }
    // Install the fly-in killer the same way Speedster does: resolve the class at
    // runtime and MSHookMessageEx its iconsFlyIn getter, rather than a Logos
    // %hook that may not bind at our load time. If the getter isn't present as a
    // real method (property synthesized without a discrete IMP), add our IMP so
    // the selector still returns NO.
    {
        Class flyCls = NSClassFromString(@"CSCoverSheetTransitionSettings");
        SEL sel = @selector(iconsFlyIn);
        if (flyCls && class_getInstanceMethod(flyCls, sel)) {
            MSHookMessageEx(flyCls, sel, (IMP)wave26_iconsFlyIn, (IMP *)&orig_iconsFlyIn);
            wave26_log(@"flyin: MSHookMessageEx installed on CSCoverSheetTransitionSettings iconsFlyIn");
        } else if (flyCls) {
            class_addMethod(flyCls, sel, (IMP)wave26_iconsFlyIn, "B@:");
            wave26_log(@"flyin: added iconsFlyIn IMP (no existing method)");
        } else {
            wave26_log(@"flyin: CSCoverSheetTransitionSettings NOT FOUND at init");
        }
        // Also hook the setter so whatever configures this settings object (and
        // writes the ivar directly via its own setter call) is forced to NO. This
        // catches the case where the ivar is read directly elsewhere, bypassing
        // our getter hook above entirely.
        SEL setSel = @selector(setIconsFlyIn:);
        if (flyCls && class_getInstanceMethod(flyCls, setSel)) {
            MSHookMessageEx(flyCls, setSel, (IMP)wave26_setIconsFlyIn, (IMP *)&orig_setIconsFlyIn);
            wave26_log(@"flyin: MSHookMessageEx installed on CSCoverSheetTransitionSettings setIconsFlyIn:");
        }
    }
    wave26_log([NSString stringWithFormat:@"init: panClass=%@ iconClass=%@ dockClass=%@ atNav=%@ sb=%@ cover=%lu appLib=%lu",
                g_panClass ? @"found" : @"nil",
                g_iconClass ? @"found" : @"nil",
                g_dockClass ? @"found" : @"nil",
                g_atNavClass ? @"found" : @"nil",
                g_sbClass ? @"found" : @"nil",
                (unsigned long)g_coverClasses.count,
                (unsigned long)g_appLibraryClasses.count]);
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:@"com.apple.springboard.lockstate"
                    object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                  wave26_lockStateChanged(note);
              }];
    // Robust unlock detector: poll lock/home state so the wave fires for every
    // unlock method (swipe-up, home button, AssistiveTouch). This is a FALLBACK
    // only — the lockstate hook and the pan are the primary triggers — so a slow
    // poll (500ms) is fine and avoids a constant 10x/s view-hierarchy walk that
    // causes lag. Each tick is one full recursive walk of every window.
    g_watchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_watchTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_watchTimer, ^{
        wave26_watchTick();
    });
    dispatch_resume(g_watchTimer);
    wave26_log(@"watch: timer started");
    wave26_scheduleFlyDiagnostics();
}
