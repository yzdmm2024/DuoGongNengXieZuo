TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 多功能写作
多功能写作_FILES = src/Tweak.xm
多功能写作_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
多功能写作_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@echo "=== Build complete ==="
	@ls -lh $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/多功能写作.dylib