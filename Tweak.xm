#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import "WaveEngine.h"
#import "WaveTable.h"

static void pc_log(NSString *msg) {
    static FILE *f = NULL;
    if (!f) f = fopen("/var/mobile/Library/26Passcode.log", "a");
    if (f) { fprintf(f, "[%s] %s\n", __TIME__, msg.UTF8String); fflush(f); }
}

#pragma mark - State

static WaveEngine *g_engine = nil;
static Class g_buttonClass = nil;
static Class g_lightButtonClass = nil;
static CFAbsoluteTime g_lastPlayTime = 0;
static UIView *g_animatingView = nil;
static CADisplayLink *g_displayLink = nil;

// Forward declaration
static void pc_fire(void);

// Trampoline for CADisplayLink.
static void pc_displayLinkTick(void) {
    if (!g_displayLink) return;
    if (g_animatingView && g_animatingView.alpha >= 0.95) {
        pc_log(@"display link: firing");
        [g_displayLink invalidate];
        g_displayLink = nil;
        g_animatingView = nil;
        pc_fire();
    }
}

@interface _PCDisplayLinkTrampoline : NSObject
- (void)tick:(CADisplayLink *)link;
@end
@implementation _PCDisplayLinkTrampoline
- (void)tick:(CADisplayLink *)link {
    pc_displayLinkTick();
}
@end

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
static NSArray<UIWindow *> *allWindows(void) {
    return [[UIApplication sharedApplication] windows];
}
#pragma GCC diagnostic pop

static void pc_collectButtons(UIView *view, NSMutableArray *out) {
    if (!g_buttonClass && !g_lightButtonClass) return;
    if ((g_buttonClass && [view isKindOfClass:g_buttonClass]) ||
        (g_lightButtonClass && [view isKindOfClass:g_lightButtonClass])) {
        [out addObject:view];
        return;
    }
    for (UIView *sub in view.subviews) {
        pc_collectButtons(sub, out);
    }
}

static NSMutableArray *collectButtons(void) {
    NSMutableArray *buttons = [NSMutableArray array];
    if (!g_buttonClass && !g_lightButtonClass) return buttons;
    for (UIWindow *win in allWindows()) {
        if (win.hidden || win.alpha < 0.5) continue;
        pc_collectButtons(win, buttons);
    }
    // Only buttons that are actually on-screen.
    NSMutableArray *visible = [NSMutableArray array];
    for (UIView *v in buttons) {
        if (v.hidden || v.alpha < 0.5) continue;
        if (!v.window) continue;
        [visible addObject:v];
    }
    return visible;
}

#pragma mark - Grid binning

// Bin the on-screen passcode buttons into the 4x3 grid.
static void pc_registerGrid(NSArray *buttons) {
    [g_engine clearButtons];
    if (buttons.count == 0) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat cx[16], cy[16];
    NSInteger n = 0;
    for (UIView *v in buttons) {
        if (n >= 16) break;
        CGRect f = [v convertRect:v.bounds toView:nil];
        if (CGRectIsNull(f)) continue;
        cx[n] = CGRectGetMidX(f);
        cy[n] = CGRectGetMidY(f);
        n++;
    }
    if (n == 0) return;

    // Cluster x-centers into column bands.
    CGFloat xs[16];
    for (NSInteger i = 0; i < n; i++) xs[i] = cx[i];
    for (NSInteger i = 1; i < n; i++) {
        CGFloat key = xs[i]; NSInteger j = i - 1;
        while (j >= 0 && xs[j] > key) { xs[j + 1] = xs[j]; j--; }
        xs[j + 1] = key;
    }
    CGFloat spanX = MAX(1.0, xs[n - 1] - xs[0]);
    NSInteger gridCols = 4;
    CGFloat colGap = (spanX / gridCols) * 0.5;
    CGFloat colBandSum[16]; NSInteger colBandCount[16]; NSInteger colBandN = 0;
    colBandSum[0] = xs[0]; colBandCount[0] = 1;
    for (NSInteger i = 1; i < n; i++) {
        if (xs[i] - xs[i - 1] > colGap) { colBandN++; colBandSum[colBandN] = xs[i]; colBandCount[colBandN] = 1; }
        else { colBandSum[colBandN] += xs[i]; colBandCount[colBandN]++; }
    }
    CGFloat colMean[16];
    for (NSInteger i = 0; i <= colBandN; i++) colMean[i] = colBandSum[i] / colBandCount[i];
    NSInteger colCount = colBandN + 1;
    if (colCount > gridCols) colCount = gridCols;
    CGFloat colPitch = 0;
    for (NSInteger i = 1; i < colCount; i++) colPitch += (colMean[i] - colMean[i - 1]);
    if (colCount > 1) colPitch /= (colCount - 1);
    if (colPitch < 1) colPitch = spanX / MAX(1, colCount);
    CGFloat gridLeft = (screen.size.width - gridCols * colPitch) * 0.5;
    if (gridLeft < 0) gridLeft = 0;

    // Cluster y-centers into row bands.
    CGFloat ys[16];
    for (NSInteger i = 0; i < n; i++) ys[i] = cy[i];
    for (NSInteger i = 1; i < n; i++) {
        CGFloat key = ys[i]; NSInteger j = i - 1;
        while (j >= 0 && ys[j] > key) { ys[j + 1] = ys[j]; j--; }
        ys[j + 1] = key;
    }
    CGFloat spanY = MAX(1.0, ys[n - 1] - ys[0]);
    NSInteger gridRows = 4;
    CGFloat rowGap = (spanY / gridRows) * 0.5;
    CGFloat rowBandSum[16]; NSInteger rowBandCount[16]; NSInteger rowBandN = 0;
    rowBandSum[0] = ys[0]; rowBandCount[0] = 1;
    for (NSInteger i = 1; i < n; i++) {
        if (ys[i] - ys[i - 1] > rowGap) { rowBandN++; rowBandSum[rowBandN] = ys[i]; rowBandCount[rowBandN] = 1; }
        else { rowBandSum[rowBandN] += ys[i]; rowBandCount[rowBandN]++; }
    }
    CGFloat rowMean[16];
    for (NSInteger i = 0; i <= rowBandN; i++) rowMean[i] = rowBandSum[i] / rowBandCount[i];
    NSInteger rowCount = rowBandN + 1;
    if (rowCount > gridRows) rowCount = gridRows;
    CGFloat rowPitch = 0;
    for (NSInteger i = 1; i < rowCount; i++) rowPitch += (rowMean[i] - rowMean[i - 1]);
    if (rowCount > 1) rowPitch /= (rowCount - 1);
    if (rowPitch < 1) rowPitch = spanY / MAX(1, rowCount);
    CGFloat minTopEdge = INFINITY;
    for (NSInteger i = 0; i < n; i++) {
        UIView *v = buttons[i];
        CGRect f = [v convertRect:v.bounds toView:nil];
        minTopEdge = MIN(minTopEdge, CGRectGetMinY(f));
    }
    CGFloat gridTop = minTopEdge;

    // Assign each button to its cell.
    for (NSInteger i = 0; i < n; i++) {
        UIView *v = buttons[i];
        CGRect f = [v convertRect:v.bounds toView:nil];
        CGFloat vx = CGRectGetMidX(f), vy = CGRectGetMidY(f);
        NSInteger c = (colPitch > 0) ? (NSInteger)floor((vx - gridLeft) / colPitch) : 0;
        NSInteger r = (rowPitch > 0) ? (NSInteger)floor((vy - gridTop) / rowPitch) : 0;
        if (c < 0) c = 0; if (c >= gridCols) c = gridCols - 1;
        if (r < 0) r = 0; if (r >= gridRows) r = gridRows - 1;
        [g_engine registerButton:v col:c row:r];
    }
}

#pragma mark - Play

static void pc_fire(void) {
    if (!g_engine) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastPlayTime < 0.5) return;
    g_lastPlayTime = now;

    [g_engine reset];

    // Collect the buttons from all windows.
    NSArray *buttons = collectButtons();
    pc_log([NSString stringWithFormat:@"fire: buttons=%lu", (unsigned long)buttons.count]);
    if (buttons.count == 0) return;

    pc_registerGrid(buttons);

    // Strip any in-flight animation on the buttons' layers before adding ours.
    for (UIView *v in buttons) {
        [v.layer removeAllAnimations];
    }

    // Suppress the native animations for the duration of our animation.
    [g_engine startNativeAnimationSuppression:buttons];

    [g_engine play];
}

#pragma mark - Hooks

static void pc_buttonDidMoveToWindow(UIView *button) {
    if (button.window) {
        // Find the animating view: walk up from the button, find the plain UIView
        // that's between SBUIPasscodeLockNumberPad and SBUIPasscodeLockViewSimpleFixedDigitKeypad.
        UIView *v = button.superview;
        while (v) {
            NSString *cls = [NSString stringWithUTF8String:class_getName(object_getClass((id)v))];
            if ([cls isEqualToString:@"UIView"]) {
                g_animatingView = v;
                break;
            }
            v = v.superview;
        }
        // Start the display link to poll the animating view.
        if (g_animatingView && !g_displayLink) {
            _PCDisplayLinkTrampoline *tramp = [[_PCDisplayLinkTrampoline alloc] init];
            g_displayLink = [CADisplayLink displayLinkWithTarget:tramp
                                                      selector:@selector(tick:)];
            [g_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                               forMode:NSRunLoopCommonModes];
        }
    } else {
        // Button removed from window: reset the state so the next presentation
        // can trigger the animation again.
        if (g_displayLink) {
            [g_displayLink invalidate];
            g_displayLink = nil;
        }
        g_animatingView = nil;
    }
}

%hook SBPasscodeNumberPadButton

- (void)didMoveToWindow {
    %orig;
    pc_buttonDidMoveToWindow((UIView *)self);
}

%end

%hook SBLightPasscodeNumberPadButton

- (void)didMoveToWindow {
    %orig;
    pc_buttonDidMoveToWindow((UIView *)self);
}

%end

#pragma mark - Init

__attribute__((constructor))
static void pc_init(void) {
    g_buttonClass = NSClassFromString(@"SBPasscodeNumberPadButton");
    g_lightButtonClass = NSClassFromString(@"SBLightPasscodeNumberPadButton");
    g_engine = [[WaveEngine alloc] init];
}
