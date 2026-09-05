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

#pragma mark - 工具函数

static UIButton* createButton(NSString *sfSymbol, SEL action, id target) {
    @try {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:sfSymbol withConfiguration:config];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        if (img) [btn setImage:img forState:UIControlStateNormal];
        [btn setTintColor:[UIColor labelColor]];
        btn.contentEdgeInsets = UIEdgeInsetsMake(3, 4, 3, 4);
        [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        return btn;
    } @catch(NSException *e) {
        return nil;
    }
}

static UIView* separator() {
    UILabel *sep = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 20)];
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
                // 通过 UITextInput 协议插入文本
                UIResponder *fr = findFirstResponder();
                if ([fr conformsToProtocol:@protocol(UITextInput)]) {
                    [UIPasteboard generalPasteboard].string = item;
                    [(id<UITextInput>)fr insertText:item];
                }
            } @catch(NSException *e) {}
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [clipboardHistory removeAllObjects];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Hook

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    if ([self viewWithTag:999]) return;

    @try {
        UIStackView *stack = [[UIStackView alloc] init];
        stack.tag = 999;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 5;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:stack];
        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-35].active = YES;

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

        [stack addArrangedSubview:separator()];

        b = createButton(@"keyboard.chevron.compact.down", @selector(didTapDismiss), self);
        if (b) [stack addArrangedSubview:b];
    } @catch(NSException *e) {
    }
}

%end

#pragma mark - 按钮 Action

// 标准编辑操作：通过 UIApplication 沿着响应者链发送到 firstResponder
static void didTapUndo(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(undo:) to:nil from:self forEvent:nil];
    } @catch(NSException *e) {}
}

static void didTapSelectAll(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil];
    } @catch(NSException *e) {}
}

static void didTapPaste(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
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

// 收起键盘：使用 UIKeyboardImpl 的 hideKeyboard 方法
static void didTapDismiss(id self, SEL _cmd) {
    @try {
        [[UIKeyboardImpl sharedInstance] hideKeyboard];
    } @catch(NSException *e) {}
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