#!/bin/bash
# 多功能写作 - Build Script
# macOS only (Xcode + ldid required)

set -e

PROJECT="多功能写作"
SRC_DIR="src"
BUILD_DIR="build"
ARCH="arm64"
MIN_IOS="16.0"

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")

echo "=== Building $PROJECT ==="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Install logos2objc if not present
if ! command -v logos2objc &> /dev/null; then
    echo "Installing logos2objc..."
    curl -L -o /usr/local/bin/logos2objc https://raw.githubusercontent.com/theos/logos/master/logos2objc.py 2>/dev/null || true
    chmod +x /usr/local/bin/logos2objc 2>/dev/null || true
fi

# Preprocess Tweak.xm → Tweak.cpp
echo "Preprocessing Tweak.xm..."
python3 -c "
import re, sys
with open('$SRC_DIR/Tweak.xm') as f:
    content = f.read()
# Simple Logos preprocessor
content = re.sub(r'%hook\s+(\w+)', r'static void _logos_hook_\1() { Class _logos_class = objc_getClass(\"\1\");', content)
content = re.sub(r'%end', '}', content)
content = re.sub(r'%orig', '((void(*)(id, SEL))_logos_orig)(self, _cmd)', content)
content = re.sub(r'- \((\w+)\)(\w+)\{', r'static \1 _logos_orig_\2(id self, SEL _cmd); \1 \2(id self, SEL _cmd) {', content)
with open('$BUILD_DIR/Tweak.cpp', 'w') as f:
    f.write('#import <objc/runtime.h>\n#import <objc/message.h>\n' + content)
"

CFLAGS="-isysroot $SDK_PATH -miphoneos-version-min=$MIN_IOS -arch $ARCH"
CFLAGS="$CFLAGS -fobjc-arc -I."
LDFLAGS="-framework UIKit -framework Foundation -framework CoreGraphics"

echo "Compiling..."
clang $CFLAGS -c "$BUILD_DIR/Tweak.cpp" -o "$BUILD_DIR/Tweak.o"

echo "Linking dylib..."
clang $CFLAGS -dynamiclib \
    -flat_namespace -undefined suppress \
    -install_name @rpath/多功能写作.dylib \
    -rpath @loader_path/.jbroot/Library/Frameworks \
    -rpath @loader_path/.jbroot/usr/lib \
    -rpath /var/jb/Library/Frameworks \
    -rpath /var/jb/usr/lib \
    "$BUILD_DIR/Tweak.o" \
    -o "$BUILD_DIR/多功能写作.dylib" \
    $LDFLAGS -lobjc -lc++

# Sign with ldid
echo "Signing..."
ldid -S "$BUILD_DIR/多功能写作.dylib"

echo "=== Build Complete ==="
echo "Output: $BUILD_DIR/多功能写作.dylib"
ls -lh "$BUILD_DIR/多功能写作.dylib"