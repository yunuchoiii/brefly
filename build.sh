#!/bin/bash
# Brefly 빌드 스크립트 — Xcode 프로젝트 없이 swiftc로 .app 번들을 만든다.
#
#   ./build.sh                            빌드만 (build/Brefly.app)
#   ./build.sh --install                  /Applications 에 설치하고 실행
#   ./build.sh --install --reset-perms    설치 전에 낡은 권한 기록을 지운다
#
# 서명 인증서는 자동으로 찾는다:
#   "Brefly Dev" 인증서가 있으면 그걸 쓰고 (재빌드해도 권한 유지)
#   없으면 애드혹 서명으로 떨어진다 (재빌드마다 권한 재설정 필요)
#   → ./setup-signing.sh 를 한 번 실행해 두면 이 문제가 사라진다
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/Brefly.app"
DEST="/Applications/Brefly.app"
BUNDLE_ID="com.brefly.dictation"
CERT_NAME="Brefly Dev"
OLD_CERT_NAME="Sokgi Dev"   # 이름 바꾸기 전에 만든 인증서도 그대로 쓴다

INSTALL=0
RESET_PERMS=0
for arg in "$@"; do
  case "$arg" in
    --install)     INSTALL=1 ;;
    --reset-perms) RESET_PERMS=1 ;;
  esac
done

# --- 사전 확인 -------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ swiftc가 없습니다. 먼저 Xcode 명령줄 도구를 설치하세요:"
  echo "   xcode-select --install"
  exit 1
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
echo "▶ 빌드 대상: $TARGET"

# --- 서명 신원 결정 --------------------------------------------------------
# 우선순위: SOKKI_SIGN_ID 지정 > Developer ID Application(배포·공증) > 로컬 고정 인증서 > 애드혹
# Developer ID 는 하드닝 런타임 + entitlements + 타임스탬프로 서명해야 공증이 통과한다.
# 로컬 개발 중에 Developer ID 를 건너뛰려면 SOKKI_LOCAL_SIGN=1.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
DISTRIBUTION=0
if [[ -n "${SOKKI_SIGN_ID:-}" ]]; then
  SIGN_ID="$SOKKI_SIGN_ID"
  STABLE=1
elif [[ -n "$DEV_ID" && "${SOKKI_LOCAL_SIGN:-0}" != "1" ]]; then
  SIGN_ID="$DEV_ID"
  STABLE=1
  DISTRIBUTION=1
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  SIGN_ID="$CERT_NAME"
  STABLE=1
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$OLD_CERT_NAME"; then
  SIGN_ID="$OLD_CERT_NAME"
  STABLE=1
else
  SIGN_ID="-"
  STABLE=0
fi

# --- 번들 구조 -------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 한국어를 쓰는 앱이라고 선언한다. 우리 UI 는 문구가 코드에 한국어로 박혀 있어 번역 파일이
# 필요 없지만, .lproj 가 하나도 없으면 macOS 는 이 앱을 영어 앱으로 보고 프로세스 언어를
# 영어로 고정한다. 그러면 Sparkle 이 ko.lproj 를 가지고 있어도 업데이트 창이 영어로 뜬다.
# 빈 ko.lproj 만 있으면 된다 — 내용은 필요 없다.
mkdir -p "$APP/Contents/Resources/ko.lproj"

# --- Sparkle 프레임워크 ----------------------------------------------------
# 앱 스스로 업데이트를 받아 교체하려면 Sparkle 이 번들 안에 들어가야 한다.
# cp -R 로 심볼릭 링크를 그대로 옮긴다(rsync -L 같은 건 링크를 풀어 서명이 깨진다).
echo "▶ Sparkle 프레임워크 넣는 중…"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$DIR/vendor/Sparkle.framework" "$APP/Contents/Frameworks/"

# --- 컴파일 ---------------------------------------------------------------
echo "▶ 컴파일 중…"
swiftc \
  -O \
  -swift-version 5 \
  -target "$TARGET" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework Speech \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework ApplicationServices \
  -framework Security \
  -framework ServiceManagement \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -F "$DIR/vendor" -framework Sparkle \
  -Xcc -I"$DIR/vendor/whisper/include" \
  -import-objc-header "$DIR/vendor/whisper/bridge.h" \
  -L"$DIR/vendor/whisper/lib" \
  -lwhisper -lparakeet -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas \
  -lc++ \
  -framework Metal \
  -framework MetalKit \
  -framework Accelerate \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Brefly" \
  "$DIR/Sources/"*.swift

# --- 앱 아이콘 -------------------------------------------------------------
# 로고를 코드로 그리므로 별도 이미지 파일 없이 바이너리가 iconset 을 만들고 iconutil 로 묶는다.
echo "▶ 앱 아이콘 생성 중…"
ICONSET="$DIR/build/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Brefly" --render-icon "$ICONSET" 2>/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# --- 서명 -----------------------------------------------------------------
# ⚠️ 중첩 번들은 **안쪽부터** 따로 서명해야 한다. 앱만 서명하면 안쪽 서명이 없거나
# 낡은 채로 남아 공증이 거부된다. Sparkle 이 배포하는 프레임워크는 서명이 안 되어 있어
# (TeamIdentifier not set) 우리 인증서로 전부 다시 서명한다.
# --deep 은 Apple 이 권하지 않는다. 순서를 직접 정해 하나씩 서명한다.
sign_sparkle() {
  local fw="$APP/Contents/Frameworks/Sparkle.framework"
  local opts=("--force" "--sign" "$SIGN_ID")
  [[ $DISTRIBUTION -eq 1 ]] && opts+=("--options" "runtime" "--timestamp")
  for item in \
    "$fw/Versions/B/XPCServices/Downloader.xpc" \
    "$fw/Versions/B/XPCServices/Installer.xpc" \
    "$fw/Versions/B/Updater.app" \
    "$fw/Versions/B/Autoupdate" \
    "$fw/Versions/B"
  do
    codesign "${opts[@]}" "$item"
  done
}
sign_sparkle

if [[ $DISTRIBUTION -eq 1 ]]; then
  echo "▶ Developer ID 로 서명 중… (하드닝 런타임 · 공증 가능)"
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" \
    --options runtime --timestamp \
    --entitlements "$DIR/Brefly.entitlements" "$APP"
  codesign --verify --deep --strict --verbose=1 "$APP"
elif [[ $STABLE -eq 1 ]]; then
  echo "▶ '$SIGN_ID' 인증서로 서명 중… (권한 유지됨)"
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
  echo "▶ 애드혹 서명 중… (재빌드하면 접근성 권한이 풀립니다)"
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
fi

# --- 낡은 권한 기록 정리 ---------------------------------------------------
# tccutil reset은 이 앱 하나의 권한 기록만 지운다. 다른 앱은 건드리지 않는다.
if [[ $RESET_PERMS -eq 1 ]]; then
  echo "▶ Brefly의 기존 권한 기록 삭제 중…"
  tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset SpeechRecognition "$BUNDLE_ID" 2>/dev/null || true
  echo "   → 앱을 실행하면 권한을 새로 물어봅니다."
fi

# --- 설치 -----------------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
  echo "▶ /Applications 에 설치 중…"
  pkill -x Brefly 2>/dev/null || true
  pkill -x Sokgi 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST" /Applications/Sokgi.app
  cp -R "$APP" "$DEST"
  FINAL="$DEST"
  echo "✅ 설치 완료: $DEST"
  open "$DEST"
else
  FINAL="$APP"
  echo "✅ 빌드 완료: $APP"
fi

echo ""
if [[ $STABLE -eq 0 ]]; then
  cat <<EOF
⚠️  애드혹 서명으로 빌드했습니다.
    재빌드할 때마다 앱의 신원이 바뀌어서, 손쉬운 사용에 체크가 켜져 있어도
    실제로는 권한이 거부됩니다. 한 번만 아래를 실행하면 영구히 해결됩니다:

      ./setup-signing.sh
      ./build.sh --install --reset-perms

EOF
fi

cat <<EOF
── 실행과 권한 ────────────────────────────────────────────
실행:      open "$FINAL"
로그:      tail -f ~/Library/Logs/Brefly.log

터미널에서 Contents/MacOS/Brefly 를 직접 실행하지 마세요.
권한 주체가 터미널이 되어 붙여넣기가 동작하지 않습니다.

권한이 꼬였을 때:   ./build.sh --install --reset-perms
───────────────────────────────────────────────────────────
EOF
