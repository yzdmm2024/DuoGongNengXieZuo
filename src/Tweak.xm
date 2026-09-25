#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "deleteall_icon.h"

// 前向声明：新增函数在 %ctor / 早定义处被提前引用
static void ksToast(NSString *msg);
static void ksInstallMethods(Class cls);

#pragma mark - 配置

static NSString *const KS_SUITE = @"com.yzdmm.keyboardstatus";
static NSInteger const KS_TOOLBAR_TAG = 9174;
// 设置面板改值后广播的 darwin 通知（KSSettingsController/KSPreviewCell 里同名 post）
#define KS_DARWIN_NOTI "com.yzdmm.keyboardstatus.prefschanged"

#pragma mark - 偏好（跨进程：设置面板与 tweak 共用 KS_SUITE）

// Roothide 实测（2026-09-06 frida）：面板写入的偏好经 RootHide 重定向，落在
// .jbroot-<UUID>/var/mobile/Library/Preferences/ 的文件里；而普通 App 进程的
// CFPreferencesCopyAppValue 走 cfprefsd 默认容器视图，读不到这份文件 → 设置永不生效。
// 解法：读直接落 jbroot 的 plist 文件，与面板写入落点物理一致，绕开 cfprefsd。
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

static void KSSyncPrefs(void) {
    // 文件直读无需同步；保留空实现兼容旧调用点
}

static id KSCopyPref(NSString *key) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            return d[key];
        }
        // 找不到 jbroot 文件时退回 CFPreferences（有 hook 的环境仍可用）
        return (__bridge_transfer id)CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, (__bridge CFStringRef)KS_SUITE);
    } @catch (NSException *e) { return nil; }
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
        NSString *p = ksPrefsFilePath();
        if (p) {
            // 直写 jbroot 文件（与面板/读侧一致）；失败再退回 CFPreferences
            NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:p] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
            if (value) d[key] = value; else [d removeObjectForKey:key];
            if ([d writeToFile:p atomically:YES]) return;
        }
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
// 快捷启动：主路径 LSApplicationWorkspace openApplicationWithBundleID:
// （iOS 16.6.1 实测：openApplicationWithBundleURL: 已不存在；openApplicationWithBundleID: 在微信沙盒内 frida 实测返回 true 拉起成功）
// 兜底 quickActionURL 的 openURL 跳转
static void ksActQuickLaunch(id s, SEL _c) {
    @try {
        NSString *bid = KSCopyPref(@"quickActionBundleId");
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
            id ws = wsCls ? [(id)wsCls performSelector:@selector(defaultWorkspace)] : nil;
            if (ws && [ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
                BOOL ok = (BOOL)[ws performSelector:@selector(openApplicationWithBundleID:) withObject:bid];
                if (ok) return;
            }
        }
        // 兜底：URL Scheme openURL（兼容旧的系统设置页 app-prefs 跳转等）
        NSString *urlStr = KSCopyPref(@"quickActionURL");
        if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) return;
        NSURL *u = [NSURL URLWithString:urlStr];
        if (!u) return;
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    } @catch (NSException *e) {}
}

static void ksActDismiss(id s, SEL _c) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder)
                                                    to:nil from:nil forEvent:nil];
    } @catch (NSException *e) {}
}

// 全删：清空当前输入框的全部文本（先点进输入框再用）
static void ksActDeleteAll(id s, SEL _c) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) {
            ksToast(@"请先点进输入框");
            return;
        }
        id<UITextInput> ti = (id<UITextInput>)fr;
        UITextRange *all = [ti textRangeFromPosition:ti.beginningOfDocument toPosition:ti.endOfDocument];
        if (all) [ti replaceRange:all withText:@""];
    } @catch (NSException *e) {}
}

#pragma mark - AI 按钮（OpenAI 兼容接口：单击默认动作 / 长按菜单）

// 预置模型：0=智谱 GLM-5.3-Flash，1=智谱 GLM-5.3，2=自定义（读 aiBaseURL/aiModel）
static void ksAIEndpoint(NSString **urlOut, NSString **modelOut) {
    NSInteger preset = 0;
    id pv = KSCopyPref(@"aiPreset");
    if ([pv isKindOfClass:[NSNumber class]]) preset = [pv integerValue];
    else if ([pv isKindOfClass:[NSString class]]) preset = [(NSString *)pv integerValue];
    if (preset == 1) {
        *urlOut = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
        *modelOut = @"glm-5.3";
    } else if (preset == 2) {
        id u = KSCopyPref(@"aiBaseURL");
        id m = KSCopyPref(@"aiModel");
        *urlOut  = [u isKindOfClass:[NSString class]] ? u : @"";
        *modelOut = [m isKindOfClass:[NSString class]] ? m : @"";
    } else {
        *urlOut = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
        *modelOut = @"glm-5.3-flash";
    }
}

// 内置动作模板（唯一 %@ = 选中文本）
static NSString *ksAIBuiltinPrompt(NSString *act) {
    NSDictionary *m = @{
        @"polish":  @"请润色改写下面的文本，保持原意、语句通顺，只输出改写结果，不要任何解释：\n\n%@\n",
        @"brief":   @"请精简压缩下面的文本，保留核心信息，只输出结果，不要解释：\n\n%@\n",
        @"expand":  @"请扩写下面的文本，使内容更丰富具体，只输出扩写结果：\n\n%@\n",
        @"summary": @"请总结下面文本的要点，输出简明摘要：\n\n%@\n",
        @"points":  @"请提取下面文本的关键要点，用简洁列表输出：\n\n%@\n",
        @"fix":     @"请纠正下面文本中的错别字和语病，只输出修正后的文本：\n\n%@\n",
        @"explain": @"请用通俗易懂的语言解释下面的文本：\n\n%@\n",
        @"z2e":     @"请把下面的中文翻译成英文，只输出译文：\n\n%@\n",
        @"e2z":     @"请把下面的英文翻译成中文，只输出译文：\n\n%@\n",
        @"ja":      @"请把下面的文本在中文与日文之间互译（中文译成日文，日文译成中文），只输出译文：\n\n%@\n",
        @"code":    @"你是一名资深程序员。请分析下面的代码或报错信息，给出优化后的代码或排查解决步骤：\n\n%@\n",
    };
    return m[act];
}

static NSString *ksAITitle(NSString *act) {
    NSDictionary *m = @{
        @"polish": @"✨ 润色改写", @"brief": @"✂️ 精简压缩", @"expand": @"📝 扩写内容",
        @"summary": @"📋 总结摘要", @"points": @"🔖 提取要点", @"fix": @"🩹 语病纠错",
        @"explain": @"💬 解释文本", @"z2e": @"🌐 中译英", @"e2z": @"🌐 英译中",
        @"ja": @"🌐 中日互译", @"code": @"💻 代码优化/报错分析",
        @"custom1": @"⭐ 自定义模板 1", @"custom2": @"⭐ 自定义模板 2",
    };
    return m[act] ?: act;
}

// 面板进程/宿主进程通用轻提示（黑底圆角，1.4s 自动消失）
static void ksToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = ksKeyWindow();
            if (!w) return;
            UILabel *l = [[UILabel alloc] init];
            l.text = msg;
            l.font = [UIFont systemFontOfSize:14];
            l.textColor = UIColor.whiteColor;
            l.textAlignment = NSTextAlignmentCenter;
            l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
            l.layer.cornerRadius = 10;
            l.layer.masksToBounds = YES;
            CGFloat pad = 16.0;
            CGSize sz = [l sizeThatFits:CGSizeMake(w.bounds.size.width - 60, CGFLOAT_MAX)];
            l.frame = CGRectMake((w.bounds.size.width - sz.width - pad * 2) / 2,
                                 w.bounds.size.height * 0.35, sz.width + pad * 2, sz.height + 20);
            [w addSubview:l];
            [UIView animateWithDuration:0.2 animations:^{ l.alpha = 0; } completion:^(BOOL fin) {
                l.alpha = 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; }
                        completion:^(BOOL f2){ [l removeFromSuperview]; }];
                });
            }];
        } @catch (NSException *e) {}
    });
}

// loading：按钮转圈 + 保存请求 task（点按钮 = 取消）
static char kKSTaskKey;
static void ksAISetLoading(UIButton *btn, BOOL loading) {
    @try {
        if (!btn) return;
        UIActivityIndicatorView *sp = objc_getAssociatedObject(btn, @selector(ksAIIsLoading));
        if (loading) {
            if (!sp) {
                sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                sp.translatesAutoresizingMaskIntoConstraints = NO;
                [btn addSubview:sp];
                [NSLayoutConstraint activateConstraints:@[
                    [sp.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
                    [sp.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
                ]];
                objc_setAssociatedObject(btn, @selector(ksAIIsLoading), sp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            btn.imageView.hidden = YES;
            btn.alpha = 0.5;
            [sp startAnimating];
        } else {
            btn.imageView.hidden = NO;
            btn.alpha = 1.0;
            [sp stopAnimating];
            sp.hidden = YES;
            objc_setAssociatedObject(btn, &kKSTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (NSException *e) {}
}

static BOOL ksAIIsLoading(UIButton *btn) {
    UIActivityIndicatorView *sp = objc_getAssociatedObject(btn, @selector(ksAIIsLoading));
    return sp && !sp.hidden;
}

// 发请求：prompt → 回调主线程 (result|nil, err|nil)，返回 task 供取消
static NSURLSessionDataTask *ksAIRequest(NSString *prompt, void (^done)(NSString *result, NSString *err)) {
    @try {
        NSString *url = nil, *model = nil;
        ksAIEndpoint(&url, &model);
        id kv = KSCopyPref(@"aiApiKey");
        NSString *key = [kv isKindOfClass:[NSString class]] ? kv : nil;
        if (url.length == 0 || model.length == 0 || key.length == 0) {
            done(nil, @"AI 未配置完整：请到 设置→键盘下方状态→AI 大模型 填写 API Key 等参数");
            return nil;
        }
        CGFloat temp = KSFloat(@"aiTemp", 0.7);
        if (temp < 0) temp = 0; if (temp > 1) temp = 1;

        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        body[@"model"] = model;
        body[@"temperature"] = @(temp);
        body[@"messages"] = @[ @{ @"role": @"user", @"content": prompt } ];
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = data;
        req.timeoutInterval = 60;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];

        __block NSURLSessionDataTask *task;
        task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (e) { done(nil, [NSString stringWithFormat:@"请求失败：%@", e.localizedDescription]); return; }
                    NSInteger code = [(NSHTTPURLResponse *)r statusCode];
                    id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
                    if (code != 200) {
                        NSString *msg = @"服务端错误";
                        if ([json isKindOfClass:[NSDictionary class]]) {
                            id errObj = json[@"error"];
                            if ([errObj isKindOfClass:[NSDictionary class]]) {
                                id m = errObj[@"message"];
                                if ([m isKindOfClass:[NSString class]]) msg = m;
                            } else if ([errObj isKindOfClass:[NSString class]]) {
                                msg = errObj;
                            }
                        }
                        done(nil, [NSString stringWithFormat:@"HTTP %ld：%@", (long)code, msg]);
                        return;
                    }
                    NSString *out = nil;
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        id choices = json[@"choices"];
                        if ([choices isKindOfClass:[NSArray class]] && [choices count] > 0) {
                            id msg = choices[0][@"message"];
                            if ([msg isKindOfClass:[NSDictionary class]]) {
                                id c = msg[@"content"];
                                if ([c isKindOfClass:[NSString class]]) out = c;
                            }
                        }
                    }
                    if (out.length == 0) done(nil, @"返回内容解析失败");
                    else done(out, nil);
                } @catch (NSException *ex) { done(nil, ex.reason ?: @"解析异常"); }
            });
        }];
        [task resume];
        return task;
    } @catch (NSException *e) {
        done(nil, e.reason ?: @"请求异常");
        return nil;
    }
}

// 执行动作：取选中文本 → 拼 prompt → loading → 请求 → 替换/追加
static void ksAIExecute(NSString *act, UIButton *btn) {
    @try {
        if (!act.length) act = @"polish";
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) {
            ksToast(@"请先点进输入框再使用 AI");
            return;
        }
        id<UITextInput> ti = (id<UITextInput>)fr;
        NSString *sel = [ti textInRange:ti.selectedTextRange] ?: @"";
        if (sel.length == 0) {
            ksToast(@"请先选中要处理的文本");
            return;
        }
        // 模板：内置动作走常量格式串；自定义模板用 {{text}} 替换（防用户模板里 % 引发格式崩溃）
        NSString *prompt = nil;
        NSString *builtin = ksAIBuiltinPrompt(act);
        if (builtin) {
            prompt = [NSString stringWithFormat:builtin, sel];
        } else {
            NSString *tpl = nil;
            if ([act isEqualToString:@"custom1"]) tpl = KSCopyPref(@"aiCustomPrompt1");
            else if ([act isEqualToString:@"custom2"]) tpl = KSCopyPref(@"aiCustomPrompt2");
            if (![tpl isKindOfClass:[NSString class]] || tpl.length == 0) {
                ksToast(@"该自定义模板为空，请到设置里填写");
                return;
            }
            prompt = [tpl stringByReplacingOccurrencesOfString:@"{{text}}" withString:sel];
        }
        if (prompt.length == 0) return;

        ksAISetLoading(btn, YES);
        __block UIButton *b = btn;
        NSURLSessionDataTask *task = ksAIRequest(prompt, ^(NSString *result, NSString *err) {
            ksAISetLoading(b, NO);
            if (err) { ksToast(err); return; }
            if (!result) return;
            @try {
                id<UITextInput> t2 = (id<UITextInput>)ksFindFirstResponder();
                if (!t2) return;
                NSInteger outMode = 0;
                id om = KSCopyPref(@"aiOutputMode");
                if ([om isKindOfClass:[NSNumber class]]) outMode = [om integerValue];
                else if ([om isKindOfClass:[NSString class]]) outMode = [(NSString *)om integerValue];
                NSString *curSel = [t2 textInRange:t2.selectedTextRange] ?: @"";
                BOOL hasSel = curSel.length > 0;
                if (outMode == 1 || !hasSel) {
                    // 模式 B：光标后追加（或选区已丢失的兜底）
                    [(id<UITextInput>)t2 insertText:result];
                } else {
                    // 模式 A：直接替换选中文本
                    [(id<UITextInput>)t2 replaceRange:t2.selectedTextRange withText:result];
                }
            } @catch (NSException *e) { ksToast(e.reason ?: @"写入失败"); }
        });
        objc_setAssociatedObject(btn, &kKSTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        ksToast(e.reason ?: @"AI 执行异常");
    }
}

// 单击：执行默认动作；loading 中 = 取消请求
static void ksActAI(id s, SEL _c, id sender) {
    @try {
        UIButton *btn = (UIButton *)sender;
        if ([btn isKindOfClass:[UIButton class]] && ksAIIsLoading(btn)) {
            NSURLSessionDataTask *task = objc_getAssociatedObject(btn, &kKSTaskKey);
            [task cancel];
            ksAISetLoading(btn, NO);
            ksToast(@"已取消 AI 请求");
            return;
        }
        NSString *act = KSCopyPref(@"aiDefaultAction");
        if (![act isKindOfClass:[NSString class]] || !act.length) act = @"polish";
        ksAIExecute(act, btn);
    } @catch (NSException *e) {}
}

// 长按：弹出功能菜单（翻译含二级子菜单）
static void ksAILongPress(id s, SEL _c, UILongPressGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan) return;
    @try {
        UIViewController *vc = ksTopViewController();
        if (!vc) return;
        UIButton *btn = (UIButton *)g.view;
        if (![btn isKindOfClass:[UIButton class]]) btn = nil;

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"✨AI处理"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        void (^run)(NSString *) = ^(NSString *act){ ksAIExecute(act, btn); };

        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 润色改写" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"polish"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 精简压缩" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"brief"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 扩写内容" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"expand"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 总结摘要" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"summary"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 提取要点" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"points"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 语病纠错" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"fix"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 解释文本" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"explain"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 翻译 ▷" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                UIAlertController *tr = [UIAlertController alertControllerWithTitle:@"翻译"
                                                                            message:nil
                                                                     preferredStyle:UIAlertControllerStyleActionSheet];
                [tr addAction:[UIAlertAction actionWithTitle:@"中译英" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *x){ run(@"z2e"); }]];
                [tr addAction:[UIAlertAction actionWithTitle:@"英译中" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *x){ run(@"e2z"); }]];
                [tr addAction:[UIAlertAction actionWithTitle:@"中日互译" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *x){ run(@"ja"); }]];
                [tr addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [vc presentViewController:tr animated:YES completion:nil];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 💻 代码优化/报错分析" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"code"); }]];
        // 自定义模板（填写了才显示）
        NSString *c1 = KSCopyPref(@"aiCustomPrompt1");
        if ([c1 isKindOfClass:[NSString class]] && c1.length)
            [sheet addAction:[UIAlertAction actionWithTitle:@"⭐ 自定义模板 1" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a){ run(@"custom1"); }]];
        NSString *c2 = KSCopyPref(@"aiCustomPrompt2");
        if ([c2 isKindOfClass:[NSString class]] && c2.length)
            [sheet addAction:[UIAlertAction actionWithTitle:@"⭐ 自定义模板 2" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a){ run(@"custom2"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"⚙️ AI设置" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                ksToast(@"请打开 设置 → 键盘下方状态 → AI 大模型 配置");
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:sheet animated:YES completion:nil];
    } @catch (NSException *e) {}
}

// 工具栏构建尺寸 / 位置约束（挂在 stack 上的关联对象 key）
static char kKSBuiltSizeKey;
static char kKSCXKey;
static char kKSBtmKey;

#pragma mark - 全删按钮：内嵌图标 + 文件覆盖，缺失时退回 SF Symbol（绝不留空）

static UIImage *ksDeleteAllRawIcon(void) {
    @try {
        // 1) 内嵌 base64：沙盒第三方 App 读不到 /var/jb 文件时也能显示
        static UIImage *embedded;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSData *data = [[NSData alloc] initWithBase64EncodedString:kKSEmbeddedDeleteAllBase64 options:0];
            embedded = [UIImage imageWithData:data];
        });
        if (embedded) return embedded;
        // 2) 用户自定义覆盖文件
        NSArray *bases = @[@"/var/jb/Library/KeyboardStatus", @"/Library/KeyboardStatus"];
        for (NSString *b in bases) {
            NSString *p = [b stringByAppendingPathComponent:@"deleteall.png"];
            UIImage *img = [UIImage imageWithContentsOfFile:p];
            if (img) return img;
        }
    } @catch (NSException *e) {}
    return nil;
}

static UIButton *ksMakeDeleteAllButton(id target, CGFloat iconSize) {
    @try {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        UIImage *raw = ksDeleteAllRawIcon();
        UIImage *img = raw ? [raw imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] : nil;
        if (!img) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:iconSize
                                                                                            weight:UIImageSymbolWeightRegular];
            img = [UIImage systemImageNamed:@"trash" withConfiguration:cfg];
        }
        if (img) {
            [b setImage:img forState:UIControlStateNormal];
            b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        } else {
            [b setTitle:@"清" forState:UIControlStateNormal];
            [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        }
        b.contentEdgeInsets = UIEdgeInsetsMake(2, 2, 2, 2);
        [b.widthAnchor constraintEqualToConstant:iconSize].active = YES;
        [b.heightAnchor constraintEqualToConstant:iconSize].active = YES;
        [b addTarget:target action:@selector(ksActDeleteAll) forControlEvents:UIControlEventTouchUpInside];
        return b;
    } @catch (NSException *e) { return nil; }
}

#pragma mark - 共享工具栏构建（dock 与第三方键盘宿主容器共用，保证行为一致）

// 在 container 里构建/更新工具栏。atTop=NO 贴底往上抬（系统键盘 dock）；
// atTop=YES 贴顶往下让（第三方键盘占满底部，只能放键盘上方）
static void ksBuildToolbarIn(UIView *container, BOOL atTop, id target) {
    @try {
        if (!container) return;
        CGFloat iconSize = KSFloat(@"iconSize", 15);
        CGFloat offX     = KSFloat(@"toolbarX", -25);
        CGFloat lift     = KSFloat(@"toolbarLift", 35);
        CGFloat spacing  = KSFloat(@"toolbarSpacing", 4);
        NSArray *defOrder = @[@"showSelectAll", @"showCut", @"showPaste", @"showClipboard",
                              @"showPhrases", @"showCursor", @"showDismiss", @"showDeleteAll",
                              @"showQuickAction", @"showAI"];
        NSMutableArray *finalOrder = [NSMutableArray array];
        id savedOrder = KSCopyPref(@"toolbarOrder");
        if ([savedOrder isKindOfClass:[NSArray class]]) {
            for (id o in savedOrder)
                if ([defOrder containsObject:o] && ![finalOrder containsObject:o]) [finalOrder addObject:o];
        }
        for (NSString *k in defOrder)
            if (![finalOrder containsObject:k]) [finalOrder addObject:k];
        NSString *sig = [NSString stringWithFormat:@"%.1f|%.0f|%@|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d",
            iconSize, spacing, [finalOrder componentsJoinedByString:@","],
            KSBool(@"showSelectAll", YES), KSBool(@"showCut", YES), KSBool(@"showPaste", YES),
            KSBool(@"showClipboard", YES), KSBool(@"showPhrases", YES), KSBool(@"showCursor", YES),
            KSBool(@"showDismiss", YES), KSBool(@"showDeleteAll", YES), KSBool(@"showQuickAction", NO),
            KSBool(@"showAI", NO), 0];
        UIStackView *stack = (UIStackView *)[container viewWithTag:KS_TOOLBAR_TAG];
        NSString *built = objc_getAssociatedObject(stack, &kKSBuiltSizeKey);
        if (stack && (![built isKindOfClass:[NSString class]] || ![built isEqualToString:sig])) {
            [stack removeFromSuperview];
            stack = nil;
        }
        if (!stack) {
            stack = [[UIStackView alloc] init];
            stack.tag = KS_TOOLBAR_TAG;
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.distribution = UIStackViewDistributionEqualSpacing;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = spacing;
            stack.translatesAutoresizingMaskIntoConstraints = NO;
            [container addSubview:stack];
            UIButton *b;
            for (NSString *k in finalOrder) {
                if ([k isEqualToString:@"showSelectAll"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"selection.pin.in.out", @"全", @selector(ksActSelectAll), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showCut"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"scissors", @"剪", @selector(ksActCut), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showPaste"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"doc.on.clipboard", @"粘", @selector(ksActPaste), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showClipboard"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"list.clipboard", @"历", @selector(ksActClipboard), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showPhrases"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"text.quote", @"语", @selector(ksActPhrases), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showCursor"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"arrow.left",  @"←", @selector(ksActCursorLeft),  target, iconSize); if (b) [stack addArrangedSubview:b];
                    b = ksMakeButton(@"arrow.right", @"→", @selector(ksActCursorRight), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showDismiss"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"keyboard.chevron.compact.down", @"收", @selector(ksActDismiss), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showDeleteAll"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeDeleteAllButton(target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showQuickAction"] && KSBool(k, NO)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"rectangle.stack", @"切", @selector(ksActQuickLaunch), target, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showAI"] && KSBool(k, NO) && KSBool(@"aiEnabled", NO)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"sparkles", @"AI", @selector(ksActAI:), target, iconSize);
                    if (b) {
                        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(ksAILongPress:)];
                        lp.minimumPressDuration = 0.4;
                        [b addGestureRecognizer:lp];
                        [stack addArrangedSubview:b];
                    }
                }
            }
            NSLayoutConstraint *cx  = [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor constant:offX];
            NSLayoutConstraint *pos = [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-lift];
            cx.active = YES; pos.active = YES;
            objc_setAssociatedObject(stack, &kKSBuiltSizeKey, sig, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(stack, &kKSCXKey,  cx,  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(stack, &kKSBtmKey, pos, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            NSLayoutConstraint *cx  = objc_getAssociatedObject(stack, &kKSCXKey);
            NSLayoutConstraint *pos = objc_getAssociatedObject(stack, &kKSBtmKey);
            cx.constant  = offX;
            pos.constant = -lift;
        }
    } @catch (NSException *e) {}
}

#pragma mark - 统一挂载：优先 dock（系统键盘），兜底宿主（第三方键盘），始终底部对齐

// BFS：找 UIKeyboardDockView（系统键盘专用，位置统一在底部，1.2.9 的稳定方案）
static UIView *ksFindDock(UIView *root) {
    if (!root) return nil;
    @try {
        NSMutableArray *q = [NSMutableArray arrayWithObject:root];
        while (q.count) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            if ([NSStringFromClass([v class]) isEqualToString:@"UIKeyboardDockView"]) return v;
            for (UIView *s in v.subviews) [q addObject:s];
        }
    } @catch (NSException *e) {}
    return nil;
}

// BFS：找 UIInputSetHostView（第三方/远程键盘宿主，仅在无 dock 时兜底用）
static UIView *ksFindHost(UIView *root) {
    if (!root) return nil;
    @try {
        NSMutableArray *q = [NSMutableArray arrayWithObject:root];
        while (q.count) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            if ([NSStringFromClass([v class]) isEqualToString:@"UIInputSetHostView"]) return v;
            for (UIView *s in v.subviews) [q addObject:s];
        }
    } @catch (NSException *e) {}
    return nil;
}

static UIWindow *ksKeyboardWindow(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableArray *wins = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in app.connectedScenes)
                if ([s isKindOfClass:[UIWindowScene class]])
                    [wins addObjectsFromArray:((UIWindowScene *)s).windows];
        }
        if (wins.count == 0) [wins addObjectsFromArray:app.windows];
        for (UIWindow *w in wins) {
            if ([NSStringFromClass([w class]) isEqualToString:@"UITextEffectsWindow"]) return w;
        }
    } @catch (NSException *e) {}
    return nil;
}

static void ksRemoveToolbarInWindow(UIWindow *w) {
    if (!w) return;
    @try {
        UIView *old = [w viewWithTag:KS_TOOLBAR_TAG];
        if (old) [old removeFromSuperview];
    } @catch (NSException *e) {}
}

// 统一入口：保证键盘窗口里只有一条工具栏，且始终锚定在底部（位置统一）
static void ksEnsureToolbar(void) {
    @try {
        if (!KSBool(@"enabled", YES) || !KSBool(@"toolbarEnabled", YES)) {
            ksRemoveToolbarInWindow(ksKeyboardWindow());
            return;
        }
        UIWindow *kw = ksKeyboardWindow();
        if (!kw) return;
        // 选容器：优先 dock（系统键盘），否则宿主（第三方键盘，如微信输入法）
        UIView *container = ksFindDock(kw);
        if (!container) container = ksFindHost(kw);
        if (!container) return;   // 宿主延迟加入层级，交给重试逻辑
        // 若已有工具栏但挂在错误容器，先移除再重建，避免重复/错位
        UIView *existing = [kw viewWithTag:KS_TOOLBAR_TAG];
        if (existing && existing.superview != container) [existing removeFromSuperview];
        Class c = [container class];
        ksInstallMethods(c);   // 仅 addMethod，不替换任何系统方法，安全
        ksBuildToolbarIn(container, NO, container);  // 始终底部对齐，位置统一
    } @catch (NSException *e) {}
}

// 键盘出现 / 设置变更时调用；第三方键盘宿主可能延迟加入层级，多重试兜底
static void ksOnKeyboardShow(void) {
    ksEnsureToolbar();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ @try { ksEnsureToolbar(); } @catch (NSException *e) {} });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ @try { ksEnsureToolbar(); } @catch (NSException *e) {} });
}

static void ksOnKeyboardHide(void) {
    @try { ksRemoveToolbarInWindow(ksKeyboardWindow()); } @catch (NSException *e) {}
}

#pragma mark - 注入按钮动作方法（仅 addMethod，不替换系统方法，安全）

static void ksInstallMethods(Class cls) {
    if (!cls) return;
    static NSMutableSet *done;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    NSString *cname = NSStringFromClass(cls);
    if (cname.length == 0 || [done containsObject:cname]) return;
    [done addObject:cname];
    struct { const char *name; IMP imp; const char *types; } methods[] = {
        {"ksActSelectAll",   (IMP)ksActSelectAll,   "v@:"},
        {"ksActCut",         (IMP)ksActCut,         "v@:"},
        {"ksActPaste",       (IMP)ksActPaste,       "v@:"},
        {"ksActCursorLeft",  (IMP)ksActCursorLeft,  "v@:"},
        {"ksActCursorRight", (IMP)ksActCursorRight, "v@:"},
        {"ksActClipboard",   (IMP)ksActClipboard,   "v@:"},
        {"ksActPhrases",     (IMP)ksActPhrases,     "v@:"},
        {"ksActDismiss",     (IMP)ksActDismiss,     "v@:"},
        {"ksActDeleteAll",   (IMP)ksActDeleteAll,   "v@:"},
        {"ksActQuickLaunch", (IMP)ksActQuickLaunch, "v@:"},
        {"ksActAI:",         (IMP)ksActAI,          "v@:@"},
        {"ksAILongPress:",   (IMP)ksAILongPress,    "v@:@"},
    };
    for (size_t i = 0; i < sizeof(methods)/sizeof(methods[0]); i++) {
        SEL sel = sel_registerName(methods[i].name);
        if (!class_addMethod(cls, sel, methods[i].imp, methods[i].types))
            class_replaceMethod(cls, sel, methods[i].imp, methods[i].types);
    }
}

#pragma mark - Hook：键盘 dock（仅普通 App，不碰主屏幕/设置）

@interface UIKeyboardDockView : UIView
@end

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;
    @try { ksEnsureToolbar(); } @catch (NSException *e) {}
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
            ksOnKeyboardShow();   // 第三方键盘宿主工具栏也实时跟随设置
        } @catch (NSException *e) {}
    });
}

#pragma mark - 注入按钮动作方法到 dock 类

%ctor {
    @autoreleasepool {
        // 安全阀：系统关键进程不加载任何 hook/监听，杜绝设备级 respring 循环
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;
        NSArray *blocked = @[@"com.apple.springboard", @"com.apple.Preferences",
                             @"com.apple.WebKit", @"com.apple.backboardd",
                             @"com.apple.ReportCrash", @"com.apple.cfprefsd",
                             @"com.apple.mediaserverd", @"com.apple.dt."];
        for (NSString *bad in blocked) if ([bid hasPrefix:bad]) return;

        // 监听设置面板的实时广播
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        ksPrefsChangedCB, CFSTR(KS_DARWIN_NOTI), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // 第三方键盘（微信输入法等）无 dock → 键盘显示/变化通知时挂载到宿主容器。
        // 注意：这里只注册通知 + addSubview，不 swizzle UIInputSetHostView 等通用容器类。
        static id ksKbObs1, ksKbObs2, ksKbObs3;
        ksKbObs1 = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                                     object:nil queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification *n){ ksOnKeyboardShow(); }];
        ksKbObs2 = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                                     object:nil queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification *n){ ksOnKeyboardHide(); }];
        ksKbObs3 = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidChangeFrameNotification
                                                                     object:nil queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification *n){ ksOnKeyboardShow(); }];
        // 注入按钮动作方法（仅 addMethod，安全）
        for (NSString *n in @[@"UIKeyboardDockView", @"UIInputSetHostView"]) {
            Class c = NSClassFromString(n);
            if (c) ksInstallMethods(c);
        }
        // 注意：手动重启提示只放在设置面板（KSSettingsController），
        // 这里不再弹窗，避免每个 App 启动都弹一次。
    }
}
