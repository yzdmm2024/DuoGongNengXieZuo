#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置

static NSString *const KS_SUITE = @"com.yzdmm.keyboardstatus";
static NSInteger const KS_TOOLBAR_TAG = 9174;
// 设置面板改值后广播的 darwin 通知（KSSettingsController/KSPreviewCell 里同名 post）
#define KS_DARWIN_NOTI "com.yzdmm.keyboardstatus.prefschanged"

#pragma mark - 偏好（跨进程：设置面板与 tweak 共用 KS_SUITE）

static void KSSyncPrefs(void) {
    @try { CFPreferencesAppSynchronize((__bridge CFStringRef)KS_SUITE); } @catch (NSException *e) {}
}

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
    } @catch (NSException *e) {}
}

#pragma mark - 剪贴板历史（内存缓存，进程内有效）

static NSMutableArray *ksClipboardHistory = nil;
static const NSUInteger kMaxClip = 30;

static void ksInitClipboardObserver(void) {
    static dispatch_once_t once;
    static id ksClipboardObserver = nil;
    dispatch_once(&once, ^{
        ksClipboardHistory = [[NSMutableArray alloc] init];
        ksClipboardObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIPasteboardChangedNotification object:nil
                       queue:[NSOperationQueue mainQueue]
                  usingBlock:^(NSNotification *note) {
            @try {
                NSString *text = [UIPasteboard generalPasteboard].string;
                if (text.length == 0) return;
                if (ksClipboardHistory.count && [ksClipboardHistory.firstObject isEqualToString:text]) return;
                [ksClipboardHistory insertObject:text atIndex:0];
                if (ksClipboardHistory.count > kMaxClip) [ksClipboardHistory removeLastObject];
            } @catch (NSException *e) {}
        }];
    });
}

#pragma mark - 快捷短语（持久化到全局 suite，跨 App 共享）

static NSArray *ksDefaultPhrases(void) {
    return @[@"好的",@"收到",@"谢谢",@"不客气",@"稍等",@"没问题",
             @"了解",@"OK",@"辛苦了",@"马上处理",@"请稍等"];
}

static NSMutableArray *ksLoadPhrases(void) {
    @try {
        NSArray *saved = KSCopyPref(@"quickPhrases");
        if ([saved isKindOfClass:[NSArray class]] && saved.count) return [saved mutableCopy];
    } @catch (NSException *e) {}
    return [ksDefaultPhrases() mutableCopy];
}

static void ksSavePhrases(NSArray *phrases) {
    KSSetPref(@"quickPhrases", phrases);
}

#pragma mark - UI 辅助

// 14.5 SDK 无 UIWindowScene.keyWindow(iOS 15+)，用 windows+isKeyWindow(iOS13 即有) 兼容查找
static UIWindow *ksKeyWindow(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableArray *wins = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in app.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    [wins addObjectsFromArray:((UIWindowScene *)s).windows];
                }
            }
        }
        if (wins.count == 0) [wins addObjectsFromArray:app.windows];
        for (UIWindow *w in wins) {
            if (w.isKeyWindow) return w;
        }
        return wins.lastObject;
    } @catch (NSException *e) { return nil; }
}

static UIResponder *ksFindFirstResponder(void) {
    @try {
        UIWindow *kw = ksKeyWindow();
        return [kw valueForKey:@"firstResponder"];
    } @catch (NSException *e) { return nil; }
}

static UIViewController *ksTopViewController(void) {
    @try {
        UIWindow *kw = ksKeyWindow();
        UIViewController *vc = kw.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    } @catch (NSException *e) { return nil; }
}

static UIButton *ksMakeButton(NSString *sf, NSString *fallback, SEL action, id target, CGFloat iconSize) {
    @try {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:iconSize
                                                                                        weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:sf withConfiguration:cfg];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        if (img) [b setImage:img forState:UIControlStateNormal];
        else if (fallback.length) [b setTitle:fallback forState:UIControlStateNormal];
        [b setTintColor:[UIColor labelColor]];
        b.contentEdgeInsets = UIEdgeInsetsMake(3, 5, 3, 5);
        [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        return b;
    } @catch (NSException *e) { return nil; }
}

static UIView *ksSeparator(void) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 20)];
    v.backgroundColor = [UIColor systemGray4Color];
    return v;
}

#pragma mark - 弹窗：剪贴板历史 / 快捷短语

static void ksShowClipboardHistory(id self) {
    ksInitClipboardObserver();
    UIViewController *vc = ksTopViewController();
    if (!vc) return;
    @try {
        if (ksClipboardHistory.count == 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板历史"
                                                                      message:@"暂无复制记录"
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
            return;
        }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板历史"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *item in ksClipboardHistory) {
            NSString *d = item.length > 40 ? [[item substringToIndex:40] stringByAppendingString:@"…"] : item;
            [a addAction:[UIAlertAction actionWithTitle:d style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
                @try {
                    UIResponder *fr = ksFindFirstResponder();
                    if ([fr conformsToProtocol:@protocol(UITextInput)]) {
                        [UIPasteboard generalPasteboard].string = item;
                        [(id<UITextInput>)fr insertText:item];
                    }
                } @catch (NSException *e) {}
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *act){ [ksClipboardHistory removeAllObjects]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) {}
}

@interface KSPhraseEditor : UITableViewController
@end
@implementation KSPhraseEditor {
    NSMutableArray *_phrases;
}
- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _phrases = ksLoadPhrases();
        self.title = @"快捷短语";
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                         target:self action:@selector(addPhrase)];
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                           target:self action:@selector(done)];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableFooterView = [[UIView alloc] init];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _phrases.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.textLabel.text = _phrases[ip.row]; c.textLabel.font = [UIFont systemFontOfSize:16];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    @try {
        NSString *t = _phrases[ip.row];
        UIResponder *fr = ksFindFirstResponder();
        if ([fr conformsToProtocol:@protocol(UITextInput)]) [(id<UITextInput>)fr insertText:t];
    } @catch (NSException *e) {}
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st == UITableViewCellEditingStyleDelete) {
        [_phrases removeObjectAtIndex:ip.row]; ksSavePhrases(_phrases);
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleDelete;
}
- (void)addPhrase {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加短语" message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"短语内容"; tf.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
        NSString *t = [[a.textFields.firstObject text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) { [_phrases addObject:t]; ksSavePhrases(_phrases);
            [self.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:_phrases.count-1 inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationAutomatic]; }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static void ksShowQuickPhrases(id self) {
    UIViewController *vc = ksTopViewController();
    if (!vc) return;
    @try {
        KSPhraseEditor *ed = [[KSPhraseEditor alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ed];
        if (@available(iOS 13.0, *)) nav.modalPresentationStyle = UIModalPresentationAutomatic;
        else nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {}
}

#pragma mark - 按钮动作（全部 try/catch 兜底）

static void ksActSelectAll(id s, SEL _c) {
    @try { [[UIApplication sharedApplication] sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil]; } @catch (NSException *e) {}
}
static void ksActCut(id s, SEL _c) {
    @try { [[UIApplication sharedApplication] sendAction:@selector(cut:) to:nil from:nil forEvent:nil]; } @catch (NSException *e) {}
}
static void ksActPaste(id s, SEL _c) {
    @try { [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:nil forEvent:nil]; } @catch (NSException *e) {}
}
static void ksActCursorLeft(id s, SEL _c) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) return;
        id<UITextInput> ti = (id<UITextInput>)fr;
        UITextRange *r = [ti selectedTextRange]; if (!r) return;
        UITextPosition *p = [ti positionFromPosition:r.start offset:-1]; if (!p) return;
        [ti setSelectedTextRange:[ti textRangeFromPosition:p toPosition:p]];
    } @catch (NSException *e) {}
}
static void ksActCursorRight(id s, SEL _c) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) return;
        id<UITextInput> ti = (id<UITextInput>)fr;
        UITextRange *r = [ti selectedTextRange]; if (!r) return;
        UITextPosition *p = [ti positionFromPosition:r.end offset:1]; if (!p) return;
        [ti setSelectedTextRange:[ti textRangeFromPosition:p toPosition:p]];
    } @catch (NSException *e) {}
}
static void ksActClipboard(id s, SEL _c) { ksShowClipboardHistory(s); }
static void ksActPhrases(id s, SEL _c)  { ksShowQuickPhrases(s); }
static void ksActDismiss(id s, SEL _c) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder)
                                                    to:nil from:nil forEvent:nil];
    } @catch (NSException *e) {}
}

#pragma mark - Hook：键盘 dock（仅普通 App，不碰主屏幕/设置）

@interface UIKeyboardDockView : UIView
@end

// 工具栏构建尺寸 / 位置约束，用关联对象挂在 stack 上（每个 dock 实例独立）
static char kKSBuiltSizeKey;
static char kKSCXKey;
static char kKSBtmKey;

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;
    @try {
        KSSyncPrefs();  // 拿到设置里最新值（滑块改完，收起再拉起键盘即生效）

        if (!KSBool(@"enabled", YES) || !KSBool(@"toolbarEnabled", YES)) {
            UIView *old = [self viewWithTag:KS_TOOLBAR_TAG];
            if (old) [old removeFromSuperview];
            return;
        }

        CGFloat iconSize = KSFloat(@"iconSize", 15);
        CGFloat offX     = KSFloat(@"toolbarX", -25);   // centerX 偏移（负=往左）
        CGFloat lift     = KSFloat(@"toolbarLift", 35); // 底部抬高量（避开 dock 行与语音键）

        // 重建签名：图标大小 + 全部功能开关，任一变化都重建整个工具栏
        //（旧版只有 iconSize 变了才重建，导致「关掉某功能按钮还在」）
        NSString *sig = [NSString stringWithFormat:@"%.1f|%d|%d|%d|%d|%d|%d|%d",
            iconSize,
            KSBool(@"showSelectAll", YES), KSBool(@"showCut", YES), KSBool(@"showPaste", YES),
            KSBool(@"showClipboard", YES), KSBool(@"showPhrases", YES), KSBool(@"showCursor", YES),
            KSBool(@"showDismiss", YES)];
        UIStackView *stack = (UIStackView *)[self viewWithTag:KS_TOOLBAR_TAG];
        NSString *built = objc_getAssociatedObject(stack, &kKSBuiltSizeKey);
        if (stack && (![built isEqualToString:sig])) {
            [stack removeFromSuperview];
            stack = nil;
        }

        if (!stack) {
            stack = [[UIStackView alloc] init];
            stack.tag = KS_TOOLBAR_TAG;
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.distribution = UIStackViewDistributionEqualSpacing;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = 4;
            stack.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:stack];

            UIButton *b;
            if (KSBool(@"showSelectAll", YES)) { b = ksMakeButton(@"selection.pin.in.out", @"全", @selector(ksActSelectAll), self, iconSize); if (b) [stack addArrangedSubview:b]; }
            if (KSBool(@"showCut", YES))       { b = ksMakeButton(@"scissors",           @"剪", @selector(ksActCut),       self, iconSize); if (b) [stack addArrangedSubview:b]; }
            if (KSBool(@"showPaste", YES))     { b = ksMakeButton(@"doc.on.clipboard",   @"粘", @selector(ksActPaste),     self, iconSize); if (b) [stack addArrangedSubview:b]; }
            if (KSBool(@"showClipboard", YES)) { [stack addArrangedSubview:ksSeparator()];
                                                 b = ksMakeButton(@"list.clipboard", @"历", @selector(ksActClipboard), self, iconSize); if (b) [stack addArrangedSubview:b]; }
            if (KSBool(@"showPhrases", YES))   { b = ksMakeButton(@"text.quote",     @"语", @selector(ksActPhrases),  self, iconSize); if (b) [stack addArrangedSubview:b]; }
            if (KSBool(@"showCursor", YES))    { [stack addArrangedSubview:ksSeparator()];
                                                 b = ksMakeButton(@"arrow.left",  @"←", @selector(ksActCursorLeft),  self, iconSize); if (b) [stack addArrangedSubview:b];
                                                 b = ksMakeButton(@"arrow.right", @"→", @selector(ksActCursorRight), self, iconSize); if (b) [stack addArrangedSubview:b]; }
            if (KSBool(@"showDismiss", YES))   { [stack addArrangedSubview:ksSeparator()];
                                                 b = ksMakeButton(@"keyboard.chevron.compact.down", @"收", @selector(ksActDismiss), self, iconSize); if (b) [stack addArrangedSubview:b]; }

            NSLayoutConstraint *cx  = [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:offX];
            NSLayoutConstraint *btm = [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-lift];
            cx.active = YES; btm.active = YES;
            objc_setAssociatedObject(stack, &kKSBuiltSizeKey, sig, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(stack, &kKSCXKey,  cx,  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(stack, &kKSBtmKey, btm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            // 已存在：只更新位置参数（实时跟随面板调整）
            NSLayoutConstraint *cx  = objc_getAssociatedObject(stack, &kKSCXKey);
            NSLayoutConstraint *btm = objc_getAssociatedObject(stack, &kKSBtmKey);
            cx.constant  = offX;
            btm.constant = -lift;
        }
    } @catch (NSException *e) {}
}

%end

#pragma mark - darwin 通知：面板改值 → 实时刷新键盘（无需收起再拉起）

static void ksRefreshLayouts(UIView *root) {
    if ([root isKindOfClass:NSClassFromString(@"UIKeyboardDockView")]) { [root setNeedsLayout]; return; }
    for (UIView *sub in [root subviews]) ksRefreshLayouts(sub);
}

static void ksPrefsChangedCB(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            KSSyncPrefs();
            UIApplication *app = [UIApplication sharedApplication];
            NSMutableArray *wins = [NSMutableArray array];
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in app.connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) {
                        [wins addObjectsFromArray:((UIWindowScene *)s).windows];
                    }
                }
            }
            if (wins.count == 0) [wins addObjectsFromArray:app.windows];
            for (UIWindow *w in wins) ksRefreshLayouts(w);
        } @catch (NSException *e) {}
    });
}

#pragma mark - 注入按钮动作方法到 dock 类

%ctor {
    @autoreleasepool {
        Class cls = NSClassFromString(@"UIKeyboardDockView");
        if (!cls) return;
        // 监听设置面板的实时广播（面板每次改开关/滑块都 post 一次）
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        ksPrefsChangedCB, CFSTR(KS_DARWIN_NOTI), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        struct { const char *name; IMP imp; } methods[] = {
            {"ksActSelectAll",  (IMP)ksActSelectAll},
            {"ksActCut",        (IMP)ksActCut},
            {"ksActPaste",      (IMP)ksActPaste},
            {"ksActCursorLeft", (IMP)ksActCursorLeft},
            {"ksActCursorRight",(IMP)ksActCursorRight},
            {"ksActClipboard",  (IMP)ksActClipboard},
            {"ksActPhrases",    (IMP)ksActPhrases},
            {"ksActDismiss",    (IMP)ksActDismiss},
        };
        for (size_t i = 0; i < sizeof(methods)/sizeof(methods[0]); i++) {
            SEL sel = sel_registerName(methods[i].name);
            if (!class_addMethod(cls, sel, methods[i].imp, "v@:"))
                class_replaceMethod(cls, sel, methods[i].imp, "v@:");
        }
    }
}
