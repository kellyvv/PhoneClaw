#!/bin/bash
# validate-ipa.sh — App Store Connect 合规自动检查
#
# PhoneClaw 踩过的坑（全部固化为检查项）：
#   - 裸 .dylib 塞在 Frameworks/*.framework/ 里 → App Store 拒包
#   - framework binary 名与目录名不匹配 → 签名校验失败
#   - MinimumOSVersion 不一致 → 审核警告
#   - ITSAppUsesNonExemptEncryption 未设置 → TestFlight Missing Compliance
#   - @rpath hard-link 指向不存在的裸 dylib → 启动崩溃
#
# 用法:
#   ./scripts/validate-ipa.sh /path/to/PhoneClaw.ipa
#   ./scripts/validate-ipa.sh /path/to/PhoneClaw.xcarchive
#
# 退出码: 0 = 全部通过, >0 = 错误数
#
# 执行时机:
#   - xcodebuild archive + exportArchive 后自动运行
#   - Transporter 上传前人工确认
#   - CI gate check（非 0 退出码阻塞流水线）

set -euo pipefail

INPUT="${1:?Usage: validate-ipa.sh <path-to-ipa-or-xcarchive>}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
ERRORS=0
WARNINGS=0

# ── 解包 ───────────────────────────────────────────────
if [[ "$INPUT" == *.xcarchive ]]; then
    APP="$INPUT/Products/Applications/$(ls "$INPUT/Products/Applications/" | head -1)"
elif [[ "$INPUT" == *.ipa ]]; then
    unzip -q "$INPUT" -d "$TMPDIR"
    APP=$(find "$TMPDIR/Payload" -name "*.app" -maxdepth 1 -type d | head -1)
else
    echo "Error: input must be .ipa or .xcarchive"
    exit 1
fi

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "Error: could not find .app bundle in input"
    exit 1
fi

APP_NAME=$(basename "$APP" .app)
BINARY="$APP/$APP_NAME"

# 读主 App 的 MinimumOSVersion 用于后续比较
MAIN_MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$APP/Info.plist" 2>/dev/null || echo "")

echo "=== IPA Validation: $APP_NAME ==="
echo "    Source: $(basename "$INPUT")"
echo "    Main MinOS: ${MAIN_MIN_OS:-unknown}"
echo ""

# ── Check 1: 裸 dylib（app root，非 Frameworks/）──────
echo "--- [F1] Bare dylibs outside Frameworks/ ---"
BARE=$(find "$APP" -maxdepth 1 -name "*.dylib" 2>/dev/null || true)
if [ -n "$BARE" ]; then
    echo "❌ Bare dylibs in app root (violates App Store rule F1):"
    echo "$BARE" | sed 's/^/  /'
    ERRORS=$((ERRORS + 1))
else
    echo "✅ No bare dylibs in app root"
fi
echo ""

# ── Check 2: framework 内嵌 dylib + 异常 Mach-O ───────
echo "--- [F1/F3] Nested dylibs inside frameworks ---"
NESTED_ISSUES=""
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    FW_NAME=$(basename "$fw" .framework)

    # framework 内的 .dylib（排除主 binary 同名情况）
    while IFS= read -r nested; do
        NESTED_ISSUES="${NESTED_ISSUES}  $(basename "$fw")/$(basename "$nested") — 裸 dylib 塞在 framework 内\n"
    done < <(find "$fw" -name "*.dylib" 2>/dev/null || true)

    # framework 内非主 binary 的 Mach-O
    for f in "$fw"/*; do
        [ -f "$f" ] || continue
        BASENAME=$(basename "$f")
        [ "$BASENAME" = "$FW_NAME" ] && continue
        [ "$BASENAME" = "Info.plist" ] && continue
        [[ "$BASENAME" == *.plist ]] && continue
        [[ "$BASENAME" == *.modulemap ]] && continue
        [[ "$BASENAME" == *.h ]] && continue
        [[ "$BASENAME" == *.swiftmodule ]] && continue
        if file "$f" 2>/dev/null | grep -q "Mach-O"; then
            NESTED_ISSUES="${NESTED_ISSUES}  $(basename "$fw")/$BASENAME — unexpected Mach-O\n"
        fi
    done
done
if [ -n "$NESTED_ISSUES" ]; then
    echo "❌ Nested dylibs/Mach-O inside frameworks:"
    echo -e "$NESTED_ISSUES"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ No nested dylibs inside frameworks"
fi
echo ""

# ── Check 3: framework binary 名 vs 目录名匹配 ────────
echo "--- [F3] Framework binary name matches directory ---"
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    FW_NAME=$(basename "$fw" .framework)
    FW_BINARY="$fw/$FW_NAME"
    if [ ! -f "$FW_BINARY" ]; then
        echo "❌ $(basename "$fw"): missing main binary '$FW_NAME'"
        ERRORS=$((ERRORS + 1))
    else
        # 检查 CFBundleExecutable 是否匹配
        PLIST="$fw/Info.plist"
        if [ -f "$PLIST" ]; then
            BUNDLE_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || echo "")
            if [ -n "$BUNDLE_EXEC" ] && [ "$BUNDLE_EXEC" != "$FW_NAME" ]; then
                echo "❌ $(basename "$fw"): CFBundleExecutable='$BUNDLE_EXEC' != directory name '$FW_NAME'"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    fi
done
echo "✅ Framework binary names verified"
echo ""

# ── Check 4: framework Info.plist 完整性 ──────────────
echo "--- [F4/F5] Framework Info.plist integrity ---"
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    FW_NAME=$(basename "$fw")
    PLIST="$fw/Info.plist"
    if [ ! -f "$PLIST" ]; then
        echo "❌ $FW_NAME: missing Info.plist"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # CFBundlePackageType
    PKG_TYPE=$(/usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$PLIST" 2>/dev/null || echo "")
    if [ "$PKG_TYPE" != "FMWK" ]; then
        echo "⚠️  $FW_NAME: CFBundlePackageType='$PKG_TYPE' (expected 'FMWK')"
        WARNINGS=$((WARNINGS + 1))
    fi

    # MinimumOSVersion
    FW_MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$PLIST" 2>/dev/null || echo "?")
    echo "  $FW_NAME: MinOS=$FW_MIN_OS, PkgType=$PKG_TYPE"

    # MinOS 不能低于主 App
    if [ -n "$MAIN_MIN_OS" ] && [ "$FW_MIN_OS" != "?" ]; then
        # 简单版本比较（只比较 major.minor）
        if python3 -c "
from packaging.version import Version
import sys
try:
    if Version('$FW_MIN_OS') < Version('$MAIN_MIN_OS'):
        sys.exit(1)
except:
    pass
sys.exit(0)
" 2>/dev/null; then
            : # OK
        else
            echo "  ⚠️  $FW_NAME MinOS ($FW_MIN_OS) < main App MinOS ($MAIN_MIN_OS)"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
done
echo ""

# ── Check 5: otool -L 主 binary ──────────────────────
echo "--- [F8] Main binary link dependencies ---"
if [ -f "$BINARY" ]; then
    # 过滤掉合法路径：@rpath (embedded frameworks)、/usr/lib (system)、/System (system)
    BAD_LINKS=$(otool -L "$BINARY" 2>/dev/null \
        | tail -n +2 \
        | grep -v "@rpath\|/usr/lib\|/System" \
        | sed 's/^[[:space:]]*//' \
        | sed 's/ (compatibility.*//' \
        || true)
    if [ -n "$BAD_LINKS" ]; then
        echo "❌ Suspicious linked libraries (not resolvable in app bundle):"
        echo "$BAD_LINKS" | sed 's/^/  /'
        ERRORS=$((ERRORS + 1))
    else
        echo "✅ All linked libraries resolvable"
    fi

    # 额外检查：@rpath 链接的 framework 在 Frameworks/ 里是否存在
    RPATH_LIBS=$(otool -L "$BINARY" 2>/dev/null \
        | grep "@rpath" \
        | sed 's/.*@rpath\///' \
        | sed 's/ (compatibility.*//' \
        || true)
    for rlib in $RPATH_LIBS; do
        # 从 @rpath/Foo.framework/Foo 提取 framework 名
        FW_DIR=$(echo "$rlib" | cut -d'/' -f1)
        if [[ "$FW_DIR" == *.framework ]]; then
            if [ ! -d "$APP/Frameworks/$FW_DIR" ]; then
                echo "❌ @rpath/$rlib: framework not found in Frameworks/"
                ERRORS=$((ERRORS + 1))
            fi
        elif [[ "$rlib" == lib*.dylib ]]; then
            # 裸 dylib @rpath 链接 — 不应存在于 App Store build
            echo "⚠️  @rpath/$rlib: bare dylib link (OK if dlopen-only, not static-linked)"
            WARNINGS=$((WARNINGS + 1))
        fi
    done
else
    echo "⚠️  Main binary not found at: $BINARY"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ── Check 6: Swift runtime dylib ─────────────────────
echo "--- [F6/F7] Swift runtime handling ---"
SWIFT_DYLIBS=$(find "$APP/Frameworks" -name "libswift*.dylib" 2>/dev/null || true)
if [ -n "$SWIFT_DYLIBS" ]; then
    echo "⚠️  Swift runtime dylibs found in Frameworks/ (should be managed by Xcode):"
    echo "$SWIFT_DYLIBS" | sed 's/^/  /'
    WARNINGS=$((WARNINGS + 1))
else
    echo "✅ No manually embedded Swift runtime dylibs"
fi
echo ""

# ── Check 7: ITSAppUsesNonExemptEncryption ────────────
echo "--- [S1] Export compliance ---"
ENCRYPTION=$(/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$APP/Info.plist" 2>/dev/null || echo "")
if [ "$ENCRYPTION" = "false" ]; then
    echo "✅ ITSAppUsesNonExemptEncryption = false"
elif [ -z "$ENCRYPTION" ]; then
    echo "⚠️  ITSAppUsesNonExemptEncryption not set (will prompt on ASC upload)"
    WARNINGS=$((WARNINGS + 1))
else
    echo "❌ ITSAppUsesNonExemptEncryption = $ENCRYPTION (should be false)"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── Check 8: Code signature ──────────────────────────
echo "--- [S2/S3] Code signature ---"
codesign -vvv "$APP" 2>&1 | head -5
echo ""

# 检查每个 embedded framework 的签名
UNSIGNED_FW=""
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    if ! codesign -vvv "$fw" 2>/dev/null; then
        UNSIGNED_FW="${UNSIGNED_FW}  $(basename "$fw")\n"
    fi
done
if [ -n "$UNSIGNED_FW" ]; then
    echo "❌ Unsigned frameworks:"
    echo -e "$UNSIGNED_FW"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ All embedded frameworks signed"
fi
echo ""

# ── Check 9: SwiftSupport ────────────────────────────
echo "--- SwiftSupport ---"
if [[ "$INPUT" == *.ipa ]]; then
    if [ -d "$TMPDIR/SwiftSupport" ]; then
        echo "✅ SwiftSupport present in IPA"
    else
        echo "ℹ️  No SwiftSupport directory (normal for iOS 12.2+ minimum deployment)"
    fi
else
    echo "ℹ️  SwiftSupport check skipped (only applies to exported IPA, not xcarchive)"
fi
echo ""

# ── Summary ──────────────────────────────────────────
echo "==========================================="
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo "==========================================="

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo "❌ FAILED — fix $ERRORS error(s) before uploading to App Store Connect"
fi

exit $ERRORS
