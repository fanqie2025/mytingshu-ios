#!/usr/bin/env bash
# 在 macOS 上把 Sources/*.swift 编译成「未签名 .ipa」（巨魔 TrollStore 可直接安装）
# 本地 Mac 用法:  bash build_ipa.sh
# 云端用法:      GitHub Actions macos runner（见 .github/workflows/ios.yml）
set -euo pipefail
cd "$(dirname "$0")"

APP=MyTingShu
BUILD=build

rm -rf "$BUILD"
mkdir -p "$BUILD/Payload/$APP.app"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "==> iOS SDK: $SDK"
xcodebuild -version || true

echo "==> 编译 Swift（$(ls Sources/*.swift | wc -l | tr -d ' ') 个文件）"
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios15.0 \
  -swift-version 5 \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -framework SwiftUI -framework AVFoundation -framework MediaPlayer \
  -framework WebKit -framework CryptoKit \
  Sources/*.swift \
  -o "$BUILD/Payload/$APP.app/$APP"

echo "==> 组装 .app"
cp Resources/Info.plist "$BUILD/Payload/$APP.app/"
cp Resources/*.png "$BUILD/Payload/$APP.app/" 2>/dev/null || true
# 注意：App 不内置任何书源（空壳）。书源一律在 App 内「设置 → 导入书源」用订阅地址/粘贴 JSON 导入。
echo "APPL????" > "$BUILD/Payload/$APP.app/PkgInfo"
chmod +x "$BUILD/Payload/$APP.app/$APP"

# 伪签名：TrollStore 能装未签名 ipa，ldid 只是为了兼容性更稳
if command -v ldid >/dev/null 2>&1; then
  echo "==> ldid 伪签名"
  ldid -S "$BUILD/Payload/$APP.app/$APP"
else
  echo "==> 没有 ldid，保持未签名（TrollStore 仍可安装）"
fi

echo "==> 打包 ipa"
cd "$BUILD"
zip -qry "$APP.ipa" Payload
cd ..
echo "✅ 产物: $(pwd)/$BUILD/$APP.ipa"
ls -lh "$BUILD/$APP.ipa"
