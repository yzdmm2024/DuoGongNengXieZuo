# 键盘下方状态 — rootless tweak + 设置面板
# 适配 iOS 16 rootless（Dopamine / Relaxin / RootHide 隐根越狱）
# 构建：make package  （需在 macOS + theos 环境下，CI 已配置）

TARGET := iphone:clang:latest:16.0
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
BUNDLE_NAME = KeyboardStatusPrefs
KeyboardStatusPrefs_FILES = Preferences/KSSettingsController.m
KeyboardStatusPrefs_INSTALL_PATH = /Library/PreferenceBundles
KeyboardStatusPrefs_FRAMEWORKS = UIKit Foundation
KeyboardStatusPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -w
KeyboardStatusPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
KeyboardStatusPrefs_RESOURCES = Preferences/Root.plist Preferences/Info.plist

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
