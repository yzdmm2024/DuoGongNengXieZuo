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
    @"showPhrases", @"showCursor", @"showDismiss", @"showQuickAction"
};
static NSDictionary *ksBtnSpecs(void) {
    return @{
        @"showSelectAll":  @[@"selection.pin.in.out", @"全"],
        @"showCut":        @[@"scissors", @"剪"],
        @"showPaste":      @[@"doc.on.clipboard", @"粘"],
        @"showClipboard":  @[@"list.clipboard", @"历"],
        @"showPhrases":    @[@"text.quote", @"语"],
        @"showCursor":     @[@"arrow.right", @"→"],
        @"showDismiss":    @[@"keyboard.chevron.compact.down", @"收"],
        @"showQuickAction":@[@"rectangle.stack", @"切"],
    };
}

// PSCustomCell 的 cellClass 必须继承 PSTableCell（坑H：否则点面板闪退）
@interface KSPreviewCell : PSTableCell
@end

@implementation KSPreviewCell {
    UIStackView   *_bar;      // 工具条（实时渲染，1:1 真实尺寸，无键盘主体）
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
        [self refresh];
    }
    return self;
}

// PSCustomCell 可能走这个 init（双保险，两个都实现）
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [self initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    return self;
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
        _bar.spacing = KSFloat(@"toolbarSpacing", 4); // 图标间隔与真实工具栏同步
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        // 与真实工具栏一致：无独立底色，图标直接浮在 cell 底色上（1:1，无键盘主体）
        [self.contentView addSubview:_bar];

        // 与 tweak 同款竖线分隔符（剪贴板历史/光标/收起/快捷启动前各一条）
        UIView *__sep;
#define KSPREV_SEP() do { \
            __sep = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 20)]; \
            __sep.backgroundColor = [UIColor systemGray4Color]; \
            [_bar addArrangedSubview:__sep]; \
        } while(0)

        NSDictionary *specs = ksBtnSpecs();
        for (NSUInteger i = 0; i < sizeof(ksBtnOrder)/sizeof(ksBtnOrder[0]); i++) {
            NSString *k = ksBtnOrder[i];
            if ([k isEqualToString:@"showCursor"]) {
                if (!KSBool(@"showCursor", YES)) continue;
                KSPREV_SEP();
                UIButton *b = [self ksMakeBtn:@"arrow.left" fallback:@"←"];
                if (b) [_bar addArrangedSubview:b];
                NSArray *sf_fb = specs[k];
                b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
                if (b) [_bar addArrangedSubview:b];
                continue;
            }
            BOOL def = [k isEqualToString:@"showQuickAction"] ? NO : YES;
            if (!KSBool(k, def)) continue;
            if ([k isEqualToString:@"showClipboard"] || [k isEqualToString:@"showDismiss"]
                || [k isEqualToString:@"showQuickAction"]) {
                KSPREV_SEP();
            }
            NSArray *sf_fb = specs[k];
            UIButton *b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
            if (b) [_bar addArrangedSubview:b];
        }

        // 与 tweak 完全同款的定位方式：centerX 偏移 + 底边抬高（相对 cell 底边，1:1 映射）
        _cx  = [_bar.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor constant:offX];
        _btm = [_bar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-lift];
        _cx.active = YES; _btm.active = YES;

        // 极端参数（抬高 120 + 图标 26）下 top 防越界约束可能与 bottom 冲突，降级防 unsatisfiable
        NSLayoutConstraint *topGuard = [_bar.topAnchor constraintLessThanOrEqualToAnchor:self.contentView.topAnchor constant:2];
        topGuard.priority = 999;
        topGuard.active = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [_bar addGestureRecognizer:pan];
    } @catch (NSException *e) {}
}

- (void)onPan:(UIPanGestureRecognizer *)p {
    @try {
        if (!_bar) return;
        CGPoint t = [p translationInView:self.contentView];
        [p setTranslation:CGPointZero inView:self.contentView];
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
        CGFloat spacing = KSFloat(@"toolbarSpacing", 4);
        NSString *sig = [NSString stringWithFormat:@"%.1f|%.0f|%d%d%d%d%d%d%d%d%d",
            iconSize, spacing,
            KSBool(@"enabled", YES) && KSBool(@"toolbarEnabled", YES) ? 1 : 0,
            KSBool(@"showSelectAll", YES) ? 1 : 0,
            KSBool(@"showCut", YES) ? 1 : 0,
            KSBool(@"showPaste", YES) ? 1 : 0,
            KSBool(@"showClipboard", YES) ? 1 : 0,
            KSBool(@"showPhrases", YES) ? 1 : 0,
            KSBool(@"showCursor", YES) ? 1 : 0,
            KSBool(@"showDismiss", YES) ? 1 : 0,
            KSBool(@"showQuickAction", NO) ? 1 : 0];
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

#pragma mark - 自定义滑块 cell：左侧文字(PSTableCell 自带 textLabel) + 右侧滑条
// 关键：PSCustomCell 实际走 initWithStyle:reuseIdentifier: 创建（setSpecifier: 后补配置），
// 自定义 UI 必须在 initWithStyle 里构建；KSPreviewCell 能工作正是这个原因。

@interface KSSliderCell : PSTableCell
@end

@implementation KSSliderCell {
    UISlider    *_slider;
    PSSpecifier *_spec;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        if (!_slider) {
            _slider = [[UISlider alloc] init];
            _slider.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:_slider];
            // 左侧 ~150pt 留给 textLabel（specifier 的 label 由父类填充显示）
            [NSLayoutConstraint activateConstraints:@[
                [_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:150],
                [_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
                [_slider.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            ]];
        }
    }
    return self;
}

// 兜底：部分调用路径走这个（内部转 initWithStyle 构建）
- (instancetype)initWithSpecifier:(PSSpecifier *)spec {
    self = [self initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    return self;
}

// Preferences 创建后调 setSpecifier: 传 plist 配置 → 在这里读 key/min/max/default 配置滑条
- (void)setSpecifier:(PSSpecifier *)spec {
    [super setSpecifier:spec];
    _spec = spec;
    @try {
        if (!_slider || !spec) return;
        NSString *key = [spec propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] || !key.length) return;
        id mnV = [spec propertyForKey:@"min"], mxV = [spec propertyForKey:@"max"], dvV = [spec propertyForKey:@"default"];
        CGFloat mn = [mnV isKindOfClass:[NSNumber class]] ? [mnV floatValue] : 0;
        CGFloat mx = [mxV isKindOfClass:[NSNumber class]] ? [mxV floatValue] : 100;
        CGFloat dv = [dvV isKindOfClass:[NSNumber class]] ? [dvV floatValue] : mn;
        _slider.minimumValue = mn;
        _slider.maximumValue = mx;
        _slider.value = KSFloat(key, dv);
    } @catch (NSException *e) {}
}

- (void)ksSlide:(UISlider *)s {
    @try {
        NSString *key = [_spec propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] || !key.length) return;
        KSWriteKey(key, @(s.value)); // 直写 jbroot 文件 + 广播，预览与真实键盘实时跟随
    } @catch (NSException *e) {}
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
