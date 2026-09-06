// Auto-generated from Tweak.xm by logos2objc.py (Logos -> Objective-C)
// 纯 Windows 交叉编译 dylib 用途；不要手动编辑。
#import <substrate.h>
#import <objc/runtime.h>

#import <UIKit/UIKit.h>
#import <substrate.h>

#pragma mark - 私有类声明

@interface UIKeyboardDockView : UIView
@end

@interface UIKeyboardImpl : UIResponder
+ (id)sharedInstance;
- (void)hideKeyboard;
@end

#pragma mark - 全局状态

static NSMutableArray *clipboardHistory = nil;
static NSArray *quickPhrases = nil;
static const NSUInteger kMaxClipboardItems = 20;

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
            [NSString stringWithUTF8String:"\345\245\275\347\232\204"], [NSString stringWithUTF8String:"\346\224\266\345\210\260"], [NSString stringWithUTF8String:"\350\260\242\350\260\242"], [NSString stringWithUTF8String:"\344\270\215\345\256\242\346\260\224"],
            [NSString stringWithUTF8String:"\345\245\275\347\232\204\357\274\214\351\251\254\344\270\212\345\244\204\347\220\206"], [NSString stringWithUTF8String:"\346\224\266\345\210\260\357\274\214\347\250\215\345\220\216\345\233\236\345\244\215"],
            [NSString stringWithUTF8String:"\350\257\267\347\250\215\347\255\211"], [NSString stringWithUTF8String:"\346\262\241\351\227\256\351\242\230"], [NSString stringWithUTF8String:"\344\272\206\350\247\243"],
            @"OK", @"Got it", @"Thanks", @"Sure",
            [NSString stringWithUTF8String:"\347\255\211\344\270\200\344\270\213"], [NSString stringWithUTF8String:"\351\251\254\344\270\212\345\210\260"], [NSString stringWithUTF8String:"\350\276\233\350\213\246\344\272\206"]
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

// 通过 KVC 获取 UIWindow 的私有 firstResponder 属性
static UIResponder* findFirstResponder() {
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
        }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
        return [keyWindow valueForKey:@"firstResponder"];
    } @catch(NSException *e) {
        return nil;
    }
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
        }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
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
            alertControllerWithTitle:[NSString stringWithUTF8String:"\345\211\252\350\264\264\346\235\277\345\216\206\345\217\262"]
                             message:[NSString stringWithUTF8String:"\346\232\202\346\227\240\345\244\215\345\210\266\350\256\260\345\275\225"]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:"\347\241\256\345\256\232"] style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithUTF8String:"\345\211\252\350\264\264\346\235\277\345\216\206\345\217\262"]
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *item in clipboardHistory) {
        NSString *display = item.length > 40 ? [[item substringToIndex:40] stringByAppendingString:[NSString stringWithUTF8String:"\342\200\246"]] : item;
        [alert addAction:[UIAlertAction actionWithTitle:display style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            @try {
                // 通过 UITextInput 协议插入文本
                UIResponder *fr = findFirstResponder();
                if ([fr conformsToProtocol:@protocol(UITextInput)]) {
                    [UIPasteboard generalPasteboard].string = item;
                    [(id<UITextInput>)fr insertText:item];
                }
            } @catch(NSException *e) {}
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:"\346\270\205\347\251\272\345\216\206\345\217\262"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [clipboardHistory removeAllObjects];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:"\345\217\226\346\266\210"] style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 快捷短语弹窗

static void showQuickPhrases() {
    initPhrasesOnce();
    UIViewController *vc = topViewController();
    if (!vc) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithUTF8String:"\345\277\253\346\215\267\347\237\255\350\257\255"]
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *phrase in quickPhrases) {
        [alert addAction:[UIAlertAction actionWithTitle:phrase style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            @try {
                // 通过 UITextInput 协议插入文本
                UIResponder *fr = findFirstResponder();
                if ([fr conformsToProtocol:@protocol(UITextInput)]) {
                    [(id<UITextInput>)fr insertText:phrase];
                }
            } @catch(NSException *e) {}
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:"\345\217\226\346\266\210"] style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Hook


static void (*_logos_orig$UIKeyboardDockView$layoutSubviews)(id, SEL) = NULL;
static void _logos_method$UIKeyboardDockView$layoutSubviews(id self, SEL _cmd) {

    ((void (*)(id, SEL))_logos_orig$UIKeyboardDockView$layoutSubviews)(self, _cmd);

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



#pragma mark - 按钮 Action

// 标准编辑操作：通过 UIApplication 沿着响应者链发送到 firstResponder
static void didTapUndo(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(undo:) to:nil from:self forEvent:nil];
    } @catch(NSException *e) {}
}

static void didTapSelectAll(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(selectAll:) to:nil from:self forEvent:nil];
    } @catch(NSException *e) {}
}

static void didTapPaste(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:self forEvent:nil];
    } @catch(NSException *e) {}
}

// 光标移动：通过 UITextInput 协议操作
static void didTapMoveLeft(id self, SEL _cmd) {
    @try {
        UIResponder *fr = findFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) return;
        id<UITextInput> input = (id<UITextInput>)fr;
        UITextRange *selectedRange = [input selectedTextRange];
        if (!selectedRange) return;
        UITextPosition *newPos = [input positionFromPosition:selectedRange.start offset:-1];
        if (!newPos) return;
        [input setSelectedTextRange:[input textRangeFromPosition:newPos toPosition:newPos]];
    } @catch(NSException *e) {}
}

static void didTapMoveRight(id self, SEL _cmd) {
    @try {
        UIResponder *fr = findFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) return;
        id<UITextInput> input = (id<UITextInput>)fr;
        UITextRange *selectedRange = [input selectedTextRange];
        if (!selectedRange) return;
        UITextPosition *newPos = [input positionFromPosition:selectedRange.end offset:1];
        if (!newPos) return;
        [input setSelectedTextRange:[input textRangeFromPosition:newPos toPosition:newPos]];
    } @catch(NSException *e) {}
}

static void didTapClipboardHistory(id self, SEL _cmd) {
    showClipboardHistory();
}

static void didTapQuickPhrases(id self, SEL _cmd) {
    showQuickPhrases();
}

// 收起键盘：使用 UIKeyboardImpl 的 hideKeyboard 方法
static void didTapDismiss(id self, SEL _cmd) {
    @try {
        [[UIKeyboardImpl sharedInstance] hideKeyboard];
    } @catch(NSException *e) {}
}

static void _logos_user_ctor(void) {
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
                class_replaceMethod(cls, sel, methods[i].imp, "v@:");
            }
        }
    }
}
#pragma mark - Logos auto-generated registration & constructor
static void _logos_register(void) {
    {
        Class _cls = objc_getClass("UIKeyboardDockView");
        if (_cls && class_respondsToSelector(_cls, @selector(layoutSubviews))) {
            MSHookMessageEx(_cls, @selector(layoutSubviews), (IMP)&_logos_method$UIKeyboardDockView$layoutSubviews, (IMP *)&_logos_orig$UIKeyboardDockView$layoutSubviews);
        }
    }
}

__attribute__((constructor)) static void _logos_initializer(void) {
    _logos_register();
    _logos_user_ctor();
}
