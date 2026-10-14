#!/bin/bash
#
# 构建 DeepSeek 余额 Pock 组件
#
#   ./build.sh              编译出 DeepSeekBalance.pock
#   ./build.sh --install    编译并安装到 Pock
#
# 只用 Command Line Tools，不需要 Xcode / CocoaPods / ibtool。
# 首次运行会自动拉取并编译依赖（PockKit 0.2.0 + SnapKit），大约需要半分钟。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="DeepSeekBalance"
POCK="$ROOT/$NAME.pock"
BUILD="$ROOT/.build"
FW="$BUILD/frameworks"
CACHE="$BUILD/modules"
DEPS="$BUILD/deps"
TARGET="arm64-apple-macosx11.0"          # 带 Touch Bar 的机器最低是 macOS 11
INSTALL="${1:-}"
WIDGETS_DIR="$HOME/Library/Application Support/Pock/Widgets"

export SWIFT_EXEC_CACHE="$BUILD"
mkdir -p "$FW" "$CACHE" "$DEPS"

# 把编译出的模块做成标准 framework 目录结构，方便用 -F 链接
make_fw() {
    local n="$1"
    mkdir -p "$FW/$n.framework/Versions/A/Resources"
    ln -sfn A "$FW/$n.framework/Versions/Current"
    ln -sfn "Versions/Current/$n" "$FW/$n.framework/$n"
    ln -sfn "Versions/Current/Resources" "$FW/$n.framework/Resources"
}

build_module() {          # $1 = 模块名，其余参数转给 swiftc
    local n="$1"; shift
    make_fw "$n"
    swiftc -emit-module -emit-library -module-name "$n" -swift-version 5 \
        -target "$TARGET" -module-cache-path "$CACHE" \
        -emit-module-path "$FW/$n.swiftmodule" \
        -Xlinker -install_name -Xlinker "@rpath/$n.framework/Versions/A/$n" \
        -o "$FW/$n.framework/Versions/A/$n" "$@"
}

# ---------------------------------------------------------------------------
# 依赖：PockKit 0.2.0（必须和 Pock 0.9.0 内置的版本一致，否则符号对不上）
# ---------------------------------------------------------------------------
if [ ! -f "$FW/PockKit.framework/Versions/A/PockKit" ]; then
    echo "==> 首次构建，拉取并编译依赖"

    [ -d "$DEPS/SnapKit" ] || git clone --depth 1 -q \
        https://github.com/SnapKit/SnapKit.git "$DEPS/SnapKit"
    [ -d "$DEPS/pockkit" ] || git clone --depth 1 -q --branch 0.2.0 \
        https://github.com/pock/pockkit.git "$DEPS/pockkit"

    # PockKit 0.2.0 这个 tag 的源码本身有残缺：部分文件在用 NSView / CGFloat
    # 却没有 import AppKit，直接编会报 cannot find type 'NSView' in scope。
    # 这里补上，只影响我们编译期用的模块，不改动它的公开 API。
    while IFS= read -r f; do
        if ! grep -qE '^import (AppKit|Cocoa)' "$f"; then
            printf 'import AppKit\n' | cat - "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        fi
    done < <(find "$DEPS/pockkit/PockKit" -name '*.swift')

    echo "    - SnapKit"
    build_module SnapKit -framework AppKit \
        $(find "$DEPS/SnapKit/Sources" -name '*.swift')

    echo "    - PockKit 0.2.0"
    build_module PockKit -I "$FW" -F "$FW" -framework SnapKit -framework AppKit \
        $(find "$DEPS/pockkit/PockKit" -name '*.swift')

    echo "==> 依赖就绪"
fi

# ---------------------------------------------------------------------------
# 编译组件
# ---------------------------------------------------------------------------
rm -rf "$POCK"
mkdir -p "$POCK/Contents/MacOS"

echo "==> 编译 $NAME"
swiftc -module-name "$NAME" -emit-library -Xlinker -bundle -swift-version 5 \
    -target "$TARGET" -module-cache-path "$CACHE" \
    -I "$FW" -F "$FW" -framework PockKit -framework AppKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -rpath -Xlinker @loader_path/Frameworks \
    -o "$POCK/Contents/MacOS/$NAME" \
    $(find "$ROOT/src" -name '*.swift')

cp "$ROOT/src/Info.plist" "$POCK/Contents/Info.plist"

# 必须签名，否则 Apple Silicon 拒绝加载
codesign --force --sign - "$POCK" 2>/dev/null

echo "==> 产出: $POCK"

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
if [ "$INSTALL" = "--install" ]; then
    mkdir -p "$WIDGETS_DIR"
    rm -rf "$WIDGETS_DIR/$NAME.pock"
    ditto "$POCK" "$WIDGETS_DIR/$NAME.pock"
    echo "==> 已安装到: $WIDGETS_DIR/$NAME.pock"
    echo "==> 重启 Pock 生效:  pkill -x Pock; open -a /Applications/Pock.app"
fi
