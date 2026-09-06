#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

#pragma mark - 配置

static NSString *const KS_SUITE = @"com.yzdmm.keyboardstatus";
static NSInteger const KS_STATUS_TAG = 9173;
static NSInteger const KS_TOOLBAR_TAG = 9174;

#pragma mark - 偏好（跨进程：设置面板与 tweak 共用 KS_SUITE）

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

static void KSSetPref(NSString *key, id value) {
    @try {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)KS_SUITE);
        CFPreferencesSynchronize((__bridge CFStringRef)KS_SUITE,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    } @catch (NSException *e) {}
}

#pragma mark - 网络类型（标准 BSD，无额外框架依赖）

static NSString *KSNetworkType(void) {
    @try {
        struct ifaddrs *ifs = NULL;
        if (getifaddrs(&ifs) != 0) return @"无网络";
        BOOL wifi = NO, cell = NO;
        for (struct ifaddrs *ifa = ifs; ifa; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr == NULL) continue;
            int fam = ifa->ifa_addr->sa_family;
            if (fam == AF_INET || fam == AF_INET6) {
                NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
                if ([name isEqualToString:@"en0"]) wifi = YES;
                else if ([name hasPrefix:@"pdp_ip"]) cell = YES;
            }
        }
        freeifaddrs(ifs);
        if (wifi) return @"WiFi";
        if (cell) return @"蜂窝";
        return @"无网络";
    } @catch (NSException *e) {}
    return @"无网络";
}

#pragma mark - 状态条文本（可选，纯显示）

static NSString *KSBuildStatus(void) {
    NSMutableArray *parts = [NSMutableArray array];
    @try {
        if (KSBool(@"showClock", YES)) {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = @"HH:mm:ss";
            [parts addObject:[NSString stringWithFormat:@"🕐 %@", [f stringFromDate:[NSDate date]]]];
        }
        if (KSBool(@"showBattery", YES)) {
            UIDevice *dev = [UIDevice currentDevice];
            dev.batteryMonitoringEnabled = YES;
            NSInteger pct = (NSInteger)(dev.batteryLevel * 100.0);
            if (pct < 0) pct = 0; if (pct > 100) pct = 100;
            NSString *mark = (dev.batteryState == UIDeviceBatteryStateCharging ||
                              dev.batteryState == UIDeviceBatteryStateFull) ? @"⚡" : @"";
            [parts addObject:[NSString stringWithFormat:@"🔋 %ld%%%@", (long)pct, mark]];
        }
        if (KSBool(@"showClipboardStatus", YES)) {
            NSString *c = [UIPasteboard generalPasteboard].string;
            if (c.length == 0) c = @"空";
            else if (c.length > 8) c = [[c substringToIndex:8] stringByAppendingString:@"…"];
            [parts addObject:[NSString stringWithFormat:@"📋 %@", c]];
        }
        if (KSBool(@"showNetwork", YES)) {
            [parts addObject:[NSString stringWithFormat:@"📶 %@", KSNetworkType()]];
        }
    } @catch (NSException *e) {}
    return [parts componentsJoinedByString:@"   "];
}

static __weak UILabel *KSStatusLabel = nil;

static void KSSetupStatusTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t){
            UILabel *label = KSStatusLabel;
            if (label == nil) return;
            if (!KSBool(@"enabled", YES) || !KSBool(@"showStatus", YES)) {
                [label removeFromSuperview];
                KSStatusLabel = nil;
                return;
            }
            if (label.superview == nil) { KSStatusLabel = nil; return; }
            @try { label.text = KSBuildStatus(); } @catch (NSException *e) {}
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
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

static UIResponder *ksFindFirstResponder(void) {
    @try {
        UIWindow *kw = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                    kw = ((UIWindowScene *)s).keyWindow; break;
                }
            }
        }
        if (!kw) kw = [UIApplication sharedApplication].keyWindow;
        return [kw valueForKey:@"firstResponder"];
    } @catch (NSException *e) { return nil; }
}

static UIViewController *ksTopViewController(void) {
    @try {
        UIWindow *kw = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                    kw = ((UIWindowScene *)s).keyWindow; break;
                }
            }
        }
        if (!kw) kw = [UIApplication sharedApplication].keyWindow;
        UIViewController *vc = kw.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    } @catch (NSException *e) { return nil; }
}

static UIButton *ksMakeButton(NSString *sf, NSString *fallback, SEL action, id target) {
    @try {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15
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
        // 用公开 API 让当前第一响应者（输入框）放弃焦点，从而收起键盘，避免调用私有类 UIKeyboardImpl
        [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder)
                                                    to:nil
                                                  from:nil
                                              forEvent:nil];
    } @catch (NSException *e) {}
}

#pragma mark - Hook：键盘 dock（仅普通 App，不碰主屏幕/设置）

@interface UIKeyboardDockView : UIView
@end

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;
    @try {
        if (!KSBool(@"enabled", YES)) {
            UIView *oldS = [self viewWithTag:KS_STATUS_TAG];  if (oldS) [oldS removeFromSuperview];
            UIView *oldT = [self viewWithTag:KS_TOOLBAR_TAG]; if (oldT) [oldT removeFromSuperview];
            KSStatusLabel = nil;
            return;
        }

        // ---- 状态条（可选）----
        if (KSBool(@"showStatus", YES)) {
            UILabel *existing = (UILabel *)[self viewWithTag:KS_STATUS_TAG];
            if (!existing) {
                UILabel *l = [[UILabel alloc] init];
                l.tag = KS_STATUS_TAG;
                l.userInteractionEnabled = NO;
                l.backgroundColor = [UIColor secondarySystemBackgroundColor];
                l.textColor = [UIColor secondaryLabelColor];
                l.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
                l.textAlignment = NSTextAlignmentCenter;
                l.lineBreakMode = NSLineBreakByTruncatingTail;
                l.translatesAutoresizingMaskIntoConstraints = NO;
                [self addSubview:l];
                [NSLayoutConstraint activateConstraints:@[
                    [l.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
                    [l.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
                    [l.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-1],
                    [l.heightAnchor constraintEqualToConstant:18]
                ]];
                l.text = KSBuildStatus();
                KSStatusLabel = l;
                KSSetupStatusTimer();
            } else { KSStatusLabel = (UILabel *)existing; }
        } else {
            UIView *old = [self viewWithTag:KS_STATUS_TAG]; if (old) [old removeFromSuperview];
            KSStatusLabel = nil;
        }

        // ---- 功能按钮栏（可选）----
        if (!KSBool(@"toolbarEnabled", YES)) {
            UIView *old = [self viewWithTag:KS_TOOLBAR_TAG]; if (old) [old removeFromSuperview];
            return;
        }
        if ([self viewWithTag:KS_TOOLBAR_TAG]) return; // 已添加

        UIStackView *stack = [[UIStackView alloc] init];
        stack.tag = KS_TOOLBAR_TAG;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 4;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8].active = YES;
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8].active = YES;
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-22].active = YES;

        UIButton *b;
        if (KSBool(@"showSelectAll", YES)) { b = ksMakeButton(@"selection.pin.in.out", @"全", @selector(ksActSelectAll), self); if (b) [stack addArrangedSubview:b]; }
        if (KSBool(@"showCut", YES))       { b = ksMakeButton(@"scissors",           @"剪", @selector(ksActCut),       self); if (b) [stack addArrangedSubview:b]; }
        if (KSBool(@"showPaste", YES))     { b = ksMakeButton(@"doc.on.clipboard",   @"粘", @selector(ksActPaste),     self); if (b) [stack addArrangedSubview:b]; }
        if (KSBool(@"showClipboard", YES)) { [stack addArrangedSubview:ksSeparator()];
                                            b = ksMakeButton(@"list.clipboard", @"历", @selector(ksActClipboard), self); if (b) [stack addArrangedSubview:b]; }
        if (KSBool(@"showPhrases", YES))   { b = ksMakeButton(@"text.quote",     @"语", @selector(ksActPhrases),  self); if (b) [stack addArrangedSubview:b]; }
        if (KSBool(@"showCursor", YES))    { [stack addArrangedSubview:ksSeparator()];
                                            b = ksMakeButton(@"arrow.left",  @"←", @selector(ksActCursorLeft),  self); if (b) [stack addArrangedSubview:b];
                                            b = ksMakeButton(@"arrow.right", @"→", @selector(ksActCursorRight), self); if (b) [stack addArrangedSubview:b]; }
        if (KSBool(@"showDismiss", YES))   { [stack addArrangedSubview:ksSeparator()];
                                            b = ksMakeButton(@"keyboard.chevron.compact.down", @"收", @selector(ksActDismiss), self); if (b) [stack addArrangedSubview:b]; }
    } @catch (NSException *e) {}
}

%end

#pragma mark - 注入按钮动作方法到 dock 类

%ctor {
    @autoreleasepool {
        Class cls = NSClassFromString(@"UIKeyboardDockView");
        if (!cls) return;
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
