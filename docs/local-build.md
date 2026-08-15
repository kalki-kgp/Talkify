# Building Talkify without Xcode

`scripts/build-local-app.sh` builds and packages `Talkify.app` using only the
Command Line Tools (`xcode-select --install`). It exists so someone running a
fork can use their own build day to day without a 15 GB Xcode install.

It is a convenience for local use. **Xcode remains the build of record** —
`Talkify.xcodeproj` is the project, and anything this script cannot do is called
out below rather than worked around.

```sh
./scripts/build-local-app.sh            # build dist/Talkify.app
./scripts/build-local-app.sh --test     # run the suite first, then build
./scripts/build-local-app.sh --tests-only
./scripts/build-local-app.sh --benchmark-cleanup
```

`--benchmark-cleanup` times Text Cleanup over drafts of four lengths, in both
pacing modes. Cleanup runs between the recognizer finishing and the text
landing, so those numbers are delay the person feels — they are what the
Settings deadline default should be chosen from. It needs Apple Intelligence
turned on; without it, cleanup correctly returns the draft untouched in
microseconds and the run says so instead of printing a meaningless table.

## How it works

SwiftPM ships with the Command Line Tools, so the Swift half needs nothing else:
the script generates a `Package.swift` in `.localbuild/`, compiles every file
under `Talkify/` into one executable, and assembles the bundle around it by hand.

Sources are staged into `.localbuild/` first, never edited in place. The only
rewrite is dropping `#Preview` blocks: the Command Line Tools ship the
Observation and Testing macro plugins but not `PreviewsMacros`, so previews are
the one construct that cannot be expanded outside Xcode. They are Canvas-only
code, so nothing in the built app changes.

`FoundationModelsMacros` is absent for the same reason, so `@Generable` and
`@Guide` cannot be used in code that has to build here. `Talkify/Cleanup/` works
around that rather than through it: plain-string responses where a string will
do, and `DynamicGenerationSchema` — a runtime API needing no macro — where the
answer has to be structured.

## What is copied from an installed Talkify

Three build products come from `actool` and `metal`, which only Xcode has:

| Product | What it is | Without it |
| --- | --- | --- |
| `Assets.car` | compiled asset catalog | no menu bar icon, no Siri orb artwork |
| `default.metallib` | compiled Metal shaders | no waveform sheen, edge glow or ripple; Particle Cloud draws nothing |
| `AppIcon.icns` | compiled app icon | generic icon |

The script copies all three out of an already-installed `Talkify.app`
(`/Applications/Talkify.app`, or `TALKIFY_REFERENCE_APP`). None of them is built
from Swift, so as long as `Talkify/HUD/Shaders/` and `Talkify/Assets.xcassets/`
are unchanged, the copy is byte-for-byte what Xcode would have produced. Change
either one and the script says so — it compares against the last commit that
touched them — but it cannot rebuild them. That needs Xcode.

For what it's worth, a missing `default.metallib` is not fatal: SwiftUI treats an
unresolved `ShaderLibrary` function as a no-op effect, and `HUDParticleCloudView`
already fails soft by design.

## Running the tests

`swift test` builds an `.xctest` bundle, which needs Xcode's `xctest` host to
run. Instead the script compiles the app sources and `TalkifyTests/` into a
single executable around swift-testing's own entry point, which needs no host.
Three details follow from that:

- The tests and the app are one module, so `@testable import Talkify` is dropped
  on the way into the staging tree.
- `Testing.framework` is passed explicitly with `-F`, and its Foundation
  cross-import overlay is disabled — the Command Line Tools ship
  `_Testing_Foundation`'s dylib without its `.swiftmodule`.
- `UpdatesTests` and `TalkifyTests` read the repository from `#filePath` and the
  app's identity from `Bundle.main`, so the staging tree keeps the repository's
  shape and the `Info.plist` is linked into the test binary as a
  `__TEXT,__info_plist` section.

All 109 tests run and pass this way.

## Signing and permissions

The bundle is signed with a local certificate if one exists, and ad-hoc
otherwise. Neither needs an Apple Developer account. Two consequences:

- **Run `scripts/create-signing-identity.sh` once.** Talkify needs Accessibility
  and Input Monitoring, and macOS keys those grants to the app's designated
  requirement. An ad-hoc signature has none, so the grant falls back to the code
  hash — which changes on every build. The symptom is nasty rather than obvious:
  Talkify keeps its row in the permission list with the checkbox on, while
  `AXIsProcessTrusted()` returns false and the dictation key does nothing. Every
  build leaves another dead row behind. The script creates a certificate that
  stays put, so the requirement becomes `identifier "com.tgomareli.Talkify" and
  certificate leaf = H"…"` and the grant survives rebuilds.

  After creating it, remove any Talkify rows already in Accessibility and Input
  Monitoring with "−" before re-adding — a row from an ad-hoc build looks
  granted and is not. `tccutil reset Accessibility com.tgomareli.Talkify` and
  `tccutil reset ListenEvent com.tgomareli.Talkify` clear them all at once.

  `TALKIFY_SIGN_IDENTITY` overrides which identity is used, and `-` forces
  ad-hoc back.
- Sparkle's update checks are turned off in the built `Info.plist`. A local build
  is ahead of the appcast, and an "update" would replace it with an upstream
  release.

## Knobs

| Variable | Default |
| --- | --- |
| `TALKIFY_REFERENCE_APP` | `/Applications/Talkify.app` |
| `TALKIFY_VERSION` | `0.3.3-local` |
| `TALKIFY_BUILD` | `120` |
| `TALKIFY_BUNDLE_ID` | `com.tgomareli.Talkify` |
| `TALKIFY_CONFIGURATION` | `release` |
| `TALKIFY_SIGN_IDENTITY` | `-` (ad-hoc) |
