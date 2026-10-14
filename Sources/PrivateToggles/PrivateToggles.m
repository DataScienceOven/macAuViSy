#import "PrivateToggles.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@implementation PrivateToggles

+ (void)setNightShiftEnabled:(BOOL)enabled {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
    if (handle) {
        Class CBBlueLightClientClass = NSClassFromString(@"CBBlueLightClient");
        if (CBBlueLightClientClass) {
            id client = [[CBBlueLightClientClass alloc] init];
            SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
            if ([client respondsToSelector:setEnabledSel]) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[client methodSignatureForSelector:setEnabledSel]];
                [inv setSelector:setEnabledSel];
                [inv setTarget:client];
                [inv setArgument:&enabled atIndex:2];
                [inv invoke];
            }
            SEL setActiveSel = NSSelectorFromString(@"setActive:");
            if ([client respondsToSelector:setActiveSel]) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[client methodSignatureForSelector:setActiveSel]];
                [inv setSelector:setActiveSel];
                [inv setTarget:client];
                [inv setArgument:&enabled atIndex:2];
                [inv invoke];
            }
        }
    }
}

+ (void)setTrueToneEnabled:(BOOL)enabled {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
    if (handle) {
        Class CBTrueToneClientClass = NSClassFromString(@"CBTrueToneClient");
        if (CBTrueToneClientClass) {
            id client = [[CBTrueToneClientClass alloc] init];
            SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
            if ([client respondsToSelector:setEnabledSel]) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[client methodSignatureForSelector:setEnabledSel]];
                [inv setSelector:setEnabledSel];
                [inv setTarget:client];
                [inv setArgument:&enabled atIndex:2];
                [inv invoke];
            }
        }
    }
}

+ (BOOL)isTrueToneEnabled {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
    if (handle) {
        Class CBTrueToneClientClass = NSClassFromString(@"CBTrueToneClient");
        if (CBTrueToneClientClass) {
            id client = [[CBTrueToneClientClass alloc] init];
            SEL sel = NSSelectorFromString(@"enabled");
            if ([client respondsToSelector:sel]) {
                BOOL (*func)(id, SEL) = (BOOL (*)(id, SEL))[client methodForSelector:sel];
                return func(client, sel);
            }
        }
    }
    return NO;
}

+ (BOOL)isNightShiftEnabled {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
    if (handle) {
        Class CBBlueLightClientClass = NSClassFromString(@"CBBlueLightClient");
        if (CBBlueLightClientClass) {
            id client = [[CBBlueLightClientClass alloc] init];
            struct {
                int active;
                int enabled;
                int sunSchedule;
                int dayStartHour, dayStartMinute;
                int dayEndHour, dayEndMinute;
                int mode;
                int schedule;
                int disableForPeriod;
                int warningCCT, defaultCCT, minCCT, maxCCT, midCCT;
            } status;
            memset(&status, 0, sizeof(status));
            SEL sel = NSSelectorFromString(@"getBlueLightStatus:");
            if ([client respondsToSelector:sel]) {
                BOOL (*func)(id, SEL, void *) = (BOOL (*)(id, SEL, void *))[client methodForSelector:sel];
                if (func(client, sel, &status)) {
                    return (status.enabled != 0 || (status.active & 1) != 0);
                }
            }
        }
    }
    return NO;
}


+ (void)showVolumeOSD:(float)percentage isMuted:(BOOL)isMuted {
    static void *osdHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        osdHandle = dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW);
    });
    
    Class OSDManagerClass = NSClassFromString(@"OSDManager");
    if (!OSDManagerClass) return;
    
    id manager = [OSDManagerClass performSelector:NSSelectorFromString(@"sharedManager")];
    if (!manager) return;
    
    SEL showImageSel = NSSelectorFromString(@"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:");
    if (![manager respondsToSelector:showImageSel]) return;
    
    NSMethodSignature *sig = [manager methodSignatureForSelector:showImageSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:showImageSel];
    [inv setTarget:manager];
    
    int64_t imageID = isMuted ? 2 : 1;
    uint32_t displayID = CGMainDisplayID();
    uint32_t priority = 500;
    uint32_t msecUntilFade = 1000;
    uint32_t totalChiclets = 16;
    uint32_t filledChiclets = isMuted ? 0 : (uint32_t)roundf(fmaxf(0.0f, fminf(1.0f, percentage)) * 16.0f);
    BOOL locked = NO;
    
    [inv setArgument:&imageID atIndex:2];
    [inv setArgument:&displayID atIndex:3];
    [inv setArgument:&priority atIndex:4];
    [inv setArgument:&msecUntilFade atIndex:5];
    [inv setArgument:&filledChiclets atIndex:6];
    [inv setArgument:&totalChiclets atIndex:7];
    [inv setArgument:&locked atIndex:8];
    
    [inv invoke];
}

+ (void)showBrightnessOSD:(float)percentage {
    static void *osdHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        osdHandle = dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW);
    });
    
    Class OSDManagerClass = NSClassFromString(@"OSDManager");
    if (!OSDManagerClass) return;
    
    id manager = [OSDManagerClass performSelector:NSSelectorFromString(@"sharedManager")];
    if (!manager) return;
    
    SEL showImageSel = NSSelectorFromString(@"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:");
    if (![manager respondsToSelector:showImageSel]) return;
    
    NSMethodSignature *sig = [manager methodSignatureForSelector:showImageSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:showImageSel];
    [inv setTarget:manager];
    
    int64_t imageID = 3;
    uint32_t displayID = CGMainDisplayID();
    uint32_t priority = 500;
    uint32_t msecUntilFade = 1000;
    uint32_t totalChiclets = 16;
    uint32_t filledChiclets = (uint32_t)roundf(fmaxf(0.0f, fminf(1.0f, percentage)) * 16.0f);
    BOOL locked = NO;
    
    [inv setArgument:&imageID atIndex:2];
    [inv setArgument:&displayID atIndex:3];
    [inv setArgument:&priority atIndex:4];
    [inv setArgument:&msecUntilFade atIndex:5];
    [inv setArgument:&filledChiclets atIndex:6];
    [inv setArgument:&totalChiclets atIndex:7];
    [inv setArgument:&locked atIndex:8];
    
    [inv invoke];
}

@end
