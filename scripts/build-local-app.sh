#!/usr/bin/env bash
# Build Talkify.app with the Command Line Tools alone — no Xcode.
#
# SwiftPM (which ships with the CLT) compiles every Swift file in Talkify/ into
# the app binary, and the bundle is assembled by hand. Three build products in a
# normal Xcode build have no CLT equivalent, because `actool` and `metal` come
# only with Xcode:
#
#   Assets.car        compiled asset catalog  (menu bar icon, Siri artwork)
#   default.metallib  compiled Metal shaders  (waveform sheen, edge glow, ripple)
#   AppIcon.icns      compiled app icon
#
# All three are copied from an already-installed Talkify.app. None of them is
# built from anything this branch changes, so a copy is the same file Xcode
# would have produced. Edit a .metal file or the asset catalog and this script
# will say so rather than silently ship the stale one.
#
# Nothing here modifies the repository sources: the Swift files are staged into
# .localbuild/ first, with #Preview blocks removed (the previews macro is the
# one macro plugin the CLT does not ship).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/.localbuild"
DIST="$ROOT/dist"
APP="$DIST/Talkify.app"
CONTENTS="$APP/Contents"

REFERENCE_APP="${TALKIFY_REFERENCE_APP:-/Applications/Talkify.app}"
VERSION="${TALKIFY_VERSION:-0.6.1-local}"
BUILD_NUMBER="${TALKIFY_BUILD:-141}"
BUNDLE_ID="${TALKIFY_BUNDLE_ID:-com.tgomareli.Talkify}"
CONFIGURATION="${TALKIFY_CONFIGURATION:-release}"
# Prefer a stable local identity over ad-hoc signing. macOS keys an
# Accessibility grant to the code hash when an app is signed ad-hoc, and that
# hash changes on every build — so the app reappears in the permission list
# looking granted while AXIsProcessTrusted() says no, and the dictation key
# goes dead after every rebuild. A signing identity gives the app a stable
# designated requirement, and the grant survives.
#
# Create one with scripts/create-signing-identity.sh; without it this falls
# back to ad-hoc and everything still builds.
LOCAL_SIGN_IDENTITY="Talkify Local Signing"
if [[ -z "${TALKIFY_SIGN_IDENTITY:-}" ]] \
  && security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_SIGN_IDENTITY"; then
  SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
else
  SIGN_IDENTITY="${TALKIFY_SIGN_IDENTITY:--}"
fi

RUN_TESTS=0
RUN_BENCHMARK=0
for argument in "$@"; do
  case "$argument" in
    --test) RUN_TESTS=1 ;;
    --tests-only) RUN_TESTS=2 ;;
    --benchmark-cleanup) RUN_BENCHMARK=1 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==>\033[0m %s\n' "$1" >&2; }

# The keys Xcode would generate from build settings (docs/ProjectSettings.md),
# plus the Sparkle keys, which live in Talkify/Info.plist because Xcode's
# INFOPLIST_KEY_ passthrough drops keys it does not know.
write_info_plist() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Talkify</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Talkify</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Talkify uses the microphone to transcribe your speech on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Talkify converts your speech into text on this Mac.</string>
</dict>
</plist>
PLIST
  /usr/libexec/PlistBuddy -c "Merge $ROOT/Talkify/Info.plist" "$1" >/dev/null
  plutil -lint "$1" >/dev/null
}

if ! command -v swift >/dev/null; then
  echo "swift not found — install the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

# ---------------------------------------------------------------- staging ----

log "Staging sources into ${STAGE#$ROOT/}"
mkdir -p "$STAGE"
rm -rf "$STAGE/Sources" "$STAGE/Repo" "$STAGE/Bench"
python3 "$ROOT/scripts/local-build/stage-sources.py" "$ROOT/Talkify" "$STAGE/Sources/Talkify" >&2

# SwiftPM builds a test target into an .xctest bundle, which needs Xcode's
# `xctest` host to run — the Command Line Tools have no such tool. The suite is
# built as an ordinary executable instead: the app sources and the tests compile
# into one module (so `@testable import Talkify` is neither needed nor possible),
# around the same swift-testing entry point SwiftPM's own runner calls.
python3 "$ROOT/scripts/local-build/stage-sources.py" \
  "$ROOT/TalkifyTests" "$STAGE/Repo/TalkifyTests" --drop-testable-import Talkify >&2
python3 "$ROOT/scripts/local-build/stage-sources.py" \
  "$ROOT/Talkify" "$STAGE/Repo/TalkifyTests/App" --strip-main >&2

# UpdatesTests walks two directories up from #filePath to reach the repository
# root, so the staged suite keeps that shape and puts the sources it reads back
# alongside it. They sit outside the target's path, so nothing compiles them
# twice. Talkify/ is copied rather than symlinked because FileManager's
# enumerator returns nothing for a symlinked root, and copied verbatim — the
# point of that test is what the committed sources import.
rsync -a --include='*/' --include='*.swift' --exclude='*' \
  "$ROOT/Talkify/" "$STAGE/Repo/Talkify/"
ln -sfn "$ROOT/appcast.xml" "$STAGE/Repo/appcast.xml"

# UpdatesTests and TalkifyTests read Bundle.main for the app's identity and
# Sparkle's keys. A bare executable has no bundle, but the Info.plist can be
# linked into the binary as a __TEXT,__info_plist section, which Bundle.main
# reads the same way.
write_info_plist "$STAGE/Repo/TestHost-Info.plist"

# Text Cleanup adds a model pass between the recognizer finishing and the text
# landing, which is exactly the window the insertion latency benchmark measures.
# The benchmark target is the app's own sources plus a main that times
# CleanupService.clean over drafts of several lengths.
if (( RUN_BENCHMARK )); then
  python3 "$ROOT/scripts/local-build/stage-sources.py" \
    "$ROOT/Talkify" "$STAGE/Bench/App" --strip-main >&2
  cp "$ROOT/scripts/local-build/CleanupBenchmark.swift" "$STAGE/Bench/main.swift"
fi

cat > "$STAGE/Repo/TalkifyTests/LocalTestRunner.swift" <<'RUNNER'
import Testing

@main
struct LocalTestRunner {
  static func main() async {
    await Testing.__swiftPMEntryPoint() as Never
  }
}
RUNNER

# swift-testing ships with the Command Line Tools, but under a directory layout
# SwiftPM only searches when it is running inside Xcode. Point the test target
# at it explicitly so `swift test` can run the committed suite.
TESTING_FRAMEWORKS="$(dirname "$(find "$(xcode-select -p)" -maxdepth 6 -name Testing.framework -type d 2>/dev/null | head -1)")"
if [[ ! -d "$TESTING_FRAMEWORKS" ]]; then
  echo "Testing.framework not found under $(xcode-select -p)" >&2
  exit 1
fi

BENCHMARK_TARGET=""
if (( RUN_BENCHMARK )); then
  BENCHMARK_TARGET='    .executableTarget(
      name: "CleanupBenchmark",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      path: "Bench",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),'
fi

cat > "$STAGE/Package.swift" <<PACKAGE
// swift-tools-version: 6.0
// Generated by scripts/build-local-app.sh. Edit that script, not this file.
import PackageDescription

let package = Package(
  name: "Talkify",
  platforms: [.macOS("26.0")],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.8.0")
  ],
  targets: [
    .executableTarget(
      name: "Talkify",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      path: "Sources/Talkify",
      swiftSettings: [.swiftLanguageMode(.v6)],
      // The hand-assembled bundle keeps Sparkle.framework in Contents/Frameworks.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
    ),
    .executableTarget(
      name: "TalkifyTests",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      path: "Repo/TalkifyTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        // Testing.framework declares a Foundation cross-import overlay, but the
        // Command Line Tools ship _Testing_Foundation's dylib without its
        // .swiftmodule, so importing Testing alongside Foundation cannot
        // resolve it. Nothing in the suite uses the overlay.
        .unsafeFlags(["-F", "$TESTING_FRAMEWORKS", "-Xfrontend", "-disable-cross-import-overlays"])
      ],
      linkerSettings: [
        .unsafeFlags([
          "-F", "$TESTING_FRAMEWORKS",
          "-Xlinker", "-rpath", "-Xlinker", "$TESTING_FRAMEWORKS",
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "$STAGE/Repo/TestHost-Info.plist"
        ])
      ]
    ),
$BENCHMARK_TARGET
  ]
)
PACKAGE

# ------------------------------------------------------------------ tests ----

if [[ $RUN_TESTS -gt 0 ]]; then
  log "Running the test suite"
  ( cd "$STAGE" && swift build -c debug --product TalkifyTests )
  "$STAGE/.build/debug/TalkifyTests"
  [[ $RUN_TESTS -eq 2 ]] && exit 0
fi

# ------------------------------------------------------------------ build ----

if (( RUN_BENCHMARK )); then
  log "Benchmarking Text Cleanup"
  ( cd "$STAGE" && swift build -c release --product CleanupBenchmark )
  "$STAGE/.build/release/CleanupBenchmark"
  exit 0
fi

log "Building Talkify ($CONFIGURATION)"
( cd "$STAGE" && swift build -c "$CONFIGURATION" --product Talkify )

BINARY="$STAGE/.build/$CONFIGURATION/Talkify"
[[ -f "$BINARY" ]] || { echo "no binary at $BINARY" >&2; exit 1; }

# -------------------------------------------------- borrowed build products ---

if [[ ! -d "$REFERENCE_APP" ]]; then
  cat >&2 <<MISSING
No reference app at $REFERENCE_APP.

Assets.car, default.metallib and AppIcon.icns need either Xcode or a built copy
of Talkify to come from. Install a release from
https://github.com/tornikegomareli/Talkify/releases and run this again, or point
TALKIFY_REFERENCE_APP at a copy you already have.
MISSING
  exit 1
fi

REFERENCE_RESOURCES="$REFERENCE_APP/Contents/Resources"
for product in Assets.car default.metallib AppIcon.icns; do
  [[ -f "$REFERENCE_RESOURCES/$product" ]] || {
    echo "$REFERENCE_APP has no $product" >&2
    exit 1
  }
done

# A borrowed product is only correct while its sources are untouched. Compare
# against the last commit that touched them rather than the files' modification
# dates, which a checkout restamps to now.
warn_if_stale() {
  local product="$1" source_path="$2" committed_at product_at
  committed_at="$(git -C "$ROOT" log -1 --format=%ct -- "$source_path" 2>/dev/null || true)"
  product_at="$(stat -f %m "$REFERENCE_RESOURCES/$product")"
  local dirty
  dirty="$(git -C "$ROOT" status --porcelain -- "$source_path" 2>/dev/null || true)"

  if [[ -n "$dirty" ]]; then
    printf '\033[1;33mwarning:\033[0m %s is uncommitted, so the %s copied from %s cannot include it.\n' \
      "${source_path#$ROOT/}" "$product" "${REFERENCE_APP##*/}" >&2
  elif [[ -n "$committed_at" && "$committed_at" -gt "$product_at" ]]; then
    printf '\033[1;33mwarning:\033[0m %s changed after %s was built; this build ships the old one.\n' \
      "${source_path#$ROOT/}" "$product" >&2
  fi
}
warn_if_stale default.metallib "$ROOT/Talkify/HUD/Shaders"
warn_if_stale Assets.car "$ROOT/Talkify/Assets.xcassets"

# --------------------------------------------------------------- assembly ----

log "Assembling ${APP#$ROOT/}"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp "$BINARY" "$CONTENTS/MacOS/Talkify"
cp "$REFERENCE_RESOURCES/Assets.car" "$REFERENCE_RESOURCES/default.metallib" \
   "$REFERENCE_RESOURCES/AppIcon.icns" "$CONTENTS/Resources/"
# Pop is CC-BY-NC (see LICENSE-SOUNDS.txt). A release build already hides it
# from the picker, but hiding it is not the same as not distributing it, so it
# never enters the bundle. Debug builds keep it — nothing is redistributed.
SOUND_EXCLUDE='LICENSE-SOUNDS.txt'
[[ "$CONFIGURATION" == "release" ]] && SOUND_EXCLUDE="$SOUND_EXCLUDE|^Pop"
find "$ROOT/Talkify/Resources/Sounds" -maxdepth 1 -type f -print0 \
  | while IFS= read -r -d '' sound; do
      [[ "$(basename "$sound")" =~ $SOUND_EXCLUDE ]] || cp "$sound" "$CONTENTS/Resources/"
    done
printf 'APPL????' > "$CONTENTS/PkgInfo"

SPARKLE_FRAMEWORK="$(find "$STAGE/.build/artifacts" -type d -name Sparkle.framework -path '*macos*' | head -1)"
[[ -n "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework not found in the SwiftPM artifacts" >&2; exit 1; }
cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/"

write_info_plist "$CONTENTS/Info.plist"

# Turn the update checks off: this build is ahead of the appcast, and letting
# Sparkle "update" it would replace it with an upstream release that has no
# Vocabulary.
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" \
                        -c "Set :SUAllowsAutomaticUpdates false" \
                        "$CONTENTS/Info.plist" >/dev/null

# ---------------------------------------------------------------- signing ----

log "Signing (identity: $SIGN_IDENTITY)"
codesign --force --deep --sign "$SIGN_IDENTITY" "$CONTENTS/Frameworks/Sparkle.framework" 2>&1 | sed 's/^/    /' >&2
codesign --force --sign "$SIGN_IDENTITY" \
         --entitlements "$ROOT/Talkify.entitlements" "$APP" 2>&1 | sed 's/^/    /' >&2
codesign --verify --strict "$APP" >&2

log "Built $APP"
printf '%s\n' "$APP"
