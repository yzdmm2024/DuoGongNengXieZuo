#import <Preferences/Preferences.h>
#import <objc/runtime.h>

#define KS_SUITE @"com.yzdmm.keyboardstatus"
// 与 Tweak.xm 里监听的同名 darwin 通知：面板改值 → tweak 实时刷新
#define KS_DARWIN_NOTI "com.yzdmm.keyboardstatus.prefschanged"

// 14.5 SDK 的 Preferences.h 未必声明该方法，兜底声明（运行时 PSListController 确有实现）
@interface PSListController (KSDeclare)
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end

#pragma mark - 偏好读写：直落 jbroot 文件（与 tweak 完全同款，绕开 cfprefsd）

static NSString *ksPrefsFilePath(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *leaf = @"var/mobile/Library/Preferences/com.yzdmm.keyboardstatus.plist";
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *p = [@"/var/jb" stringByAppendingPathComponent:leaf];
            if ([fm fileExistsAtPath:p]) { cached = p; return; }
            NSString *base = @"/private/var/containers/Bundle/Application";
            for (NSString *it in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if ([it hasPrefix:@".jbroot-"]) {
                    NSString *cand = [[base stringByAppendingPathComponent:it] stringByAppendingPathComponent:leaf];
                    if ([fm fileExistsAtPath:cand]) { cached = cand; return; }
                }
            }
        } @catch (NSException *e) {}
    });
    return cached;
}

static NSDictionary *KSPrefDict(void) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) return [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

static void KSPostChanged(void) {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR(KS_DARWIN_NOTI), NULL, NULL, TRUE);
    } @catch (NSException *e) {}
}

static void KSWriteKey(NSString *key, id value) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) {
            NSMutableDictionary *d = [KSPrefDict() mutableCopy] ?: [NSMutableDictionary dictionary];
            if (value) d[key] = value; else [d removeObjectForKey:key];
            if ([d writeToFile:p atomically:YES]) { KSPostChanged(); return; }
        }
        // 文件写失败退回 CFPreferences（面板进程 root，带 RootHide hook 时同样落 jbroot）
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)KS_SUITE);
        CFPreferencesSynchronize((__bridge CFStringRef)KS_SUITE,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        KSPostChanged();
    } @catch (NSException *e) {}
}

static BOOL KSBool(NSString *key, BOOL def) {
    @try {
        id v = KSPrefDict()[key];
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    } @catch (NSException *e) {}
    return def;
}

static CGFloat KSFloat(NSString *key, CGFloat def) {
    @try {
        id v = KSPrefDict()[key];
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v floatValue];
    } @catch (NSException *e) {}
    return def;
}

#pragma mark - 实时预览 cell：固定键盘主体 + 实时工具栏（可拖动调位置）

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

// PSCustomCell 的 cellClass 必须继承 PSTableCell（坑H：否则点面板闪退）
@interface KSPreviewCell : PSTableCell
@end

@implementation KSPreviewCell {
    UIView        *_kbBg;     // 键盘模拟背景
    NSMutableArray *_keyViews; // 固定按键（不随配置变）
    CGFloat        _drawnW;    // 按键绘制时的宽度（变了才重画）
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
        _keyViews = [[NSMutableArray alloc] init];
        [self buildViews];
        [self refresh];
    }
    return self;
}

// PSCustomCell 可能走这个 init（双保险，两个都实现）
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [self initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    return self;
}

- (UIColor *)ksKbColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.18 green:0.18 blue:0.20 alpha:1]
            : [UIColor colorWithRed:0.85 green:0.86 blue:0.87 alpha:1];
    }];
}

- (UIColor *)ksKeyColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.32 green:0.32 blue:0.34 alpha:1] : [UIColor whiteColor];
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
    } @catch (NSException *e) {}
}

// 固定键盘主体：4 行按键示意（QWERTY / ASDF / shift行 / dock行），不随配置变化
- (void)ksDrawKeysIfNeeded {
    @try {
        CGFloat W = _kbBg.bounds.size.width, H = _kbBg.bounds.size.height;
        if (W <= 10 || H <= 10) return;
        if (_keyViews.count && fabs(W - _drawnW) < 1) return;
        _drawnW = W;
        for (UIView *v in _keyViews) [v removeFromSuperview];
        [_keyViews removeAllObjects];

        CGFloat rowH = 20, gap = 3, side = 8;
        CGFloat blockH = rowH * 4 + gap * 3;
        CGFloat y0 = H - blockH - 6; // 键区从底部往上

        NSArray<NSArray *> *rows = @[
            @[@10, @"Q,W,E,R,T,Y,U,I,O,P"],
            @[@9,  @"A,S,D,F,G,H,J,K,L"],
            @[@9,  @"⇧,Z,X,C,V,B,N,M,⌫"],
        ];
        CGFloat y = y0;
        for (NSArray *row in rows) {
            NSUInteger n = [row[0] unsignedIntegerValue];
            NSArray *keys = [row[1] componentsSeparatedByString:@","];
            CGFloat kw = (W - side * 2 - gap * (n - 1)) / n;
            CGFloat x = side;
            for (NSString *label in keys) {
                UIView *k = [[UIView alloc] initWithFrame:CGRectMake(x, y, kw, rowH)];
                k.backgroundColor = [self ksKeyColor];
                k.layer.cornerRadius = 4;
                UILabel *l = [[UILabel alloc] initWithFrame:k.bounds];
                l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                l.text = label;
                l.font = [UIFont systemFontOfSize:10];
                l.textAlignment = NSTextAlignmentCenter;
                l.textColor = [UIColor secondaryLabelColor];
                [k addSubview:l];
                [_kbBg addSubview:k];
                [_keyViews addObject:k];
                x += kw + gap;
            }
            y += rowH + gap;
        }
        // 底部 dock 行：123 + 空格 + 发送
        CGFloat dy = y;
        CGFloat dw1 = (W - side * 2 - gap * 2) * 0.22;
        CGFloat dw2 = (W - side * 2 - gap * 2) * 0.50;
        CGFloat dw3 = (W - side * 2 - gap * 2) * 0.28;
        NSArray *dockSpec = @[
            @[[NSValue valueWithCGRect:CGRectMake(side, dy, dw1, rowH)], @"123"],
            @[[NSValue valueWithCGRect:CGRectMake(side + dw1 + gap, dy, dw2, rowH)], @""],
            @[[NSValue valueWithCGRect:CGRectMake(side + dw1 + gap * 2 + dw2, dy, dw3, rowH)], @"发送"],
        ];
        for (NSArray *spec in dockSpec) {
            CGRect f = [[spec objectAtIndex:0] CGRectValue];
            NSString *label = [spec objectAtIndex:1];
            UIView *k = [[UIView alloc] initWithFrame:f];
            BOOL isSend = [label isEqualToString:@"发送"];
            k.backgroundColor = label.length == 0
                ? [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
                    return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
                        ? [UIColor colorWithWhite:0.45 alpha:1] : [UIColor whiteColor];
                  }]
                : (isSend ? [UIColor systemGray3Color] : [UIColor systemGray4Color]);
            k.layer.cornerRadius = 4;
            if (label.length) {
                UILabel *l = [[UILabel alloc] initWithFrame:k.bounds];
                l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                l.text = label;
                l.font = [UIFont systemFontOfSize:10];
                l.textAlignment = NSTextAlignmentCenter;
                l.textColor = [UIColor secondaryLabelColor];
                [k addSubview:l];
            }
            [_kbBg addSubview:k];
            [_keyViews addObject:k];
        }
    } @catch (NSException *e) {}
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self ksDrawKeysIfNeeded];
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
            if ([k isEqualToString:@"showCursor"]) {
                if (!KSBool(@"showCursor", YES)) continue;
                UIButton *b = [self ksMakeBtn:@"arrow.left" fallback:@"←"];
                if (b) [_bar addArrangedSubview:b];
                NSArray *sf_fb = specs[k];
                b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
                if (b) [_bar addArrangedSubview:b];
                continue;
            }
            if (!KSBool(k, YES)) continue;
            NSArray *sf_fb = specs[k];
            UIButton *b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
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
        KSWriteKey(@"toolbarX", @(offX));
        KSWriteKey(@"toolbarLift", @(lift));
        [self refresh]; // 立即反映（KSWriteKey 内已广播给 tweak）
    } @catch (NSException *e) {}
}

- (void)refresh {
    @try {
        CGFloat iconSize = KSFloat(@"iconSize", 15);
        // 签名含 iconSize + 每个开关独立一位，任何一项变化都触发重建
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

// 定时器轮询（0.25s）：开关/滑块改动自动反映到预览；页面退出时停掉
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
// → super 写 cfprefsd（RootHide 环境落 jbroot）→ 再直写文件双保险 → 广播 darwin 通知
- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    @try {
        [super setPreferenceValue:value specifier:specifier];
        if ([specifier respondsToSelector:@selector(propertyForKey:)]) {
            NSString *key = [specifier propertyForKey:@"key"];
            if ([key isKindOfClass:[NSString class]] && key.length) {
                NSString *p = ksPrefsFilePath();
                if (p) {
                    NSMutableDictionary *d = [KSPrefDict() mutableCopy] ?: [NSMutableDictionary dictionary];
                    if (value) d[key] = value;
                    [d writeToFile:p atomically:YES]; // 与 super 写的值一致，谁后写都无冲突
                }
            }
        }
        KSPostChanged();
    } @catch (NSException *e) {}
}

@end
