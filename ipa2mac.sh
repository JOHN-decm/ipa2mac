#!/bin/bash
# ipa2mac.sh — 把 iOS IPA 转成 Mac Catalyst 平台并 ad-hoc 签名，安装到 /Applications
# 不注入 PlayTools，窗口由系统原生处理。
#
# 用法:  ipa2mac.sh [选项] <文件.ipa>
#   --dest DIR     安装目录（默认 /Applications）
#   --no-launch    装完不自动启动
#   -h, --help     显示帮助

set -uo pipefail

DEST="/Applications"
LAUNCH=1
IPA=""

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)
      [ $# -ge 2 ] && [ -n "$2" ] || die "--dest 需要指定安装目录"
      DEST="$2"
      shift 2
      ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "未知选项: $1" ;;
    *) IPA="$1"; shift ;;
  esac
done

[ -n "$IPA" ] || die "请指定一个 .ipa 文件（ipa2mac.sh --help 查看用法）"
[ -f "$IPA" ] || die "找不到文件: $IPA"
[ "$(uname -m)" = "arm64" ] || die "只支持 Apple Silicon Mac"
for t in unzip otool vtool codesign lipo ditto file /usr/libexec/PlistBuddy; do
  command -v "$t" >/dev/null 2>&1 || die "缺少工具 $t（请先运行: xcode-select --install）"
done
[ -d "$DEST" ] || die "安装目录不存在: $DEST"

WORK=$(mktemp -d /tmp/ipa2mac.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. 解包 ----------
info "解包 $(basename "$IPA") ..."
unzip -q "$IPA" -d "$WORK/ex" || die "解压失败，文件可能不是有效的 IPA"
APPS=("$WORK"/ex/Payload/*.app)
[ -d "${APPS[0]}" ] || die "IPA 里没找到 Payload/*.app"
APP="${APPS[0]}"
PL="$APP/Info.plist"
BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PL" 2>/dev/null)
EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PL" 2>/dev/null)
NAME=$(basename "$APP" .app)
info "App: $NAME  ($BID)"

xattr -cr "$APP"
rm -rf "$APP/_CodeSignature" "$APP/embedded.mobileprovision" "$APP/SC_Info"

# 收集所有 Mach-O
MACHOS=()
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' && MACHOS+=("$f")
done < <(find "$APP" -type f -print0)
info "发现 ${#MACHOS[@]} 个 Mach-O 文件"

# ---------- 2. 检查加密 ----------
for b in "${MACHOS[@]}"; do
  if otool -l "$b" 2>/dev/null | grep -A4 LC_ENCRYPTION_INFO | grep -q 'cryptid [1-9]'; then
    die "${b#$APP/} 仍是 FairPlay 加密的，需要先砸壳的 IPA"
  fi
done
ok "未加密"

# ---------- 3. 转换平台为 Mac Catalyst ----------
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }  # $1 >= $2

info "转换为 Mac Catalyst 平台 ..."
for b in "${MACHOS[@]}"; do
  # 胖二进制只保留 arm64
  archs=$(lipo -archs "$b" 2>/dev/null)
  if [ "$archs" != "arm64" ]; then
    echo "$archs" | grep -qw arm64 || { warn "跳过非 arm64 文件: ${b#$APP/}"; continue; }
    lipo -thin arm64 "$b" -output "$b.thin" && mv "$b.thin" "$b"
  fi
  lc=$(otool -l "$b")
  plat=$(echo "$lc" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
  if [ -n "$plat" ] && [ "$plat" != "2" ] && [ "$plat" != "7" ]; then
    continue   # 已经不是 iOS 平台（比如已是 Catalyst），不动
  fi
  minos=$(echo "$lc" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS/{f=1} f&&/(minos|version) /{print $2; exit}')
  sdk=$(echo "$lc" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS/{f=1} f&&/sdk /{print $2; exit}')
  minos=${minos:-14.0}; sdk=${sdk:-$minos}
  ver_ge "$minos" "14.0" || minos=14.0
  ver_ge "$sdk" "$minos" || sdk=$minos
  codesign --remove-signature "$b" 2>/dev/null
  vtool -set-build-version maccatalyst "$minos" "$sdk" -replace -output "$b.new" "$b" >/dev/null 2>&1 \
    && mv "$b.new" "$b" || die "转换失败: ${b#$APP/}"
done
ok "平台转换完成"

# ---------- 4. 由内向外 ad-hoc 签名（不带 entitlements） ----------
info "签名 ..."
sign() { codesign -f -s - --timestamp=none "$1" >/dev/null 2>&1 || die "签名失败: ${1#$APP/}"; }

# 4a. 不属于 bundle 主程序的独立 Mach-O（dylib、辅助可执行文件等）
for b in "${MACHOS[@]}"; do
  case "$b" in
    *.framework/*|*.appex/*) dir=$(dirname "$b"); base=$(basename "$b")
      bn=$(basename "$dir"); [ "${bn%.*}" = "$base" ] && continue ;;  # bundle 主程序，跟 bundle 一起签
  esac
  [ "$b" = "$APP/$EXE" ] && continue
  sign "$b"
done
# 4b. 内嵌 bundle，路径深的先签
while IFS= read -r d; do sign "$d"; done < <(
  find "$APP" -mindepth 1 -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' -o -name '*.xpc' \) \
  | awk -F/ '{print NF"\t"$0}' | sort -rn | cut -f2-)
# 4c. 主 app
sign "$APP"
codesign --verify --deep --strict "$APP" 2>/dev/null || die "签名校验失败"
ok "签名完成"

# ---------- 5. 安装 ----------
TARGET="$DEST/$NAME.app"
pkill -9 -f "$TARGET/" 2>/dev/null && sleep 1
if [ -e "$TARGET" ]; then
  info "覆盖已安装的 $TARGET"
  rm -rf "$TARGET" || die "无法删除旧版本（权限不足？）"
fi
ditto "$APP" "$TARGET" || die "复制到 $DEST 失败（权限不足？）"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" 2>/dev/null
ok "已安装到 $TARGET"

# ---------- 6. 试启动 ----------
[ "$LAUNCH" = 1 ] || exit 0
info "试启动 ..."
START=$(date '+%Y-%m-%d %H:%M:%S')
open "$TARGET" 2>/dev/null
for _ in $(seq 1 8); do
  sleep 1
  pgrep -f "$TARGET/$EXE" >/dev/null && { ok "$NAME 已在运行 🎉"; exit 0; }
done
warn "$NAME 没有在运行，查找原因 ..."
/usr/bin/log show --start "$START" --style compact 2>/dev/null \
  | grep -F "$TARGET" | grep -iE 'not valid|amfi|denied|killed' | tail -3
CR=$(ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i "$EXE" | head -1)
[ -n "$CR" ] && echo "崩溃报告: ~/Library/Logs/DiagnosticReports/$CR"
exit 2
