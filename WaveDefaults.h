#import <Foundation/Foundation.h>

// Device snapshot, 2026-11-08. Shared by the engine and Settings so resetting
// preferences restores the same tuning shown by the sliders.
static NSDictionary<NSString *, NSNumber *> *Wave26DefaultPreferences(void) {
    static NSDictionary *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = @{
            @"experimentalFlyIn": @NO,
            @"w13_dampingMax": @26.69999885559082,
            @"w13_dampingMin": @23.23333168029785,
            @"w13_mass": @71.75232696533203,
            @"w13_stiffness": @194.91400146484375,
            @"w13_velocity": @5.0,
            @"w47_dampingMax": @23.566665649414062,
            @"w47_dampingMin": @19.5,
            @"w47_mass": @1.501,
            @"w47_stiffness": @151.2899932861328,
            @"w47_velocity": @0.95,
            @"w89_dampingMax": @17.0333309173584,
            @"w89_dampingMin": @13.966666221618652,
            @"w89_mass": @1.501,
            @"w89_stiffness": @70.42599487304688,
            @"w89_velocity": @0.803,
            @"w1_delay": @(-0.0343),
            @"w2_delay": @0.03,
            @"w3_delay": @0.0197,
            @"w4_delay": @(-0.07099999487400055),
            @"w5_delay": @0.071,
            @"w6_delay": @(-0.05966669321060181),
            @"w7_delay": @0.0703,
            @"w8_delay": @(-0.08566668629646301),
            @"w9_delay": @0.071,
        };
    });
    return defaults;
}
