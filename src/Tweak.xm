#import <UIKit/UIKit.h>
#import <substrate.h>

#pragma mark - 私有类声明

@interface UIKeyboardDockView : UIView
@end

@interface UIKeyboardImpl : UIResponder
+ (id)sharedInstance;
- (void)dismissKeyboard;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
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

#pragma mark - 初始化

__attribute__((constructor))
static void initPlugin() {
    clipboardHistory = [[NSMutableArray alloc] init];
    quickPhrases = @[
        @"好的", @"收到", @"谢谢", @"不客气",
        @"好的，马上处理", @"收到，稍后回复",
        @"请稍等", @"没问题", @"了解",
        @"OK", @"Got it", @"Thanks", @"Sure",
        @"等一下", @"马上到", @"辛苦了"
    ];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIPasteboardChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note)
    {
        NSString *text = [UIPasteboard generalPasteboard].string;
        if (text.length == 0) return;
        if ([clipboardHistory.firstObject isEqualToString:text]) return;
        [clipboardHistory insertObject:text atIndex:0];
        if (clipboardHistory.count > kMaxClipboardItems) {
            [clipboardHistory removeLastObject];
        }
    }];
}

#pragma mark - 工具函数

static UIButton* createButton(NSString *sfSymbol, SEL action, id target) {
    UIImage *img = [UIImage systemImageNamed:sfSymbol];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setImage:img forState:UIControlStateNormal];
    [btn setTintColor:[UIColor labelColor]];
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static void haptic() {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] init];
    [gen impactOccurred];
}

static UIViewController* topViewController() {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = keyWindow.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    return root;
}

#pragma mark - 剪贴板历史弹窗

static void showClipboardHistory() {
    if (clipboardHistory.count == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"剪贴板历史"
                             message:@"暂无复制记录"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"剪贴板历史"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *item in clipboardHistory) {
        NSString *display = item.length > 40 ? [[item substringToIndex:40] stringByAppendingString:@"…"] : item;
        [alert addAction:[UIAlertAction actionWithTitle:display style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = item;
            [[UIKeyboardImpl sharedInstance] paste:nil];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [clipboardHistory removeAllObjects];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [topViewController() presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 快捷短语弹窗

static void showQuickPhrases() {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"快捷短语"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *phrase in quickPhrases) {
        [alert addAction:[UIAlertAction actionWithTitle:phrase style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [[UIKeyboardImpl sharedInstance] insertText:phrase];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [topViewController() presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 分隔线

static UIView* separator() {
    UILabel *sep = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 24)];
    sep.backgroundColor = [UIColor systemGray4Color];
    return sep;
}

#pragma mark - Hook

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    UIView *old = [self viewWithTag:999];
    [old removeFromSuperview];

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

    /* 撤销 */
    [stack addArrangedSubview:createButton(@"arrow.uturn.backward", @selector(didTapUndo), self)];
    /* 全选 */
    [stack addArrangedSubview:createButton(@"selection.pin.in.out",  @selector(didTapSelectAll), self)];
    /* 粘贴 */
    [stack addArrangedSubview:createButton(@"doc.on.clipboard",      @selector(didTapPaste), self)];

    [stack addArrangedSubview:separator()];

    /* 光标左移 */
    [stack addArrangedSubview:createButton(@"arrow.left",  @selector(didTapMoveLeft), self)];
    /* 光标右移 */
    [stack addArrangedSubview:createButton(@"arrow.right", @selector(didTapMoveRight), self)];

    [stack addArrangedSubview:separator()];

    /* 剪贴板历史 */
    [stack addArrangedSubview:createButton(@"list.clipboard", @selector(didTapClipboardHistory), self)];
    /* 快捷短语 */
    [stack addArrangedSubview:createButton(@"text.quote",     @selector(didTapQuickPhrases), self)];

    [stack addArrangedSubview:separator()];

    /* 收起 */
    [stack addArrangedSubview:createButton(@"keyboard.chevron.compact.down", @selector(didTapDismiss), self)];
}

- (void)didTapUndo {
    haptic();
    [[UIKeyboardImpl sharedInstance] undo:nil];
}

- (void)didTapSelectAll {
    haptic();
    [[UIKeyboardImpl sharedInstance] selectAll:nil];
}

- (void)didTapPaste {
    haptic();
    [[UIKeyboardImpl sharedInstance] paste:nil];
}

- (void)didTapMoveLeft {
    haptic();
    [[UIKeyboardImpl sharedInstance] moveBackward:nil];
}

- (void)didTapMoveRight {
    haptic();
    [[UIKeyboardImpl sharedInstance] moveForward:nil];
}

- (void)didTapClipboardHistory {
    haptic();
    showClipboardHistory();
}

- (void)didTapQuickPhrases {
    haptic();
    showQuickPhrases();
}

- (void)didTapDismiss {
    haptic();
    [[UIKeyboardImpl sharedInstance] dismissKeyboard];
}

%end