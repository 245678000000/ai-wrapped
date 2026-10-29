#!/bin/zsh
# Builds "AI 年度报告.app" into ./dist (release build, app icon, ad-hoc signed).
#   ./build-app.sh            this Mac's architecture
#   UNIVERSAL=1 ./build-app.sh  Apple silicon + Intel
#   ./build-app.sh --dmg      also packs dist/AI-Wrapped-<version>-mac.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.4.0"
APP_NAME="AI 年度报告"
APP="dist/$APP_NAME.app"

if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  # Build each slice separately and merge; `--arch a --arch b` would need Xcode's xcbuild.
  SLICES=()
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx15.0" --scratch-path ".build/$arch"
    SLICES+=("$(swift build -c release --triple "$arch-apple-macosx15.0" --scratch-path ".build/$arch" --show-bin-path)/AIWrapped")
  done
  BIN=".build/AIWrapped-universal"
  lipo -create "${SLICES[@]}" -output "$BIN"
else
  swift build -c release
  BIN=".build/release/AIWrapped"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIWrapped"

# App icon, rendered by the app itself.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --icon "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  [[ $size -ne 512 ]] && sips -z $double $double "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AIWrapped</string>
  <key>CFBundleIdentifier</key><string>local.aiwrapped</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/AIWrapped"))"

if [[ "${1:-}" == "--dmg" ]]; then
  DMG="dist/AI-Wrapped-$VERSION-mac.dmg"
  STAGE="$(mktemp -d)/stage"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/打不开？看这里.txt" <<'TXT'
把「AI 年度报告」拖进「应用程序」文件夹即可。

这个应用没有经过 Apple 公证，第一次打开时系统可能提示“无法验证开发者”或“已损坏”。
任选一种方式放行：

1. 打开「系统设置 → 隐私与安全性」，在页面底部找到这个应用，点「仍要打开」。
2. 或者在「终端」里运行下面这一行，再双击打开：
   xattr -dr com.apple.quarantine "/Applications/AI 年度报告.app"

所有数据只在本机读取（~/.claude、~/.codex 等目录），不会上传任何内容。
TXT
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
  echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
fi
