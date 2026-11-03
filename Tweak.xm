#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

@end
@interface YTSettingsGroupData : NSObject
@property (nonatomic, assign) NSInteger type;
@end

static NSString *const kEnabledKey = @"YTLG_enabled";
static const NSInteger kLGSection = 7878; // custom settings category id

static BOOL LGEnabled(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kEnabledKey];
    return v ? [v boolValue] : YES;
}

#pragma mark - Liquid Glass (YouTube's built-in implementation, switched on)

static id LGMakeGlassEffect(void) {
    Class c = NSClassFromString(@"UIGlassEffect"); // iOS 26+
    return c ? [[c alloc] init] : nil;
}

%hook YTColdConfig
- (BOOL)mainAppCoreClientIos27EnableLiquidGlass { return LGEnabled() ? YES : %orig; }
- (BOOL)mainAppCoreClientIosEnablePositionedFloatyBars { return LGEnabled() ? YES : %orig; }
%end

%hook YTColdConfigMainAppCoreClientImpl
- (BOOL)ios27EnableLiquidGlass { return LGEnabled() ? YES : %orig; }
- (BOOL)iosEnablePositionedFloatyBars { return LGEnabled() ? YES : %orig; }
%end

%hook M3CLiquidGlass
+ (BOOL)isLiquidGlassAvailable { return LGEnabled() ? YES : %orig; }
+ (BOOL)computeIsLiquidGlassAvailable { return LGEnabled() ? YES : %orig; }
%end

%hook YTPivotBarView
- (id)liquidGlassEffect {
    id e = %orig;
    return (e || !LGEnabled()) ? e : LGMakeGlassEffect();
}
- (id)liquidGlassEffectForPageStyle:(NSInteger)style {
    id e = %orig;
    return (e || !LGEnabled()) ? e : LGMakeGlassEffect();
}
%end

#pragma mark - Settings toggle

static void LGBuildSettings(id manager) {
    @try {
        Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
        id vc = [manager valueForKey:@"_settingsViewControllerDelegate"];
        SEL itemSel = NSSelectorFromString(@"switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:");
        if (!itemClass || !vc || ![itemClass respondsToSelector:itemSel]) return;

        BOOL (^switchBlock)(id, BOOL) = ^BOOL(id cell, BOOL enabled) {
            [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabledKey];
            return YES;
        };
        id item = ((id (*)(Class, SEL, NSString *, NSString *, NSString *, BOOL, id, int))objc_msgSend)(
            itemClass, itemSel,
            @"Liquid Glass",
            @"Turns on YouTube's built-in Liquid Glass. Restart YouTube to apply.",
            nil, LGEnabled(), switchBlock, 0);
        if (!item) return;
        NSMutableArray *items = [NSMutableArray arrayWithObject:item];

        SEL withIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
        SEL noIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:titleDescription:headerHidden:");
        if ([vc respondsToSelector:withIcon]) {
            id icon = [NSClassFromString(@"YTIIcon") new];
            ((void (*)(id, SEL, NSMutableArray *, NSInteger, NSString *, id, NSString *, BOOL))objc_msgSend)(
                vc, withIcon, items, kLGSection, @"Liquid Glass", icon, nil, NO);
        } else if ([vc respondsToSelector:noIcon]) {
            ((void (*)(id, SEL, NSMutableArray *, NSInteger, NSString *, NSString *, BOOL))objc_msgSend)(
                vc, noIcon, items, kLGSection, @"Liquid Glass", nil, NO);
        }
    } @catch (__unused NSException *e) {}
}

%hook YTSettingsGroupData
- (NSArray *)orderedCategories {
    NSArray *orig = %orig;
    if (self.type != 1 || [orig containsObject:@(kLGSection)]) return orig;
    NSMutableArray *m = [orig mutableCopy];
    [m insertObject:@(kLGSection) atIndex:0];
    return m;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    if ([order containsObject:@(kLGSection)]) return order;
    NSMutableArray *m = [order mutableCopy];
    NSUInteger idx = [order indexOfObject:@(1)];
    if (idx != NSNotFound) [m insertObject:@(kLGSection) atIndex:idx + 1];
    else [m addObject:@(kLGSection)];
    return m;
}
%end

%hook YTSettingsSectionItemManager
- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == (NSUInteger)kLGSection) {
        LGBuildSettings(self);
        return;
    }
    %orig;
}
%end

#pragma mark - Google sign-in fix for sideloaded builds

static NSString *LGAccessGroup(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"bundleSeedID",
            (__bridge id)kSecAttrService: @"",
            (__bridge id)kSecReturnAttributes: @YES
        };
        CFDictionaryRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecItemNotFound)
            status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecSuccess && result) {
            NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;
            cached = attrs[(__bridge id)kSecAttrAccessGroup];
        }
    });
    return cached;
}

%hook SSOConfiguration
- (BOOL)shouldEnableSafariSignIn { return YES; }
- (BOOL)temporarilyDisableSafariSignIn { return NO; }
- (void)setTemporarilyDisableSafariSignIn:(BOOL)arg1 { %orig(NO); }
%end

%hook SSOKeychainHelper
+ (id)accessGroup { return LGAccessGroup(); }
+ (id)sharedAccessGroup { return LGAccessGroup(); }
%end

%hook SSOKeychainCore
+ (id)accessGroup { return LGAccessGroup(); }
+ (id)sharedAccessGroup { return LGAccessGroup(); }
%end

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (LGEnabled() && self == NSBundle.mainBundle &&
        [key isEqualToString:@"UIDesignRequiresCompatibility"]) {
        return @NO;
    }
    return %orig;
}
- (NSString *)bundleIdentifier {
    NSArray *addrs = [NSThread callStackReturnAddresses];
    if (addrs.count > 2) {
        Dl_info info;
        if (dladdr((void *)[addrs[2] unsignedLongLongValue], &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            if ([path hasPrefix:NSBundle.mainBundle.bundlePath]) {
                return @"com.google.ios.youtube";
            }
        }
    }
    return %orig;
}
%end
