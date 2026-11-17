#!/bin/bash
# 跑 AnnotateCore 單元測試（2026-11-13）
# Command Line Tools 沒有 XCTest，Swift Testing 要手動指定框架路徑
set -euo pipefail
cd "$(dirname "$0")"

# 結束時（成功或失敗）刪掉 .build 編譯暫存：約 600MB，不留在專案資料夾裡
# 代價：每次都是完整重新編譯（release 約 1 分鐘）
trap 'rm -rf "$PWD/.build"' EXIT

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --build-system native \
  -Xswiftc -F"$F" \
  -Xlinker -F"$F" \
  -Xlinker -rpath -Xlinker "$F" \
  "$@"
