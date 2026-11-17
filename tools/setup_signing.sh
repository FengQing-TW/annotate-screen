#!/bin/bash
# 建立本機自簽的程式碼簽章憑證「AnnotateScreen Local Signing」（2026-11-13）
#
# 為什麼：ad-hoc 簽章的 designated requirement 是 cdhash，每次建置都變，
#        系統的「螢幕與系統錄音」權限綁舊 cdhash，於是一直判定沒權限。
#        改用固定憑證簽章後，requirement 變成「bundle id＋憑證」，重新建置也不會失效。
# 範圍：只匯入「登入」鑰匙圈，只給這台 Mac 用；不需要信任設定。
# 移除：鑰匙圈存取 →「登入」→ 我的憑證 → 刪除「AnnotateScreen Local Signing」
#      或 security delete-identity -c "AnnotateScreen Local Signing"
set -euo pipefail

NAME="AnnotateScreen Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "已存在：${NAME}，不重建"
    exit 0
fi

WORK="$(mktemp -d)"
# 私鑰暫存檔用完即刪（成功或失敗都刪）
trap 'rm -f "$WORK"/key.pem "$WORK"/cert.pem "$WORK"/id.p12 "$WORK"/openssl.cnf; rmdir "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# 用系統內建的 LibreSSL（Homebrew 的 OpenSSL 3 匯出的 p12 格式 security 可能讀不了）
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS"

# -T：允許 codesign 使用這把私鑰（減少「codesign 想要取用鑰匙」的詢問）
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
echo "已建立：$NAME"
