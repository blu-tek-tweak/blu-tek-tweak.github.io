#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Grid + wave-map selection.
//
// iPhone: a single 4 (col) x 6 (row) map, origin top-left (0,0), center (1.5, 2.5).
// iPad:   a 5 (col) x 6 (row) map. Two variants are provided — "horizontal" and
//         "vertical" — selected by the device's current orientation. The caller
//         (Tweak.xm) picks the variant at fire time and passes it here.
typedef NS_ENUM(NSInteger, WaveOrientation) {
    WaveOrientationVertical   = 0,  // portrait  (taller than wide)
    WaveOrientationHorizontal = 1,  // landscape (wider than tall)
};

@interface WaveTable : NSObject

// Grid dimensions for a given device idiom + orientation. iPhone = 4x6
// (orientation-agnostic). iPad vertical = 5x6; iPad horizontal = 6x5.
+ (NSInteger)colsForIsPad:(BOOL)isPad orientation:(WaveOrientation)orientation;
+ (NSInteger)rowsForIsPad:(BOOL)isPad orientation:(WaveOrientation)orientation;

// The wave (1..N) for a (col,row) cell. For iPhone the orientation is ignored.
// For iPad, orientation selects the horizontal vs vertical 5x6 map.
+ (NSInteger)waveForCol:(NSInteger)col
                    row:(NSInteger)row
                isPad:(BOOL)isPad
           orientation:(WaveOrientation)orientation;

+ (NSTimeInterval)microOffsetForCol:(NSInteger)col
                               row:(NSInteger)row
                           isPad:(BOOL)isPad
                      orientation:(WaveOrientation)orientation;

+ (NSTimeInterval)delayForCol:(NSInteger)col
                         row:(NSInteger)row
                 waveInterval:(NSTimeInterval)interval
                        isPad:(BOOL)isPad
                   orientation:(WaveOrientation)orientation;

// Grid center (in cell units) for a given idiom + orientation.
+ (CGPoint)centerForIsPad:(BOOL)isPad orientation:(WaveOrientation)orientation;

+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row isPad:(BOOL)isPad;

@end

NS_ASSUME_NONNULL_END
