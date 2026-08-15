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

> **This is a fork.** Talkify is [Tornike Gomareli's](https://github.com/tornikegomareli/Talkify)
> — a menu-bar dictation app for macOS that is genuinely lovely to use. This fork
> adds the personalization layer: it learns your words and your writing style, so
> what lands in the field is what you would have typed. Everything below the next
> section is upstream's, unchanged.

## What this fork adds

Free dictation gets the words down. Paid dictation gets *your* words down. That gap
is two features, and both of them are here.

**A vocabulary that sticks.** Product names, your teammates' names, the acronyms
only your team uses. Add them once in **Settings → Vocabulary** and the recognizer
stops mangling them. Terms are applied while the session is warming up, not on the
keypress, so they cost you nothing at the moment you are waiting to speak.

**Cleanup that sounds like you.** *"um so I was thinking we could uh ship it friday"*
lands as a sentence. Filler goes, punctuation arrives, and per-app style rules mean
Slack reads casual while email reads sharp. Runs on Apple's on-device model between
the recognizer finishing and the text being inserted — with a deadline, so a slow
pass inserts your raw text rather than making you wait.

**It learns from your edits.** When you fix something Talkify inserted, it notices.
Those corrections are distilled into short, readable style rules and vocabulary
suggestions that you approve or reject one by one — nothing is ever applied behind
your back. The raw text is dropped the moment it has been distilled.

**Diagnostics, so "nothing happened" has an answer.** Permission state and what the
last dictation actually did, in **Settings → Diagnostics**.

### Privacy, specifically

The additions keep upstream's rule: **no network requests, no audio stored, no
transcript history.** Cleanup uses Apple's on-device `FoundationModels` — nothing is
sent anywhere. The one exception is deliberate and bounded: to learn from your edits,
a capped buffer of at most 20 correction pairs is kept in
`~/Library/Application Support/Talkify/`. It is distilled into style rules and
cleared, and **Settings → Cleanup → Forget captured corrections** erases it and its
file immediately.

### Requirements for the additions

- Vocabulary and Diagnostics work on any Mac that runs Talkify.
- **Cleanup requires Apple Intelligence to be enabled** (System Settings → Apple
  Intelligence & Siri). Without it, cleanup reports itself unavailable in Settings
  and dictation inserts your raw text exactly as upstream does — nothing breaks, the
  feature is simply inert.

### Building this fork

`scripts/build-local-app.sh` builds and packages the app with only the Command Line
Tools, no 15 GB Xcode install — see [`docs/local-build.md`](docs/local-build.md).
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
