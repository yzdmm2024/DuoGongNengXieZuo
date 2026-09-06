#!/bin/bash
# 键盘下方状态 - 本地构建（仅 macOS + theos 环境）
# CI 走 .github/workflows/build.yml，本脚本方便在 Mac 上本地验证编译

set -e

export THEOS="${THEOS:-/opt/theos}"

if [ ! -d "$THEOS" ]; then
    echo "未找到 theos，请先安装：git clone --recursive https://github.com/theos/theos.git /opt/theos"
    exit 1
fi

echo "=== Building 键盘下方状态 ==="
make clean 2>/dev/null || true
make package FINALPACKAGE=1
echo "=== 完成，产物在 packages/ ==="
ls -lh packages/*.deb
