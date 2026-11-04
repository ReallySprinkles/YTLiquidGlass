#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <sys/utsname.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define LG_VERSION  @"1.0 Beta 2"
#define LG_DEV_NAME @"gloop"
#define LG_DEV_URL  @"https://github.com/ReallySprinkles"

// Private YouTube classes, declared by hand.
@interface YTPivotBarView : UIView
@end
@interface YTPivotBarItemView : UIView
@end
@interface YTSettingsCell : UIView
@end
@interface YTSettingsGroupData : NSObject
@property (nonatomic, assign) NSInteger type;
@end

static NSString *const kYTID       = @"com.google.ios.youtube";
static NSString *const kYTName     = @"YouTube";
static NSString *const kDesignKey  = @"UIDesignRequiresCompatibility";
static NSString *const kEnabledKey = @"YTLG_enabled";
static NSString *const kTypeKey    = @"YTLG_glassType";
static NSString *const kInertID    = @"YTLGInertItem";
static NSString *const kDevID      = @"YTLGDeveloperItem";
static const NSInteger kLGSection  = 7878;

enum { LGTypeNative = 0, LGTypeYouTube = 1 };

#pragma mark - Preferences
// Hooks use a snapshot taken at launch (gOn / gType). The settings page edits the saved
// values, which take effect after a restart. Hooks never touch NSUserDefaults themselves,
// because NSBundle hooks can run while NSUserDefaults is still starting up.

static BOOL gOn = YES;
static NSInteger gType = LGTypeYouTube;
static BOOL gSpoofBundle = NO;

static BOOL LGPrefOn(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kEnabledKey];
    return v ? [v boolValue] : YES;
}
static NSInteger LGPrefType(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kTypeKey];
    return v ? [v integerValue] : LGTypeYouTube;
}
static BOOL LGHasGlassEffect(void) { return NSClassFromString(@"UIGlassEffect") != Nil; }
static BOOL LGNative(void)         { return gOn && gType == LGTypeNative && LGHasGlassEffect(); }
static BOOL LGYouTubeGlass(void)   { return gOn && gType == LGTypeYouTube && LGHasGlassEffect(); }

#pragma mark - YouTube's own glass (type: YouTube)

%hook YTColdConfig
- (BOOL)mainAppCoreClientIos27EnableLiquidGlass {
    return gOn ? LGYouTubeGlass() : %orig;
}
- (BOOL)mainAppCoreClientIosEnablePositionedFloatyBars {
    return gOn ? LGYouTubeGlass() : %orig;
}
- (NSInteger)mainAppCoreClientIosFloatingBarStyle {
    return gOn ? (LGYouTubeGlass() ? 2 : 0) : %orig;
}
%end

%hook YTColdConfigMainAppCoreClientImpl
- (BOOL)ios27EnableLiquidGlass {
    return gOn ? LGYouTubeGlass() : %orig;
}
- (BOOL)iosEnablePositionedFloatyBars {
    return gOn ? LGYouTubeGlass() : %orig;
}
- (NSInteger)iosFloatingBarStyle {
    return gOn ? (LGYouTubeGlass() ? 2 : 0) : %orig;
}
%end

%hook M3CLiquidGlass
+ (BOOL)isLiquidGlassAvailable { return LGYouTubeGlass() ? YES : %orig; }
+ (BOOL)computeIsLiquidGlassAvailable { return LGYouTubeGlass() ? YES : %orig; }
%end

#pragma mark - Native glass tab bar (type: Native)
// YouTube's glass is switched off and the tab bar gets a real iOS UIGlassEffect capsule
// with a selection pill behind the tab items.

static const void *kGlassKey = &kGlassKey;
static const void *kPillKey  = &kPillKey;
static const void *kFadedKey = &kFadedKey;
static const void *kSelKey   = &kSelKey;

static BOOL LGContainsItem(UIView *view) {
    static Class itemClass;
    if (!itemClass) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (!itemClass) return NO;
    if ([view isKindOfClass:itemClass]) return YES;
    for (UIView *s in view.subviews) if (LGContainsItem(s)) return YES;
    return NO;
}

static void LGCollectItems(UIView *view, NSMutableArray<UIView *> *out) {
    static Class itemClass;
    if (!itemClass) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass && [view isKindOfClass:itemClass]) { [out addObject:view]; return; }
    for (UIView *s in view.subviews) LGCollectItems(s, out);
}

static NSArray<UIView *> *LGSortedItems(UIView *bar) {
    NSMutableArray<UIView *> *all = [NSMutableArray array];
    LGCollectItems(bar, all);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *v in all) if (!v.hidden && CGRectGetWidth(v.bounds) > 0) [visible addObject:v];
    [visible sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat x = CGRectGetMinX([a convertRect:a.bounds toView:bar]);
        CGFloat y = CGRectGetMinX([b convertRect:b.bounds toView:bar]);
        return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
    }];
    return visible;
}

static BOOL LGItemSelected(UIView *item) {
    id stored = objc_getAssociatedObject(item, kSelKey);
    if (stored) return [stored boolValue];
    SEL s = NSSelectorFromString(@"isSelected");
    if ([item respondsToSelector:s] && ((BOOL (*)(id, SEL))objc_msgSend)(item, s)) return YES;
    return (item.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
}

static BOOL LGLooksLikeScrubber(UIView *view, NSUInteger depth) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    for (NSString *w in @[@"scrub", @"progress", @"playerbar", @"slider", @"seek", @"timebar"]) {
        if ([name containsString:w]) return YES;
    }
    if (depth == 0) return NO;
    for (UIView *s in view.subviews) if (LGLooksLikeScrubber(s, depth - 1)) return YES;
    return NO;
}

static NSHashTable<UIView *> *LGFaded(UIView *bar) {
    NSHashTable *t = objc_getAssociatedObject(bar, kFadedKey);
    if (!t) {
        t = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(bar, kFadedKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return t;
}

static UIView *LGBlurView(UIView *bar) {
    SEL s = NSSelectorFromString(@"blurView");
    return [bar respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(bar, s) : nil;
}

static UIVisualEffect *LGMakeGlassEffect(void) {
    Class c = NSClassFromString(@"UIGlassEffect");
    if (!c) return nil;
    SEL withStyle = NSSelectorFromString(@"effectWithStyle:");
    if ([c respondsToSelector:withStyle]) {
        return ((id (*)(Class, SEL, NSInteger))objc_msgSend)(c, withStyle, 0);
    }
    return [c new];
}

static UIColor *LGPillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.0 alpha:0.35]
            : [UIColor colorWithWhite:0.0 alpha:0.07];
    }];
}

static void LGRemoveNativeBar(UIView *bar) {
    UIView *glass = objc_getAssociatedObject(bar, kGlassKey);
    if (!glass) return;
    [glass removeFromSuperview];
    objc_setAssociatedObject(bar, kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bar, kPillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGBlurView(bar).hidden = NO;
    for (UIView *v in LGFaded(bar).allObjects) v.alpha = 1.0;
    [LGFaded(bar) removeAllObjects];
}

static void LGApplyNativeBar(UIView *bar) {
    CGFloat barW = CGRectGetWidth(bar.bounds), barH = CGRectGetHeight(bar.bounds);
    if (barW <= 0 || barH <= 0) return;

    UIVisualEffectView *glass = objc_getAssociatedObject(bar, kGlassKey);
    if (!glass) {
        UIVisualEffect *effect = LGMakeGlassEffect();
        if (!effect) return;
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = NO;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Get YouTube's own backdrop out of the way.
    LGBlurView(bar).hidden = YES;
    NSHashTable<UIView *> *faded = LGFaded(bar);
    for (UIView *sib in bar.subviews) {
        if (sib == glass) continue;
        if (LGContainsItem(sib)) {
            sib.opaque = NO;
            sib.backgroundColor = UIColor.clearColor;
        } else if (sib.alpha > 0 && !LGLooksLikeScrubber(sib, 3) &&
                   (CGRectGetHeight(sib.frame) >= barH * 0.6 || CGRectGetHeight(sib.frame) <= 1.5)) {
            sib.alpha = 0;
            [faded addObject:sib];
        }
    }
    bar.backgroundColor = UIColor.clearColor;
    bar.layer.backgroundColor = UIColor.clearColor.CGColor;
    bar.opaque = NO;
    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;
    if (glass.superview != bar) [bar insertSubview:glass atIndex:0];
    else [bar sendSubviewToBack:glass];

    // Capsule geometry
    NSArray<UIView *> *items = LGSortedItems(bar);
    NSUInteger n = items.count;
    CGFloat itemH = MAX(barH - bar.safeAreaInsets.bottom, 44.0);
    CGFloat capH = itemH + 14.0;
    CGFloat capTop = MIN(0.0, barH - capH - 4.0);
    CGFloat capW = barW - 40.0;
    if (n > 0 && n <= 4) capW = MIN(capW, 88.0 * n + 16.0);
    CGRect cap = CGRectMake((barW - capW) * 0.5, capTop, capW, capH);
    glass.frame = cap;
    glass.layer.cornerRadius = capH * 0.5;

    // Spread the tab items evenly inside the capsule
    CGFloat slot = n ? (capW - 8.0) / (CGFloat)n : 0;
    for (NSUInteger i = 0; i < n; i++) {
        UIView *item = items[i];
        if (!item.superview) continue;
        CGRect cur = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(cap.origin.x + 4.0 + slot * i,
                                   CGRectGetMidY(cap) - CGRectGetHeight(cur) * 0.5,
                                   slot, CGRectGetHeight(cur));
        CGRect local = [bar convertRect:target toView:item.superview];
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), CGRectIntegral(local))) item.frame = local;
    }

    // Selection pill, drawn on the glass behind the items
    UIView *pill = objc_getAssociatedObject(bar, kPillKey);
    if (!pill) {
        pill = [UIView new];
        pill.userInteractionEnabled = NO;
        pill.backgroundColor = LGPillColor();
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, kPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (pill.superview != glass.contentView) [glass.contentView addSubview:pill];

    NSUInteger selIndex = NSNotFound;
    for (NSUInteger i = 0; i < n; i++) if (LGItemSelected(items[i])) { selIndex = i; break; }
    if (selIndex == NSNotFound) {
        pill.hidden = YES;
    } else {
        CGRect target = CGRectMake(4.0 + slot * selIndex + 2.0, 4.0, MAX(slot - 4.0, 20.0), capH - 8.0);
        BOOL animate = !pill.hidden && !CGRectIsEmpty(pill.frame) && !CGRectEqualToRect(pill.frame, target);
        pill.hidden = NO;
        pill.layer.cornerRadius = target.size.height * 0.5;
        if (animate) {
            [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ pill.frame = target; } completion:nil];
        } else {
            pill.frame = target;
        }
    }
}

%hook YTPivotBarView
- (id)liquidGlassEffect {
    id v = %orig;
    return LGNative() ? nil : v;
}
- (id)liquidGlassEffectForPageStyle:(NSInteger)style {
    id v = %orig;
    return LGNative() ? nil : v;
}
- (void)setFloatingBarStyle:(NSInteger)style {
    if (LGNative() && style == 2) style = 0;
    %orig(style);
}
- (void)layoutSubviews {
    %orig;
    if (LGNative()) LGApplyNativeBar(self);
    else LGRemoveNativeBar(self);
}
%end

%hook YTPivotBarItemView
- (void)setSelected:(BOOL)selected {
    %orig;
    objc_setAssociatedObject(self, kSelKey, @(selected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (LGNative() && selected) {
        UIView *v = self.superview;
        while (v && ![NSStringFromClass(v.class) isEqualToString:@"YTPivotBarView"]) v = v.superview;
        [v setNeedsLayout];
    }
}
%end

%hook YTPivotBarViewController
- (BOOL)isFrostedPivotBarPermitted { return LGNative() ? YES : %orig; }
%end

%hook YTSearchResultsViewController
- (BOOL)optOutOfFrostedPivotBar { return LGNative() ? NO : %orig; }
%end

#pragma mark - Settings helpers

static NSString *LGTypeName(NSInteger t) { return t == LGTypeNative ? @"Native" : @"YouTube"; }

static NSString *LGInfoLine(void) {
    struct utsname u;
    uname(&u);
    NSString *model = [NSString stringWithUTF8String:u.machine] ?: @"iOS Device";
    NSString *yt = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"Unknown";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: kYTID;
    NSString *ios = UIDevice.currentDevice.systemVersion ?: @"?";
    return [NSString stringWithFormat:@"YTLiquidGlass %@  \u2022  YouTube %@  \u2022  %@  \u2022  %@  \u2022  iOS %@",
            LG_VERSION, yt, bid, model, ios];
}

// A YTIIcon that shows an arbitrary UIImage (so rows can carry SF Symbols).
static const void *kIconImageKey = &kIconImageKey;

static UIImage *LGSquare(UIImage *image) {
    if (!image) return nil;
    CGFloat side = MAX(image.size.width, image.size.height);
    if (side <= 0) return image;
    UIGraphicsImageRendererFormat *f = UIGraphicsImageRendererFormat.preferredFormat;
    f.opaque = NO;
    f.scale = image.scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake((side - image.size.width) / 2, (side - image.size.height) / 2,
                                     image.size.width, image.size.height)];
    }];
}

static id LGIconWithStyle(id self_, SEL _cmd, long long style) {
    return [objc_getAssociatedObject(self_, kIconImageKey)
            imageWithTintColor:UIColor.labelColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}
static id LGIconWithColor(id self_, SEL _cmd, UIColor *color) {
    return [objc_getAssociatedObject(self_, kIconImageKey)
            imageWithTintColor:(color ?: UIColor.labelColor) renderingMode:UIImageRenderingModeAlwaysOriginal];
}
static id LGIconWithSelected(id self_, SEL _cmd, BOOL selected) {
    return [objc_getAssociatedObject(self_, kIconImageKey)
            imageWithTintColor:UIColor.labelColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}
static id LGIconPlain(id self_, SEL _cmd) {
    return [objc_getAssociatedObject(self_, kIconImageKey)
            imageWithTintColor:UIColor.labelColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static Class LGIconClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"YTIIcon");
        if (!base) return;
        cls = objc_allocateClassPair(base, "YTLGSettingIcon", 0);
        if (!cls) return;
        class_addMethod(cls, NSSelectorFromString(@"iconImageWithPageStyle:"), (IMP)LGIconWithStyle, "@24@0:8q16");
        class_addMethod(cls, NSSelectorFromString(@"delhiIconImageWithPageStyle:"), (IMP)LGIconWithStyle, "@24@0:8q16");
        class_addMethod(cls, NSSelectorFromString(@"iconImageWithColor:"), (IMP)LGIconWithColor, "@24@0:8@16");
        class_addMethod(cls, NSSelectorFromString(@"newIconImageWithColor:"), (IMP)LGIconWithColor, "@24@0:8@16");
        class_addMethod(cls, NSSelectorFromString(@"iconImageWithSelected:"), (IMP)LGIconWithSelected, "@20@0:8B16");
        class_addMethod(cls, NSSelectorFromString(@"delhiIconImageWithSelected:"), (IMP)LGIconWithSelected, "@20@0:8B16");
        class_addMethod(cls, NSSelectorFromString(@"iconImageForContextMenu"), (IMP)LGIconPlain, "@16@0:8");
        objc_registerClassPair(cls);
    });
    return cls;
}

static id LGMakeIcon(NSString *symbol) {
    Class c = LGIconClass();
    UIImage *img = LGSquare([UIImage systemImageNamed:symbol]);
    if (!c || !img) return nil;
    id icon = [c new];
    objc_setAssociatedObject(icon, kIconImageKey, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL setType = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:setType]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setType, 44);
    return icon;
}

static id LGPlainItem(NSString *title, NSString *desc, NSString *ident,
                      NSString *(^detail)(void), BOOL (^select)(id, NSUInteger)) {
    Class c = NSClassFromString(@"YTSettingsSectionItem");
    SEL s5 = NSSelectorFromString(@"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    SEL s4 = NSSelectorFromString(@"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    id d = detail ? [detail copy] : nil;
    id s = select ? [select copy] : nil;
    if ([c respondsToSelector:s5]) {
        return ((id (*)(Class, SEL, id, id, id, id, id))objc_msgSend)(c, s5, title, desc, ident, d, s);
    }
    if ([c respondsToSelector:s4]) {
        return ((id (*)(Class, SEL, id, id, id, id))objc_msgSend)(c, s4, title ?: desc, ident, d, s);
    }
    return nil;
}

static void LGMakeInert(id item) {
    for (NSString *name in @[@"setInkEnabled:", @"setEnabled:", @"setSettingEnabled:"]) {
        SEL s = NSSelectorFromString(name);
        if ([item respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
    }
}

static void LGReload(id vc) {
    SEL s = NSSelectorFromString(@"reloadData");
    if (vc && [vc respondsToSelector:s]) ((void (*)(id, SEL))objc_msgSend)(vc, s);
}

static void LGPromptRestart(UIViewController *vc) {
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart required"
        message:@"Close and reopen YouTube for this change to take effect."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Close YouTube" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { exit(0); }]];
    [vc presentViewController:a animated:YES completion:nil];
}

// Dropdown: YouTube's own bottom sheet with a checkmark on the current choice.
static void LGPresentChoice(UIViewController *presenter, NSArray<NSString *> *titles,
                            NSUInteger selected, void (^handler)(NSUInteger)) {
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    Class sheetClass = NSClassFromString(@"YTDefaultSheetController");
    SEL makeAction = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    SEL add = NSSelectorFromString(@"addAction:");
    SEL present = NSSelectorFromString(@"presentFromViewController:animated:completion:");
    id sheet = nil;
    if (sheetClass && [actionClass respondsToSelector:makeAction]) {
        SEL init = NSSelectorFromString(@"initWithSheetStyle:headerTitle:headerSubtitle:shouldDisableLogging:delegate:parentResponder:");
        SEL make = NSSelectorFromString(@"sheetControllerWithMessage:subMessage:delegate:parentResponder:");
        if ([sheetClass instancesRespondToSelector:init]) {
            sheet = ((id (*)(id, SEL, NSInteger, id, id, BOOL, id, id))objc_msgSend)(
                [sheetClass alloc], init, 2, nil, nil, NO, nil, nil);
        } else if ([sheetClass respondsToSelector:make]) {
            sheet = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(sheetClass, make, nil, nil, nil, nil);
        }
    }
    if (sheet && [sheet respondsToSelector:add] && [sheet respondsToSelector:present]) {
        UIImage *check = [[UIImage systemImageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24, 24)];
        UIImage *blank = [[r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {}]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        [titles enumerateObjectsUsingBlock:^(NSString *t, NSUInteger i, BOOL *stop) {
            id block = [^(__unused id a) { if (handler) handler(i); } copy];
            id action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                actionClass, makeAction, t, i == selected ? check : blank, 0, block);
            if (action) ((void (*)(id, SEL, id))objc_msgSend)(sheet, add, action);
        }];
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(sheet, present, presenter, YES, nil);
        return;
    }
    // Fallback: plain iOS action sheet
    UIAlertController *sh = [UIAlertController alertControllerWithTitle:nil message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [titles enumerateObjectsUsingBlock:^(NSString *t, NSUInteger i, BOOL *stop) {
        UIAlertAction *a = [UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *x) { if (handler) handler(i); }];
        @try { [a setValue:@(i == selected) forKey:@"checked"]; } @catch (__unused NSException *e) {}
        [sh addAction:a];
    }];
    [sh addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sh.popoverPresentationController.sourceView = presenter.view;
    sh.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                                             CGRectGetMidY(presenter.view.bounds), 1, 1);
    [presenter presentViewController:sh animated:YES completion:nil];
}

static void LGBuildSettings(id manager) {
    @try {
        Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
        id vc = [manager valueForKey:@"_settingsViewControllerDelegate"];
        SEL switchSel = NSSelectorFromString(@"switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:");
        if (!itemClass || !vc || ![itemClass respondsToSelector:switchSel]) return;

        __weak id weakManager = manager;
        __weak id weakVC = vc;
        NSMutableArray *items = [NSMutableArray array];

        // 1) Liquid Glass switch
        BOOL (^switchBlock)(id, BOOL) = ^BOOL(id cell, BOOL enabled) {
            [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabledKey];
            dispatch_async(dispatch_get_main_queue(), ^{
                id m = weakManager;
                if (m) { LGBuildSettings(m); LGReload(weakVC); }
                LGPromptRestart(weakVC);
            });
            return YES;
        };
        id sw = ((id (*)(Class, SEL, NSString *, NSString *, NSString *, BOOL, id, int))objc_msgSend)(
            itemClass, switchSel, @"Liquid Glass",
            @"Turns on Liquid Glass in YouTube.", nil, LGPrefOn(), [switchBlock copy], 0);
        if (sw) [items addObject:sw];

        // 2) Liquid Glass Type (only while Liquid Glass is on)
        if (LGPrefOn()) {
            id type = LGPlainItem(@"Liquid Glass Type", nil, nil,
                ^NSString *{ return LGTypeName(LGPrefType()); },
                ^BOOL(id cell, NSUInteger idx) {
                    UIViewController *v = weakVC;
                    if (!v) return NO;
                    LGPresentChoice(v, @[@"Native", @"YouTube"], (NSUInteger)LGPrefType(), ^(NSUInteger choice) {
                        [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)choice forKey:kTypeKey];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            LGReload(weakVC);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{ LGPromptRestart(weakVC); });
                        });
                    });
                    return YES;
                });
            if (type) [items addObject:type];
        }

        // 3) ABOUT
        id header = LGPlainItem(nil, @"ABOUT", kInertID, nil, nil);
        LGMakeInert(header);
        if (header) [items addObject:header];

        id dev = LGPlainItem(LG_DEV_NAME, @"Developer", kDevID,
            ^NSString *{ return @"\u203A"; },
            ^BOOL(id cell, NSUInteger idx) {
                NSURL *url = [NSURL URLWithString:LG_DEV_URL];
                if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
                return YES;
            });
        SEL setIcon = NSSelectorFromString(@"setSettingIcon:");
        id personIcon = LGMakeIcon(@"person.crop.circle");
        if (dev && personIcon && [dev respondsToSelector:setIcon]) {
            ((void (*)(id, SEL, id))objc_msgSend)(dev, setIcon, personIcon);
        }
        if (dev) [items addObject:dev];

        id footer = LGPlainItem(nil, LGInfoLine(), kInertID, nil, nil);
        LGMakeInert(footer);
        if (footer) [items addObject:footer];

        SEL withIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
        SEL noIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:titleDescription:headerHidden:");
        if ([vc respondsToSelector:withIcon]) {
            id icon = LGMakeIcon(@"drop") ?: [NSClassFromString(@"YTIIcon") new];
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

// Text-only rows (ABOUT header and the info footer) must not react to taps.
// Cells are reused, so interaction is reset on every layout.
%hook YTSettingsCell
- (void)layoutSubviews {
    %orig;
    self.userInteractionEnabled = ![self.accessibilityIdentifier isEqualToString:kInertID];
}
%end

#pragma mark - Bundle identity (Info.plist) + Liquid Glass design opt-in

static NSString *LGRealBundleID(void) {
    CFStringRef s = CFBundleGetIdentifier(CFBundleGetMainBundle()); // CF level: not hooked
    return s ? (__bridge NSString *)s : nil;
}

%hook NSBundle
+ (NSBundle *)bundleWithIdentifier:(NSString *)identifier {
    if (gSpoofBundle && [identifier isEqualToString:kYTID]) return NSBundle.mainBundle;
    return %orig;
}
- (NSString *)bundleIdentifier {
    if (gSpoofBundle && self == NSBundle.mainBundle) return kYTID;
    return %orig;
}
- (NSDictionary *)infoDictionary {
    NSDictionary *info = %orig;
    if (!info || self != NSBundle.mainBundle) return info;
    BOOL strip = gOn && info[kDesignKey] != nil;
    if (!gSpoofBundle && !strip) return info;
    NSMutableDictionary *m = [info mutableCopy];
    if (strip) [m removeObjectForKey:kDesignKey];
    if (gSpoofBundle) {
        m[@"CFBundleIdentifier"] = kYTID;
        m[@"CFBundleDisplayName"] = kYTName;
        m[@"CFBundleName"] = kYTName;
    }
    return m;
}
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (self == NSBundle.mainBundle) {
        if (gOn && [key isEqualToString:kDesignKey]) return nil;
        if (gSpoofBundle) {
            if ([key isEqualToString:@"CFBundleIdentifier"]) return kYTID;
            if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) return kYTName;
        }
    }
    return %orig;
}
%end

#pragma mark - Google sign-in fix for sideloaded builds

static NSString *LGAccessGroup(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"YTLGProbe",
            (__bridge id)kSecAttrService: @"YTLGProbeService",
            (__bridge id)kSecReturnAttributes: @YES
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecItemNotFound) status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
        if (status == errSecDuplicateItem) status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result) {
            NSDictionary *attrs = CFBridgingRelease(result);
            id g = attrs[(__bridge id)kSecAttrAccessGroup];
            if ([g isKindOfClass:NSString.class]) cached = [g copy];
        } else if (result) {
            CFRelease(result);
        }
    });
    return cached;
}

%group Sideload

%hook YTVersionUtils
+ (NSString *)appName { return kYTName; }
+ (NSString *)appID { return kYTID; }
%end

%hook SSOConfiguration
- (BOOL)shouldEnableSafariSignIn { return YES; }
- (BOOL)temporarilyDisableSafariSignIn { return NO; }
- (void)setTemporarilyDisableSafariSignIn:(BOOL)disabled { %orig(NO); }
- (id)initWithClientID:(id)clientID supportedAccountServices:(id)services {
    id me = %orig;
    if (me) {
        @try {
            [me setValue:kYTName forKey:@"_shortAppName"];
            [me setValue:kYTID forKey:@"_applicationIdentifier"];
        } @catch (__unused NSException *e) {}
    }
    return me;
}
%end

%hook SSOClientLogin
+ (id)defaultSourceString { return kYTID; }
%end

%hook SSOKeychainHelper
+ (id)accessGroup { return LGAccessGroup(); }
+ (id)sharedAccessGroup { return LGAccessGroup(); }
%end

%hook SSOKeychainCore
+ (id)accessGroup { return LGAccessGroup(); }
+ (id)sharedAccessGroup { return LGAccessGroup(); }
%end

%hook UICKeyChainStore
- (id)accessGroup { return LGAccessGroup(); }
%end

// Sideloaded apps have no app-group entitlement; give them a private folder instead of nil.
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSURL *orig = %orig;
    if (orig || ![groupIdentifier containsString:@"group."]) return orig;
    NSURL *support = [[self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] lastObject];
    if (!support) return nil;
    NSURL *dir = [[support URLByAppendingPathComponent:@"AppGroups" isDirectory:YES]
                  URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    [self createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
%end

// "Is this the App Store build?" checks
%hook GULAppEnvironmentUtil
+ (BOOL)isFromAppStore { return YES; }
%end

%hook APMAEU
+ (BOOL)isFAS { return YES; }
%end

%end // group Sideload

#pragma mark - Startup

%ctor {
    // Snapshot preferences once, before any hook can run.
    gOn = LGPrefOn();
    gType = LGPrefType();

    NSString *receipt = NSBundle.mainBundle.appStoreReceiptURL.path;
    BOOL sideloaded = receipt.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:receipt];
    NSString *real = LGRealBundleID();
    gSpoofBundle = sideloaded && real.length && ![real isEqualToString:kYTID];

    // Let iOS use its new design: drop the opt-out key from the live Info.plist dictionary.
    if (gOn) {
        id info = (__bridge id)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
        if ([info respondsToSelector:@selector(removeObjectForKey:)]) {
            @try { [info removeObjectForKey:kDesignKey]; } @catch (__unused NSException *e) {}
        }
    }

    %init;
    if (sideloaded) {
        LGAccessGroup();
        %init(Sideload);
    }
}
