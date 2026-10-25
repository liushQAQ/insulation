#!/bin/bash
# 一键打包 insulation（充电限制 fork 版）
# 用法：在 Mac 上（已装 theos）执行  ./package-deb.sh
# 行为：版本自增 +1 → 分别打包 rootless / roothide → 产物归档到 dist/（历史不覆盖）
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
sed -i "s/^Version: .*/Version: $NEW_VER/" control
echo "=== 版本自增：$OLD_VER -> $NEW_VER ==="

# --- 两种 scheme 各打一次（对应上游 rootless_build.sh / roothide_build.sh）---
for scheme in rootless roothide; do
  echo "=== 打包 scheme=$scheme ==="
  make clean >/dev/null 2>&1 || true
  make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=$scheme
done

# --- 产物归档到 dist/，按 版本_scheme 命名，历史构建绝不覆盖 ---
mkdir -p dist
shopt -s nullglob
for deb in packages/*.deb; do
  name=$(basename "$deb" .deb)                       # com.be-huge.insulation_0.0.5_iphoneos-arm
  arch=$(echo "$name" | grep -oE 'iphoneos-arm[0-9a-z]*$' || echo "unknown")
  scheme_tag=$(echo "$name" | grep -oE '_(rootless|roothide)_' || true)
  out="dist/insulation_${NEW_VER}${scheme_tag:+_${scheme_tag}}_${arch}.deb"
  cp -n "$deb" "$out"                                # -n：已存在则跳过，不覆盖
  ls -lh "$out"
done
shopt -s nullglob

echo "=== 完成：dist/ 目录共 $(ls dist/*.deb 2>/dev/null | wc -l | tr -d ' ') 个历史产物 ==="
ls -lh dist/
