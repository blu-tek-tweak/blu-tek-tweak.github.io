#import "WaveTable.h"

#pragma mark - Grid dimensions

static const NSInteger kCols = 4;
static const NSInteger kRows = 4;

#pragma mark - Wave map

// waveMap[row][col] -> wave (1 = first ... 4 = last). 0 = no button.
//
//        c0   c1   c2   c3
//  r0   [ 3] [ 2] [ 3] [ 0]
//  r1   [ 2] [ 1] [ 2] [ 0]
//  r2   [ 3] [ 2] [ 3] [ 0]
//  r3   [ 0] [ 4] [ 0] [ 0]
static const NSInteger kWaveMap[4][4] = {
    /* r0 */ { 3, 2, 3, 0 },
    /* r1 */ { 2, 1, 2, 0 },
    /* r2 */ { 3, 2, 3, 0 },
    /* r3 */ { 0, 4, 0, 0 },
};

#pragma mark - Per-wave stagger

// The bottom-center button (wave 4) lands a beat after the 3x3 digit cluster
// has settled, mirroring the 26Unlock center-out ripple.
static const NSTimeInterval kWaveDelays[5] = {
    0.0,    // wave 0 (unused)
    0.0,    // wave 1 (center pair)
    0.055,  // wave 2 (ring)
    0.110,  // wave 3 (corners)
    0.180,  // wave 4 (bottom center)
};

@implementation WaveTable

+ (NSInteger)waveForCol:(NSInteger)col row:(NSInteger)row {
    if (col < 0 || col >= kCols || row < 0 || row >= kRows) return 0;
    return kWaveMap[row][col];
}

+ (NSTimeInterval)delayForWave:(NSInteger)wave {
    if (wave < 1 || wave > 4) return 0.0;
    return kWaveDelays[wave];
}

+ (CGPoint)center {
    return CGPointMake((kCols - 1) * 0.5, (kRows - 1) * 0.5);
}

+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row {
    return col >= 0 && col < kCols && row >= 0 && row < kRows;
}

@end
