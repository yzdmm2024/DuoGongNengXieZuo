#import <UIKit/UIKit.h>
#import <substrate.h>

#pragma mark - 私有类声明

@interface UIKeyboardDockView : UIView
@end

@interface UIKeyboardImpl : UIResponder
+ (id)sharedInstance;
- (void)dismissKeyboard;
- (void)undo:(id)sender;
- (void)paste:(id)sender;
- (void)selectAll:(id)sender;
- (void)moveBackward:(id)sender;
- (void)moveForward:(id)sender;
- (void)insertText:(NSString *)text;
@end

#pragma mark - 全局状态

static NSMutableArray *clipboardHistory = nil;
static NSArray *quickPhrases = nil;
static const NSUInteger kMaxClipboardItems = 20;
// isLayoutBusy 已移除，改用 dispatch_once 避免重复创建

#pragma mark - 懒加载初始化

static void initClipboardOnce() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        clipboardHistory = [[NSMutableArray alloc] init];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIPasteboardChangedNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note)
        {
            @try {
                NSString *text = [UIPasteboard generalPasteboard].string;
                if (text.length == 0) return;
                if ([clipboardHistory.firstObject isEqualToString:text]) return;
                [clipboardHistory insertObject:text atIndex:0];
                if (clipboardHistory.count > kMaxClipboardItems) {
                    [clipboardHistory removeLastObject];
                }
            } @catch(NSException *e) {}
        }];
    });
}

static void initPhrasesOnce() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        quickPhrases = @[
            @"好的", @"收到", @"谢谢", @"不客气",
            @"好的，马上处理", @"收到，稍后回复",
            @"请稍等", @"没问题", @"了解",
            @"OK", @"Got it", @"Thanks", @"Sure",
            @"等一下", @"马上到", @"辛苦了"
        ];
    });
}

#pragma mark - 工具函数

static UIButton* createButton(NSString *sfSymbol, SEL action, id target) {
    @try {
        UIImage *img = [UIImage systemImageNamed:sfSymbol];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        if (img) [btn setImage:img forState:UIControlStateNormal];
        [btn setTintColor:[UIColor labelColor]];
        [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        return btn;
    } @catch(NSException *e) {
        return nil;
    }
}

static UIView* separator() {
    UILabel *sep = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 24)];
    sep.backgroundColor = [UIColor systemGray4Color];
    return sep;
}

static UIViewController* topViewController() {
    @try {
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
            for (UIScene *scene in scenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    keyWindow = ((UIWindowScene *)scene).keyWindow;
                    break;
                }
            }
            if (!keyWindow && [scenes anyObject]) {
                keyWindow = ((UIWindowScene *)[scenes anyObject]).keyWindow;
            }
        }
        if (!keyWindow) return nil;
        UIViewController *root = keyWindow.rootViewController;
        while (root.presentedViewController) {
            root = root.presentedViewController;
        }
        return root;
    } @catch(NSException *e) {
        return nil;
    }
}

#pragma mark - 剪贴板历史弹窗

static void showClipboardHistory() {
    initClipboardOnce();
    UIViewController *vc = topViewController();
    if (!vc) return;

    if (clipboardHistory.count == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"剪贴板历史"
                             message:@"暂无复制记录"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"剪贴板历史"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *item in clipboardHistory) {
        NSString *display = item.length > 40 ? [[item substringToIndex:40] stringByAppendingString:@"…"] : item;
        [alert addAction:[UIAlertAction actionWithTitle:display style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            @try {
                [UIPasteboard generalPasteboard].string = item;
                [[UIKeyboardImpl sharedInstance] paste:nil];
            } @catch(NSException *e) {}
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [clipboardHistory removeAllObjects];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 快捷短语弹窗

static void showQuickPhrases() {
    initPhrasesOnce();
    UIViewController *vc = topViewController();
    if (!vc) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"快捷短语"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *phrase in quickPhrases) {
        [alert addAction:[UIAlertAction actionWithTitle:phrase style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            @try {
                [[UIKeyboardImpl sharedInstance] insertText:phrase];
            } @catch(NSException *e) {}
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Hook

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    // 工具栏不存在时才创建，避免每次 layoutSubviews 重建导致 watchdog 超时
    if ([self viewWithTag:999]) return;

    @try {
        UIStackView *stack = [[UIStackView alloc] init];
        stack.tag = 999;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 6;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:stack];
        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6].active = YES;

        UIButton *b;
        b = createButton(@"arrow.uturn.backward", @selector(didTapUndo), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"selection.pin.in.out",  @selector(didTapSelectAll), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"doc.on.clipboard",      @selector(didTapPaste), self);
        if (b) [stack addArrangedSubview:b];

        [stack addArrangedSubview:separator()];

        b = createButton(@"arrow.left",  @selector(didTapMoveLeft), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"arrow.right", @selector(didTapMoveRight), self);
        if (b) [stack addArrangedSubview:b];

        [stack addArrangedSubview:separator()];

        b = createButton(@"list.clipboard", @selector(didTapClipboardHistory), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"text.quote",     @selector(didTapQuickPhrases), self);
        if (b) [stack addArrangedSubview:b];

        [stack addArrangedSubview:separator()];

        b = createButton(@"keyboard.chevron.compact.down", @selector(didTapDismiss), self);
        if (b) [stack addArrangedSubview:b];
    } @catch(NSException *e) {
    }
}

%end

#pragma mark - 按钮 Action（用 %ctor 手动注册，防止 Logos 不自动添加新方法）

static void didTapUndo(id self, SEL _cmd) {
    @try { [[UIKeyboardImpl sharedInstance] undo:nil]; } @catch(NSException *e) {}
}

static void didTapSelectAll(id self, SEL _cmd) {
    @try { [[UIKeyboardImpl sharedInstance] selectAll:nil]; } @catch(NSException *e) {}
}

static void didTapPaste(id self, SEL _cmd) {
    @try { [[UIKeyboardImpl sharedInstance] paste:nil]; } @catch(NSException *e) {}
}

static void didTapMoveLeft(id self, SEL _cmd) {
    @try { [[UIKeyboardImpl sharedInstance] moveBackward:nil]; } @catch(NSException *e) {}
}

static void didTapMoveRight(id self, SEL _cmd) {
    @try { [[UIKeyboardImpl sharedInstance] moveForward:nil]; } @catch(NSException *e) {}
}

static void didTapClipboardHistory(id self, SEL _cmd) {
    showClipboardHistory();
}

static void didTapQuickPhrases(id self, SEL _cmd) {
    showQuickPhrases();
}

static void didTapDismiss(id self, SEL _cmd) {
    @try { [[UIKeyboardImpl sharedInstance] dismissKeyboard]; } @catch(NSException *e) {}
}

%ctor {
    @autoreleasepool {
        Class cls = NSClassFromString(@"UIKeyboardDockView");
        if (!cls) return;

        struct { const char *name; IMP imp; } methods[] = {
            {"didTapUndo",             (IMP)didTapUndo},
            {"didTapSelectAll",        (IMP)didTapSelectAll},
            {"didTapPaste",            (IMP)didTapPaste},
            {"didTapMoveLeft",         (IMP)didTapMoveLeft},
            {"didTapMoveRight",        (IMP)didTapMoveRight},
            {"didTapClipboardHistory", (IMP)didTapClipboardHistory},
            {"didTapQuickPhrases",     (IMP)didTapQuickPhrases},
            {"didTapDismiss",          (IMP)didTapDismiss},
        };

        for (size_t i = 0; i < sizeof(methods)/sizeof(methods[0]); i++) {
            SEL sel = sel_registerName(methods[i].name);
            if (!class_addMethod(cls, sel, methods[i].imp, "v@:")) {
                // 如果添加失败（可能已存在），尝试替换
                class_replaceMethod(cls, sel, methods[i].imp, "v@:");
            }
        }
    }
}