#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

#pragma mark - 配置

static NSString *const KS_SUITE = @"com.yzdmm.keyboardstatus";
static NSInteger const KS_TAG = 9173;

#pragma mark - 偏好读取（跨进程：读设置面板写入的全局域，改动即时生效）

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

#pragma mark - 网络类型（标准 BSD socket，无额外框架依赖，零风险）

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

#pragma mark - 状态文本拼接

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
        if (KSBool(@"showClipboard", YES)) {
            NSString *c = [UIPasteboard generalPasteboard].string;
            if (c.length == 0) c = @"空";
            else if (c.length > 10) c = [[c substringToIndex:10] stringByAppendingString:@"…"];
            [parts addObject:[NSString stringWithFormat:@"📋 %@", c]];
        }
        if (KSBool(@"showNetwork", YES)) {
            [parts addObject:[NSString stringWithFormat:@"📶 %@", KSNetworkType()]];
        }
    } @catch (NSException *e) {}
    return [parts componentsJoinedByString:@"   "];
}

#pragma mark - 状态标签（全局弱引用，避免野指针崩溃）

static __weak UILabel *KSLabel = nil;

static void KSSetupTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t){
            UILabel *label = KSLabel;
            if (label == nil) return;
            if (!KSBool(@"enabled", YES)) {
                [label removeFromSuperview];
                KSLabel = nil;
                return;
            }
            if (label.superview == nil) { KSLabel = nil; return; }
            @try { label.text = KSBuildStatus(); }
            @catch (NSException *e) {}
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}

#pragma mark - Hook：只挂在键盘 dock 上，不碰任何系统关键进程

@interface UIKeyboardDockView : UIView
@end

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    @try {
        if (!KSBool(@"enabled", YES)) {
            UIView *old = [self viewWithTag:KS_TAG];
            if (old) [old removeFromSuperview];
            if (KSLabel == (UILabel *)old) KSLabel = nil;
            return;
        }

        UILabel *existing = (UILabel *)[self viewWithTag:KS_TAG];
        if (existing) {
            KSLabel = existing;
            return;
        }

        UILabel *label = [[UILabel alloc] init];
        label.tag = KS_TAG;
        label.userInteractionEnabled = NO;        // 纯显示，绝不拦截触摸
        label.backgroundColor = [UIColor secondarySystemBackgroundColor];
        label.textColor = [UIColor secondaryLabelColor];
        label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        label.textAlignment = NSTextAlignmentCenter;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],
            [label.heightAnchor constraintEqualToConstant:20]
        ]];

        label.text = KSBuildStatus();
        KSLabel = label;
        KSSetupTimer();
    } @catch (NSException *e) {}
}

%end
