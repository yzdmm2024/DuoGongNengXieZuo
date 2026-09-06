# 键盘下方状态 — rootless tweak + 设置面板
# 适配 iOS 16 rootless（Dopamine / Relaxin / RootHide 隐根越狱）
# 构建：make package  （需在 macOS + theos 环境下，CI 已配置）

# SDK 14.5（theos/sdks）：新 Xcode SDK 已不带私有框架 tbd（Preferences 等），
# 链接 Preferences.framework 必须用老 SDK；deployment 14.0 不影响跑 16.6.1
TARGET := iphone:clang:14.5:14.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ===== Tweak 本体：注入键盘 dock，显示只读状态条 =====
TWEAK_NAME = KeyboardStatus
KeyboardStatus_FILES = src/Tweak.xm
KeyboardStatus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -w
KeyboardStatus_FRAMEWORKS = UIKit Foundation CoreGraphics

# ===== 设置面板 PreferenceBundle（由 PreferenceLoader 在「设置」里加载）=====
# Info.plist / Root.plist 放在 layout/Library/PreferenceBundles/KeyboardStatusPrefs.bundle/
# （对齐超级截图的验证做法；_RESOURCES 声明不生效）
BUNDLE_NAME = KeyboardStatusPrefs
KeyboardStatusPrefs_FILES = Preferences/KSSettingsController.m
KeyboardStatusPrefs_INSTALL_PATH = /Library/PreferenceBundles
KeyboardStatusPrefs_FRAMEWORKS = UIKit Foundation
# 关键修复：显式链接 Preferences（dyld chained fixups 下不能用 dynamic_lookup，
# 否则设置里加载 bundle 直接报「已损坏或丢失必要的资源」——与超级截图面板二进制对比确认）
KeyboardStatusPrefs_PRIVATE_FRAMEWORKS = Preferences
# theos 只发 -framework 不发搜索路径（instance/rules.mk 110 行），须手动补 -F
KeyboardStatusPrefs_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH)
KeyboardStatusPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -w

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
