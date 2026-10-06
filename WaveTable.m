#import "WaveTable.h"

#pragma mark - Grid dimensions

// iPhone: 4 (col) x 6 (row), orientation-agnostic.
// iPad:   VERTICAL (portrait)  = 5 (col) x 6 (row).
//         HORIZONTAL (landscape) = 6 (col) x 5 (row)  (the vertical map rotated 90°).
static const NSInteger kIPhoneCols = 4;
static const NSInteger kIPhoneRows = 6;
static const NSInteger kIPadVerticalCols   = 5;
static const NSInteger kIPadVerticalRows   = 6;
static const NSInteger kIPadHorizontalCols = 6;
static const NSInteger kIPadHorizontalRows = 5;

#pragma mark - iPhone wave map (4 x 6)

// waveMap[row][col]  ->  entry wave (1 = first ... 9 = last)
//
//        c0  c1  c2  c3
//  r0   [7] [6] [6] [7]
//  r1   [5] [4] [4] [5]
//  r2   [3] [1] [1] [3]
//  r3   [2] [1] [1] [2]   <- (1,3)(2,3) get an extra "earlier" micro offset
//  r4   [3] [1] [1] [3]
//  r5   [5] [4] [4] [5]
static const NSInteger kIPhoneWaveMap[6][4] = {
    /* r0 */ { 9, 8, 8, 9 },
    /* r1 */ { 7, 6, 6, 7 },
    /* r2 */ { 3, 1, 1, 3 },
    /* r3 */ { 2, 1, 1, 2 },
    /* r4 */ { 3, 1, 1, 3 },
    /* r5 */ { 5, 4, 4, 5 },
};

#pragma mark - iPad wave maps

// Two maps for the iPad, selected by orientation.
//
// VERTICAL (portrait):  5 (col) x 6 (row).  TALLER than wide.
// HORIZONTAL (landscape): 6 (col) x 5 (row).  WIDER than tall.
//
// The HORIZONTAL map is the VERTICAL map ROTATED 90°. Defined in its final
// landscape orientation (6 columns x 5 rows).
//
// Both maps are a concentric, center-out layout: wave 1 is the central 2x2
// (vertical) / 2x4 (horizontal) block, wave 2 the ring around it, etc. The
// iPad's grid is odd-width, so the center is a single column (vertical) or
// single row (horizontal) — the 2x2 core straddles that center line.

// HORIZONTAL (landscape): 6 (col) x 5 (row) — derived from a recording of a
// real iPad unlock. 10 concentric rings, center-out; the center 2x2 core
// (wave 3) expands out to wave 9 at the corners.
//
//        c0  c1  c2  c3  c4  c5
//  r0   [9] [8] [7] [7] [8] [9]
//  r1   [7] [6] [5] [5] [6] [7]
//  r2   [5] [4] [3] [3] [4] [5]
//  r3   [7] [6] [5] [5] [6] [7]
//  r4   [9] [8] [7] [7] [8] [9]
static const NSInteger kIPadHorizontalWaveMap[5][6] = {
    /* r0 */ { 10, 9, 8, 8, 9, 10 },
    /* r1 */ { 7, 4, 2, 2, 4, 7 },
    /* r2 */ { 6, 3, 1, 1, 3, 6 },
    /* r3 */ { 6, 3, 1, 1, 3, 6 },
    /* r4 */ { 7, 5, 2, 2, 5, 7 },
};

// VERTICAL (portrait): 5 (col) x 6 (row). 10 concentric rings, center-out.
// The 5-wide grid has 2 distinct columns on each side of the center (cols 0/1
// left, 3/4 right) and 3 distinct rows (0/1/2 top, 3/4/5 bottom) -> 2x3 = 6
// rings + the 2x2 core = 10 waves.
//
//        c0  c1  c2  c3  c4
//  r0   [10] [9] [8] [9] [10]
//  r1   [8] [7] [6] [7] [8]
//  r2   [6] [5] [4] [5] [6]
//  r3   [6] [5] [4] [5] [6]
//  r4   [8] [7] [6] [7] [8]
//  r5   [10] [9] [8] [9] [10]
static const NSInteger kIPadVerticalWaveMap[6][5] = {
    /* r0 */ { 10, 9, 8, 9, 10 },
    /* r1 */ { 6, 4, 2, 4, 6 },
    /* r2 */ { 3, 1, 1, 1, 3 },
    /* r3 */ { 2, 1, 1, 1, 2 },
    /* r4 */ { 5, 3, 2, 3, 5 },
    /* r5 */ { 8, 7, 6, 7, 8 },
};

#pragma mark - Per-idiom delay ("early") tuning

// The base interval between successive waves.
static const NSTimeInterval kIPhoneWaveInterval = 0.055;
static const NSTimeInterval kIPadWaveInterval   = 0.050;  // 50ms between waves

// iPhone "early" offsets (pull a wave band earlier to tighten a gap).
static const NSTimeInterval kIPhoneWave3Early = 0.015;
static const NSTimeInterval kIPhoneWave4Early = 0.255;
static const NSTimeInterval kIPhoneWave5Early = 0.025;
static const NSTimeInterval kIPhoneWave6Early = 0.010;
static const NSTimeInterval kIPhoneWave7Early = 0.025;
static const NSTimeInterval kIPhoneWave8Early = 0.165;

// iPad "early" offsets. With the 50ms base interval and a pure (w-1)*50ms
// schedule, each wave w fires at exactly (w-1)*50ms — i.e. wave 1 at 0ms,
// wave 2 at 50ms, ... wave 10 at 450ms. No per-wave "early" offset is needed.
static const NSTimeInterval kIPadWave3Early  = 0.0;
static const NSTimeInterval kIPadWave4Early  = 0.0;
static const NSTimeInterval kIPadWave5Early  = 0.0;
static const NSTimeInterval kIPadWave6Early  = 0.0;
static const NSTimeInterval kIPadWave7Early  = 0.0;
static const NSTimeInterval kIPadWave8Early  = 0.0;
static const NSTimeInterval kIPadWave9Early  = 0.0;
static const NSTimeInterval kIPadWave10Early = 0.0;

// Per-idiom micro offsets (a hair earlier/later for specific cells).
// iPhone: W5 top pair (0,1)(3,1) a hair later than the bottom pair (0,5)(3,5).
static NSTimeInterval kIPhoneMicroOffset(NSInteger col, NSInteger row) {
    if (row == 1 && (col == 0 || col == 3)) return 0.015;
    return 0.0;
}
// iPad: no per-cell micro offsets for now (a uniform 50ms-per-wave schedule).
static NSTimeInterval kIPadMicroOffset(NSInteger col, NSInteger row, WaveOrientation orientation) {
    (void)col; (void)row; (void)orientation;
    return 0.0;
}

#pragma mark - Helpers

static NSTimeInterval waveIntervalForIsPad(BOOL isPad) {
    return isPad ? kIPadWaveInterval : kIPhoneWaveInterval;
}

@implementation WaveTable

+ (NSInteger)colsForIsPad:(BOOL)isPad orientation:(WaveOrientation)orientation {
    if (!isPad) return kIPhoneCols;
    return (orientation == WaveOrientationHorizontal) ? kIPadHorizontalCols
                                                     : kIPadVerticalCols;
}

+ (NSInteger)rowsForIsPad:(BOOL)isPad orientation:(WaveOrientation)orientation {
    if (!isPad) return kIPhoneRows;
    return (orientation == WaveOrientationHorizontal) ? kIPadHorizontalRows
                                                     : kIPadVerticalRows;
}

+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row isPad:(BOOL)isPad {
    // Orientation-agnostic validity: accept the union of the iPad's two
    // orientations (max cols = 6, max rows = 6). The specific orientation's
    // waveForCol: returns 0 for out-of-bounds cells for that orientation.
    NSInteger cols = isPad ? kIPadHorizontalCols : kIPhoneCols;  // 6 (max for iPad)
    NSInteger rows = isPad ? kIPadVerticalRows   : kIPhoneRows;  // 6 (max for iPad)
    return col >= 0 && col < cols && row >= 0 && row < rows;
}

+ (NSInteger)waveForCol:(NSInteger)col
                    row:(NSInteger)row
                isPad:(BOOL)isPad
           orientation:(WaveOrientation)orientation {
    if (!isPad) {
        if (col < 0 || col >= kIPhoneCols || row < 0 || row >= kIPhoneRows) return 0;
        return kIPhoneWaveMap[row][col];
    }
    // iPad: bounds-check against THIS orientation's map shape (vertical 5x6,
    // horizontal 6x5) — the two maps are different sizes.
    if (orientation == WaveOrientationHorizontal) {
        if (col < 0 || col >= kIPadHorizontalCols || row < 0 || row >= kIPadHorizontalRows) return 0;
        return kIPadHorizontalWaveMap[row][col];
    }
    if (col < 0 || col >= kIPadVerticalCols || row < 0 || row >= kIPadVerticalRows) return 0;
    return kIPadVerticalWaveMap[row][col];
}

+ (NSTimeInterval)microOffsetForCol:(NSInteger)col
                               row:(NSInteger)row
                           isPad:(BOOL)isPad
                      orientation:(WaveOrientation)orientation {
    if (isPad) return kIPadMicroOffset(col, row, orientation);
    return kIPhoneMicroOffset(col, row);
}

+ (NSTimeInterval)delayForCol:(NSInteger)col
                         row:(NSInteger)row
                 waveInterval:(NSTimeInterval)interval
                        isPad:(BOOL)isPad
                   orientation:(WaveOrientation)orientation {
    NSInteger w = [self waveForCol:col row:row isPad:isPad orientation:orientation];
    if (w == 0) return 0.0;
    // Use the per-idiom base interval if the caller passed 0 (default).
    NSTimeInterval base = (interval > 0) ? interval : waveIntervalForIsPad(isPad);
    NSTimeInterval d = (w - 1) * base + [self microOffsetForCol:col row:row isPad:isPad orientation:orientation];

    // Per-idiom "early" offsets.
    if (isPad) {
        if (w >= 3) d -= kIPadWave3Early;
        if (w >= 4) d -= kIPadWave4Early;
        if (w >= 5) d -= kIPadWave5Early;
        if (w >= 6) d -= kIPadWave6Early;
        if (w >= 7) d -= kIPadWave7Early;
        if (w >= 8) d -= kIPadWave8Early;
        if (w >= 9) d -= kIPadWave9Early;
        if (w >= 10) d -= kIPadWave10Early;
    } else {
        if (w >= 3) d -= kIPhoneWave3Early;
        if (w >= 4) d -= kIPhoneWave4Early;
        if (w >= 5) d -= kIPhoneWave5Early;
        if (w >= 6) d -= kIPhoneWave6Early;
        if (w >= 7) d -= kIPhoneWave7Early;
        if (w >= 8) d -= kIPhoneWave8Early;
    }
    return d;
}

+ (CGPoint)centerForIsPad:(BOOL)isPad orientation:(WaveOrientation)orientation {
    // Grid center in cell units. iPhone 4x6 -> (1.5, 2.5).
    // iPad vertical 5x6 -> (2.0, 2.5); iPad horizontal 6x5 -> (2.5, 2.0).
    NSInteger cols = [self colsForIsPad:isPad orientation:orientation];
    NSInteger rows = [self rowsForIsPad:isPad orientation:orientation];
    return CGPointMake((cols - 1) * 0.5, (rows - 1) * 0.5);
}

@end
