#import <Preferences/Preferences.h>

@interface KSSettingsController : PSListController
@end

@implementation KSSettingsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
