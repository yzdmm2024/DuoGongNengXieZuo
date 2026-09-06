#import <Preferences/Preferences.h>
#import <objc/runtime.h>

#define KS_SUITE @"com.yzdmm.keyboardstatus"
// 与 Tweak.xm 里监听的同名 darwin 通知：面板改值 → tweak 实时刷新
#define KS_DARWIN_NOTI "com.yzdmm.keyboardstatus.prefschanged"

// 14.5 SDK 的 Preferences.h 未必声明该方法，兜底声明（运行时 PSListController 确有实现）
@interface PSListController (KSDeclare)
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end

#pragma mark - 偏好读写（与 Tweak.xm 同一 suite）

static id KSCopyPref(NSString *key) {
    return (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)KS_SUITE);
}

static BOOL KSBool(NSString *key, BOOL def) {
    @try {
        id v = KSCopyPref(key);
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    } @catch (NSException *e) {}
    return def;
}

static CGFloat KSFloat(NSString *key, CGFloat def) {
    @try {
        id v = KSCopyPref(key);
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v floatValue];
    } @catch (NSException *e) {}
    return def;
}

static void KSSetPref(NSString *key, id value) {
    @try {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)KS_SUITE);
        CFPreferencesSynchronize((__bridge CFStringRef)KS_SUITE,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        // 广播给 tweak（所有注入的 App 立即跟随）
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR(KS_DARWIN_NOTI), NULL, NULL, TRUE);
    } @catch (NSException *e) {}
}

#pragma mark - 实时预览 cell（模拟键盘 + 工具条，可拖动调位置）

// 与 Tweak.xm 相同的按钮清单：(SF Symbol, 文字回退, 开关键)
static NSString * const ksBtnOrder[] = {
    @"showSelectAll", @"showCut", @"showPaste", @"showClipboard",
    @"showPhrases", @"showCursor", @"showDismiss"
};
static NSDictionary *ksBtnSpecs(void) {
    return @{
        @"showSelectAll": @[@"selection.pin.in.out", @"全"],
        @"showCut":       @[@"scissors", @"剪"],
        @"showPaste":     @[@"doc.on.clipboard", @"粘"],
        @"showClipboard": @[@"list.clipboard", @"历"],
        @"showPhrases":   @[@"text.quote", @"语"],
        @"showCursor":    @[@"arrow.right", @"→"],
        @"showDismiss":   @[@"keyboard.chevron.compact.down", @"收"],
    };
}

@interface KSPreviewCell : UITableViewCell
@end

@implementation KSPreviewCell {
    UIView        *_kbBg;     // 键盘模拟背景
    UIView        *_spaceBar; // 空格条示意
    UIImageView   *_globe;
    UIImageView   *_mic;
    UIStackView   *_bar;      // 工具条（实时渲染）
    NSLayoutConstraint *_cx, *_btm;
    NSTimer       *_timer;
    NSString      *_builtSig;
    CGFloat       _iconSize;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        [self buildViews];
        [self refresh];
    }
    return self;
}

// PSCustomCell 可能走这个 init（双保险，两个都实现）
- (instancetype)initWithSpecifier:(id)specifier {
    self = [self initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    return self;
}

- (UIColor *)ksKbColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.23 green:0.23 blue:0.25 alpha:1]
            : [UIColor colorWithRed:0.85 green:0.86 blue:0.87 alpha:1];
    }];
}

- (void)buildViews {
    @try {
        _kbBg = [[UIView alloc] initWithFrame:CGRectZero];
        _kbBg.translatesAutoresizingMaskIntoConstraints = NO;
        _kbBg.layer.cornerRadius = 14;
        _kbBg.layer.masksToBounds = YES;
        _kbBg.backgroundColor = [self ksKbColor];
        [self.contentView addSubview:_kbBg];

        [NSLayoutConstraint activateConstraints:@[
            [_kbBg.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [_kbBg.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_kbBg.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_kbBg.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];

        // 底部 dock 行示意：地球 + 空格 + 听写
        _globe = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"globe"]];
        _globe.tintColor = [UIColor secondaryLabelColor];
        _globe.contentMode = UIViewContentModeScaleAspectFit;
        _globe.translatesAutoresizingMaskIntoConstraints = NO;

        _spaceBar = [[UIView alloc] init];
        _spaceBar.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
                ? [UIColor colorWithWhite:0.36 alpha:1] : [UIColor whiteColor];
        }];
        _spaceBar.layer.cornerRadius = 4;
        _spaceBar.translatesAutoresizingMaskIntoConstraints = NO;

        _mic = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mic.fill"]];
        _mic.tintColor = [UIColor secondaryLabelColor];
        _mic.contentMode = UIViewContentModeScaleAspectFit;
        _mic.translatesAutoresizingMaskIntoConstraints = NO;

        [_kbBg addSubview:_globe];
        [_kbBg addSubview:_spaceBar];
        [_kbBg addSubview:_mic];
        [NSLayoutConstraint activateConstraints:@[
            [_globe.leadingAnchor constraintEqualToAnchor:_kbBg.leadingAnchor constant:14],
            [_globe.bottomAnchor constraintEqualToAnchor:_kbBg.bottomAnchor constant:-8],
            [_globe.widthAnchor constraintEqualToConstant:22],
            [_globe.heightAnchor constraintEqualToConstant:22],

            [_mic.trailingAnchor constraintEqualToAnchor:_kbBg.trailingAnchor constant:-14],
            [_mic.bottomAnchor constraintEqualToAnchor:_kbBg.bottomAnchor constant:-8],
            [_mic.widthAnchor constraintEqualToConstant:22],
            [_mic.heightAnchor constraintEqualToConstant:22],

            [_spaceBar.centerYAnchor constraintEqualToAnchor:_globe.centerYAnchor],
            [_spaceBar.leadingAnchor constraintEqualToAnchor:_globe.trailingAnchor constant:24],
            [_spaceBar.trailingAnchor constraintEqualToAnchor:_mic.leadingAnchor constant:-24],
            [_spaceBar.heightAnchor constraintEqualToConstant:30],
        ]];

        // 拖动手势挂在工具条上（rebuild 时重挂）
    } @catch (NSException *e) {}
}

- (UIButton *)ksMakeBtn:(NSString *)sf fallback:(NSString *)fb {
    @try {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:_iconSize
                                                                                          weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:sf withConfiguration:cfg];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        if (img) [b setImage:img forState:UIControlStateNormal];
        else if (fb.length) [b setTitle:fb forState:UIControlStateNormal];
        [b setTintColor:[UIColor labelColor]];
        b.contentEdgeInsets = UIEdgeInsetsMake(3, 5, 3, 5); // 与 tweak 同款内边距
        b.userInteractionEnabled = NO; // 预览按钮不响应点击，拖动在整条上
        return b;
    } @catch (NSException *e) { return nil; }
}

- (void)rebuildBar {
    @try {
        if (_bar) { [_bar removeFromSuperview]; _bar = nil; _cx = nil; _btm = nil; }
        if (!KSBool(@"enabled", YES) || !KSBool(@"toolbarEnabled", YES)) return;

        _iconSize = KSFloat(@"iconSize", 15);
        CGFloat offX = KSFloat(@"toolbarX", -25);
        CGFloat lift = KSFloat(@"toolbarLift", 35);

        _bar = [[UIStackView alloc] init];
        _bar.axis = UILayoutConstraintAxisHorizontal;
        _bar.distribution = UIStackViewDistributionEqualSpacing;
        _bar.alignment = UIStackViewAlignmentCenter;
        _bar.spacing = 4;
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        _bar.layer.cornerRadius = 8;
        _bar.layer.masksToBounds = YES;
        _bar.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
                ? [UIColor colorWithWhite:0.15 alpha:0.85] : [UIColor colorWithWhite:1.0 alpha:0.85];
        }];
        [_kbBg addSubview:_bar];

        NSDictionary *specs = ksBtnSpecs();
        for (NSUInteger i = 0; i < sizeof(ksBtnOrder)/sizeof(ksBtnOrder[0]); i++) {
            NSString *k = ksBtnOrder[i];
            if (![k isEqualToString:@"showCursor"] && !KSBool(k, YES)) continue;
            if ([k isEqualToString:@"showCursor"] && !KSBool(@"showCursor", YES)) continue;
            NSArray *sf_fb = specs[k];
            UIButton *b;
            if ([k isEqualToString:@"showCursor"]) {
                b = [self ksMakeBtn:@"arrow.left" fallback:@"←"];
                if (b) [_bar addArrangedSubview:b];
                b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
            } else {
                b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
            }
            if (b) [_bar addArrangedSubview:b];
        }

        // 与 tweak 完全同款的定位方式：centerX 偏移 + 底边抬高
        _cx  = [_bar.centerXAnchor constraintEqualToAnchor:_kbBg.centerXAnchor constant:offX];
        _btm = [_bar.bottomAnchor constraintEqualToAnchor:_kbBg.bottomAnchor constant:-lift];
        _cx.active = YES; _btm.active = YES;

        // 极端参数（抬高 120 + 图标 26）下 top 防越界约束可能与 bottom 冲突，降级防 unsatisfiable
        NSLayoutConstraint *topGuard = [_bar.topAnchor constraintLessThanOrEqualToAnchor:_kbBg.topAnchor constant:10];
        topGuard.priority = 999;
        topGuard.active = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [_bar addGestureRecognizer:pan];
    } @catch (NSException *e) {}
}

- (void)onPan:(UIPanGestureRecognizer *)p {
    @try {
        if (!_bar) return;
        CGPoint t = [p translationInView:_kbBg];
        [p setTranslation:CGPointZero inView:_kbBg];
        CGFloat offX = KSFloat(@"toolbarX", -25) + t.x;
        CGFloat lift = KSFloat(@"toolbarLift", 35) - t.y; // 往上拖 = 抬高增大
        offX = MIN(120, MAX(-120, offX));
        lift = MIN(120, MAX(0, lift));
        KSSetPref(@"toolbarX", @(offX));
        KSSetPref(@"toolbarLift", @(lift));
        [self refresh]; // 立即反映 + 已广播给 tweak 实时跟随
    } @catch (NSException *e) {}
}

- (void)refresh {
    @try {
        CGFloat iconSize = KSFloat(@"iconSize", 15);
        // 签名含 iconSize + 每个开关独立一位（错位编码，任何一项变化都触发重建）
        NSString *sig = [NSString stringWithFormat:@"%.1f|%d%d%d%d%d%d%d%d",
            iconSize,
            KSBool(@"enabled", YES) && KSBool(@"toolbarEnabled", YES) ? 1 : 0,
            KSBool(@"showSelectAll", YES) ? 1 : 0,
            KSBool(@"showCut", YES) ? 1 : 0,
            KSBool(@"showPaste", YES) ? 1 : 0,
            KSBool(@"showClipboard", YES) ? 1 : 0,
            KSBool(@"showPhrases", YES) ? 1 : 0,
            KSBool(@"showCursor", YES) ? 1 : 0,
            KSBool(@"showDismiss", YES) ? 1 : 0];
        if (![sig isEqualToString:_builtSig]) {
            _builtSig = sig;
            [self rebuildBar];
        }
        if (_cx) _cx.constant = KSFloat(@"toolbarX", -25);
        if (_btm) _btm.constant = -KSFloat(@"toolbarLift", 35);
    } @catch (NSException *e) {}
}

// 定时器轮询（0.25s）：开关/滑块的值变化自动反映到预览；页面退出时停掉
- (void)didMoveToWindow {
    [super didMoveToWindow];
    @try {
        if (self.window == nil) {
            [_timer invalidate]; _timer = nil;
        } else if (!_timer) {
            _timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        }
    } @catch (NSException *e) {}
}

- (void)dealloc {
    [_timer invalidate]; _timer = nil;
}

@end

#pragma mark - 主设置控制器

@interface KSSettingsController : PSListController
@end

@implementation KSSettingsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 每次开关/滑块改值都会走到这里（PSSwitchCell/PSSliderCell 的标准写入链路）
// → super 写入 suite → 广播 darwin 通知 → tweak 实时刷新（无需收起键盘）
- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    @try {
        [super setPreferenceValue:value specifier:specifier];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR(KS_DARWIN_NOTI), NULL, NULL, TRUE);
    } @catch (NSException *e) {}
}

@end
