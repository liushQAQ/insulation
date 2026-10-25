#!/bin/bash
# 一键打包 insulation（充电限制 fork 版）
# 用法：./package-deb.sh（macOS + theos，或 GitHub Actions 内）
# 行为：版本自增 +1 → 按 theos 实际支持的 scheme 打包（rootless；旧 theos 另有 roothide）
# → 产物归档到 dist/（历史不覆盖）
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${THEOS:-}" ] && [ ! -d "/opt/theos" ] && [ ! -d "$HOME/theos" ]; then
  echo "错误：未找到 theos（THEOS 环境变量 / /opt/theos / ~/theos）。请先安装 theos。"
  exit 1
fi

# --- 版本自增（patch +1），保留 control 里的旧版本号可追溯 ---
OLD_VER=$(grep '^Version:' control | awk '{print $2}')
if ! echo "$OLD_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "错误：control Version 不是 x.y.z 格式：$OLD_VER"
  exit 1
fi
BASE=${OLD_VER%.*}
PATCH=${OLD_VER##*.}
NEW_VER="$BASE.$((PATCH + 1))"
# -i.bak 同时兼容 GNU sed 与 macOS BSD sed
sed -i.bak "s/^Version: .*/Version: $NEW_VER/" control && rm -f control.bak
echo "=== 版本自增：$OLD_VER -> $NEW_VER ==="

mkdir -p dist
# --- scheme 各打一次；打完立即归档，防止下一次 make clean 覆盖 ---
# 说明：theos 新版 master 只保留 rootless 模块（vendor/mod/roothide 已移除），
# 因此循环里做存在性探测，旧 theos 有 roothide 时才打，没有则跳过不报错。
THEOS_DIR="${THEOS:-}"
if [ -z "$THEOS_DIR" ]; then
  if [ -d "/opt/theos" ]; then THEOS_DIR="/opt/theos"; else THEOS_DIR="$HOME/theos"; fi
fi
for scheme in rootless roothide; do
  if [ ! -d "$THEOS_DIR/vendor/mod/$scheme" ]; then
    echo "=== 跳过 scheme=${scheme}（当前 theos 无此 scheme 模块）==="
    continue
  fi
  echo "=== 打包 scheme=$scheme ==="
  make clean >/dev/null 2>&1 || true
  make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=$scheme
  shopt -s nullglob
  for deb in packages/*.deb; do
    base=$(basename "$deb" .deb)                 # com.be-huge.insulation_0.0.5_iphoneos-arm
    arch=${base##*_}                             # iphoneos-arm（rootless 产 arm64/arm64e 双切片）
    out="dist/insulation_${NEW_VER}_${scheme}_${arch}.deb"
    cp -n "$deb" "$out"                          # -n：已存在则跳过，不覆盖
    ls -lh "$out"
  done
  shopt -u nullglob
done

echo "=== 完成：dist/ 目录共 $(ls dist/*.deb 2>/dev/null | wc -l | tr -d ' ') 个产物 ==="
ls -lh dist/
