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

#pragma mark - 快捷短语持久化

static NSString *const kQPSKey = @"MultiWriter_QuickPhrases";

static NSMutableArray *loadQuickPhrases() {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kQPSKey];
    if (saved.count > 0) return [saved mutableCopy];
    return [@[@"好的", @"收到", @"谢谢", @"不客气", @"好的，马上处理", @"收到，稍后回复", @"请稍等", @"没问题", @"了解", @"OK", @"Got it", @"辛苦了"] mutableCopy];
}

static void saveQuickPhrases(NSArray *phrases) {
    [[NSUserDefaults standardUserDefaults] setObject:phrases forKey:kQPSKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 快捷短语编辑器

@interface QPEditorViewController : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) NSMutableArray *phrases;
@end

@implementation QPEditorViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _phrases = loadQuickPhrases();
        self.title = @"快捷短语";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addPhrase)];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.estimatedRowHeight = 44;
    self.tableView.tableFooterView = [[UIView alloc] init];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.phrases.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
    cell.textLabel.text = self.phrases[ip.row];
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    @try {
        NSString *text = self.phrases[ip.row];
        UIResponder *fr = [self findFirstResponder];
        if ([fr conformsToProtocol:@protocol(UITextInput)]) {
            [(id<UITextInput>)fr insertText:text];
        }
    } @catch(NSException *e) {}
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 左滑删除
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete) {
        [self.phrases removeObjectAtIndex:ip.row];
        saveQuickPhrases(self.phrases);
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleDelete;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"删除";
}

- (void)addPhrase {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加短语" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"输入短语内容";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (text.length > 0) {
            [self.phrases addObject:text];
            saveQuickPhrases(self.phrases);
            NSIndexPath *ip = [NSIndexPath indexPathForRow:self.phrases.count - 1 inSection:0];
            [self.tableView insertRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIResponder *)findFirstResponder {
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
    if (!keyWindow) keyWindow = [[UIApplication sharedApplication] keyWindow];
    return [keyWindow valueForKey:@"firstResponder"];
}

@end

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

#pragma mark - 快捷短语弹窗

static void showQuickPhrases() {
    UIViewController *vc = topViewController();
    if (!vc) return;

    QPEditorViewController *editor = [[QPEditorViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    if (@available(iOS 13.0, *)) {
        nav.modalPresentationStyle = UIModalPresentationAutomatic;
    } else {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    [vc presentViewController:nav animated:YES completion:nil];
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
        stack.spacing = 4;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:stack];
        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-35].active = YES;

        UIButton *b;
        b = createButton(@"selection.pin.in.out",   @selector(didTapSelectAll), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"scissors",               @selector(didTapCut),  self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"doc.on.clipboard",       @selector(didTapPaste), self);
        if (b) [stack addArrangedSubview:b];

        [stack addArrangedSubview:separator()];

        b = createButton(@"arrow.left",  @selector(didTapMoveLeft), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"arrow.right", @selector(didTapMoveRight), self);
        if (b) [stack addArrangedSubview:b];

        [stack addArrangedSubview:separator()];

        b = createButton(@"list.clipboard",  @selector(didTapClipboardHistory), self);
        if (b) [stack addArrangedSubview:b];
        b = createButton(@"text.quote",      @selector(didTapQuickPhrases), self);
        if (b) [stack addArrangedSubview:b];

        [stack addArrangedSubview:separator()];

        b = createButton(@"keyboard.chevron.compact.down", @selector(didTapDismiss), self);
        if (b) [stack addArrangedSubview:b];
    } @catch(NSException *e) {
    }
}

%end

#pragma mark - 按钮 Action

static void didTapCut(id self, SEL _cmd) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(cut:) to:nil from:nil forEvent:nil];
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
            {"didTapCut",              (IMP)didTapCut},
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