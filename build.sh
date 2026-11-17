#!/bin/bash
# 建置 AnnotateScreen.app 並 ad-hoc 簽章（2026-11-13）
# 注意：這台機器 swift build 預設建置系統會失敗，一律加 --build-system native
set -euo pipefail
cd "$(dirname "$0")"

# 結束時（成功或失敗）刪掉 .build 編譯暫存：約 600MB，不留在專案資料夾裡
# 代價：每次都是完整重新編譯（release 約 1 分鐘）
trap 'rm -rf "$PWD/.build"' EXIT

swift build -c release --build-system native
BIN_DIR="$(swift build -c release --build-system native --show-bin-path)"

APP="build/AnnotateScreen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AnnotateScreen" "$APP/Contents/MacOS/AnnotateScreen"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon：由 tools/make_icon.swift 畫出 1024 原圖，再縮成各尺寸包成 .icns（不把二進位檔放進 git）
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir "$ICONSET"
swift tools/make_icon.swift "$ICON_TMP/icon_1024.png" >/dev/null
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -r "$ICONSET" "$ICON_TMP/icon_1024.png"
rmdir "$ICON_TMP"

# 用固定的本機憑證簽章（tools/setup_signing.sh 建立），重新建置後「螢幕與系統錄音」權限不會失效；
# 沒有憑證時退回 ad-hoc（每次建置都要重開權限）
SIGN_ID="AnnotateScreen Local Signing"
if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    codesign --force --deep -s "$SIGN_ID" "$APP"
else
    echo "警告：找不到憑證「${SIGN_ID}」，改用 ad-hoc 簽章；先執行 tools/setup_signing.sh 可避免每次重開權限" >&2
    codesign --force --deep -s - "$APP"
fi
echo "完成：$APP"

# 安裝到「應用程式」（2026-11-13 使用者裁示）；INSTALL_DIR 可改目的地（測試用）
# 注意：每次建置簽章都會變，「螢幕與系統錄音」權限要重新打開
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/AnnotateScreen.app"
WAS_RUNNING=0
if pgrep -f "$DEST/Contents/MacOS/AnnotateScreen" >/dev/null; then
    WAS_RUNNING=1
    # 執行中的程式不能就地覆蓋（簽章頁面會失效），先結束
    # 以路徑比對只結束這一份（用 App 名稱 quit 會連其他位置的同名 App 一起關掉）
    pkill -TERM -f "$DEST/Contents/MacOS/AnnotateScreen" || true
    for _ in $(seq 1 50); do
        pgrep -f "$DEST/Contents/MacOS/AnnotateScreen" >/dev/null || break
        sleep 0.1
    done
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
echo "已安裝：$DEST"
if [ "$WAS_RUNNING" = 1 ]; then
    open "$DEST"
    echo "已重新啟動"
fi
