#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Passcode pad wave map.
//
// The passcode pad is a 4 (col) x 3 (row) grid of SBPasscodeNumberPadButton:
//
//        c0   c1   c2   c3
//  r0   [ 3] [ 2] [ 3] [  ]
//  r1   [ 2] [ 1] [ 2] [  ]
//  r2   [ 3] [ 2] [ 3] [  ]
//  r3   [  ] [ 4] [  ] [  ]
//
// 4 waves, center-out: wave 1 = the two center digit buttons, wave 2 = the
// ring around them, wave 3 = the outer corners, wave 4 = the bottom-center
// button (backspace/enter).
typedef NS_ENUM(NSInteger, PasscodeWave) {
    PasscodeWave1 = 1,
    PasscodeWave2 = 2,
    PasscodeWave3 = 3,
    PasscodeWave4 = 4,
};

@interface WaveTable : NSObject

// The wave (1..4) for a (col,row) cell of the 4x3 passcode pad.
+ (NSInteger)waveForCol:(NSInteger)col row:(NSInteger)row;

// Per-wave stagger (seconds). Wave 1 starts at 0; later waves land after it.
+ (NSTimeInterval)delayForWave:(NSInteger)wave;

// Grid center in cell units: (1.5, 1.5).
+ (CGPoint)center;

+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row;

@end

NS_ASSUME_NONNULL_END
