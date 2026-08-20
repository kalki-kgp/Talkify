<p align="center">
  <img src="docs/assets/app-icon.png" width="96" alt="Talkify icon" />
  <h1 align="center">Talkify</h1>
</p>

<h3 align="center">Beautiful and fastest way to do voice dictation on macOS</h3>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" />
  <img src="https://img.shields.io/badge/macOS-26+-blue.svg" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-lightgrey.svg" />
  <img src="https://github.com/tornikegomareli/Talkify/actions/workflows/ci.yml/badge.svg" />
</p>

> **This is a fork.** Talkify is [Tornike Gomareli's](https://github.com/tornikegomareli/Talkify),
> a menu-bar dictation app for macOS. This fork adds the personalization layer, so
> what lands in the field is closer to what you would have typed. Everything below
> the next section is upstream's, unchanged.

## What this fork adds

Free dictation gets the words down. Paid dictation gets *your* words down. That gap
is two features, and both are here.

**A vocabulary that sticks.** Product names, your teammates' names, the acronyms
only your team uses. Add them once in **Settings → Vocabulary** and the recognizer
stops mangling them. Terms load while the session warms up rather than on the
keypress, so they cost nothing at the moment you are waiting to speak.

**Cleanup that sounds like you.** *"um so I was thinking we could uh ship it friday"*
lands as a sentence. Filler goes, punctuation arrives, and per-app rules let Slack
read casual while email reads sharp. It runs on Apple's on-device model between the
recognizer finishing and the text being inserted. There is a deadline on it, so a
slow pass inserts your raw text instead of making you wait.

**It learns from your edits.** Fix something Talkify inserted and it notices. Those
corrections become short style rules and vocabulary suggestions that you approve or
reject one at a time. Nothing is applied behind your back, and the raw text is
dropped once it has been distilled.

**Diagnostics, so "nothing happened" has an answer.** Permission state and what the
last dictation actually did, in **Settings → Diagnostics**.

### Privacy, specifically

The additions keep upstream's rule: no network requests, no audio stored, no
transcript history. Cleanup uses Apple's on-device `FoundationModels`, so nothing is
sent anywhere. One exception is deliberate and bounded. To learn from your edits, a
buffer of at most 20 correction pairs is kept in
`~/Library/Application Support/Talkify/`. It is distilled into style rules and then
cleared, and **Settings → Cleanup → Forget captured corrections** erases it and its
file immediately.

### Requirements for the additions

- Vocabulary and Diagnostics work on any Mac that runs Talkify.
- **Cleanup requires Apple Intelligence to be enabled** (System Settings → Apple
  Intelligence & Siri). Without it, cleanup reports itself unavailable in Settings
  and dictation inserts your raw text exactly as upstream does. Nothing breaks. The
  feature is just inert.

### Installing this fork

Download [**Talkify-personalization.dmg**](https://github.com/kalki-kgp/Talkify/releases/latest),
open it, and drag Talkify to Applications.

**macOS will refuse to open it the first time.** You will see *"Apple could not
verify Talkify is free of malware."* That warning is accurate. Read it before you
click past it.

This build is signed with a self-signed certificate and is not notarized. I do not
have a paid Apple Developer ID, so Apple has never scanned this binary. macOS
cannot tell you it is safe, because nobody has checked. To open it anyway:

1. **System Settings → Privacy & Security**
2. Scroll to the message about Talkify being blocked, and click **Open Anyway**

Talkify then asks for **Accessibility**. That one permission lets an application
watch your keystrokes and read text fields in other apps. Talkify needs it to see
its trigger key and to put text where your cursor is. It makes no network requests
at all, but you are taking my word for that, from a binary nobody has scanned.

**If that trade sounds bad, it should.** Build it yourself instead. It takes one
command, and then the app on your machine is one you compiled from source you can
read:

```bash
git clone https://github.com/kalki-kgp/Talkify.git
cd Talkify
./scripts/create-signing-identity.sh   # once
./scripts/build-local-app.sh
cp -R dist/Talkify.app /Applications/
```

A notarized build will replace this the moment I have a Developer ID.

### Building this fork

`scripts/build-local-app.sh` builds and packages the app with only the Command Line
Tools, no 15 GB Xcode install. See [`docs/local-build.md`](docs/local-build.md).
Run `scripts/create-signing-identity.sh` once first, or macOS will quietly drop your
Accessibility grant on every rebuild.

---

## Showcase


<p align="center">
  <img src="docs/assets/showreel.gif" width="90%" alt="Talkify's six voice visuals playing together: Edge Glow in Sunset, Aurora, Spectrum and Ocean, Compact captions, and the Siri-style waveform" />
</p>

<p align="center">
  <img src="docs/assets/settings-appearance.jpg" width="45%" alt="Settings — Appearance, with a live HUD preview" />
  <img src="docs/assets/settings-insights.jpg" width="45%" alt="Settings — Insights, computed and stored locally" />
</p>

## Privacy

Everything is on-device: Apple's `SpeechAnalyzer`/`SpeechTranscriber` for recognition, `AVSpeechSynthesizer` for Read Aloud. Talkify makes no network requests, stores no audio, and keeps no history beyond the local usage metrics you can see in Insights.

## Requirements

- macOS 26 (Tahoe) on Apple Silicon

## Install

With Homebrew:

```bash
brew tap tornikegomareli/talkify https://github.com/tornikegomareli/Talkify
brew trust --tap tornikegomareli/talkify
brew install --cask talkify
```

Homebrew 6 refuses to load anything from a third-party tap until you trust it (Talkify will be verified cask after 100 stars),
so the middle line is required. It is asking whether you trust this repository;
[read the cask](Casks/talkify.rb) first if you would rather check what it does.

Or grab [**Talkify.dmg**](https://github.com/tornikegomareli/Talkify/releases/latest/download/Talkify.dmg) from the latest release.

Build from source:

```bash
git clone https://github.com/tornikegomareli/Talkify.git
cd Talkify
open Talkify.xcodeproj   # ⌘R
```

Or headless:

```bash
xcodebuild -project Talkify.xcodeproj -scheme Talkify -configuration Debug build
```

Run the tests the same way CI does:

```bash
xcodebuild test -project Talkify.xcodeproj -scheme Talkify -destination 'platform=macOS'
```

## Using it

| Action | Gesture |
|---|---|
| Dictate | Hold **fn**, speak, release |
| Hands-free session | Quick-tap **fn**, speak, tap again to finish |
| Dictate in your second language | Hold **right ⌥** instead |
| Cancel mid-session | **Esc** |
| Read selected text aloud | **⌥ ⎋** (toggles; also in the menu) |
| Everything else | Menu bar ghost → Settings |

The trigger and the Read Aloud shortcut are rebindable in **Settings → Shortcuts**

## Two languages, two keys

Pick a second language in **Settings → Language** and it gets its own key. Hold
**fn** for English, hold **right ⌥** for German, with no setting to change in
between. Both keys are rebindable, and either can be the one you use most.

Apple Speech transcribes one language per session and offers no way to detect
which language you are speaking, so Talkify does not guess. Guessing would mean
transcribing first and inferring the language from the result, and in the wrong
language that result is fluent nonsense rather than an error. A key per language
is instant and never wrong.

Both languages stay loaded, so the second answers as fast as the first, and the
notch shows a small tag naming the one that is listening. macOS ships 30
locales across German, English, Spanish, French, Italian, Japanese, Korean,
Portuguese, Cantonese and Chinese; a language you have not used before downloads
its model once, with progress shown in Settings and in the notch.

## Architecture

Code is organized into folders, callbacks only flow one way from the main wiring point, and a pure reducer handles the state.

- `App/` — composition root, settings store, status item
- `Input/` — the global key event tap and recorded bindings
- `Dictation/` — the session machine (`DictationSessionMachine`, a pure tested reducer) and the speech/insertion services
- `HUD/` — geometry seams, the shell, the voice visuals, and all Metal shaders
- `ReadAloud/`, `Settings/`, `Insights/`

`CONTEXT.md` is the domain doc, decisions live in `docs/adr/`

## Roadmap

- **Live Captions & Meeting Transcripts** — ephemeral captions from a selected app's audio (Chrome, YouTube, meeting apps), and the saved, timestamped transcript as a separate action. The domain design already lives in `CONTEXT.md`; the recognition pipeline is ready for non-microphone audio.
- **Text cleanup** — optional on-device polishing of dictated text (fillers, punctuation) once the raw-insertion core is benchmarked. Version 1 deliberately inserts exactly what you said. *(Built in this fork — see [What this fork adds](#what-this-fork-adds).)*
- **Snippets** — saved text blocks inserted by a spoken trigger word: say your trigger mid-dictation and the whole block lands instead.

## License
[MIT](LICENSE)
