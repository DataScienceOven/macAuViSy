#import <Foundation/Foundation.h>

@interface PrivateToggles : NSObject

+ (void)setNightShiftEnabled:(BOOL)enabled;
+ (void)setTrueToneEnabled:(BOOL)enabled;

+ (BOOL)isNightShiftEnabled;
+ (BOOL)isTrueToneEnabled;

+ (void)showVolumeOSD:(float)percentage isMuted:(BOOL)isMuted;
+ (void)showBrightnessOSD:(float)percentage;

@end
