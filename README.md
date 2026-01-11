# Dictant - native Mac OS wrapper for OpenAI Whisper

Dictant is a tiny (<1 MB) macOS menu bar push-to-talk app that turns your voice into polished text with OpenAI Whisper and optional ChatGPT cleanup.

Free and open-source — there are no paywalls, you only cover your own OpenAI API usage.

**[Download the latest version from the Releases page](https://github.com/sbrin/Dictant/releases)**

## Why Dictant
- *Built for speed*: hold the right Command key or tap the menu bar icon to start/stop recording in a second.
- *Clipboard automation*: copy and optionally paste the result straight into the active app.
- *Reliable status cues*: menu bar icon blinks red while recording and green while processing.
- *Smart post-processing*: optional ChatGPT pass with your own system prompt for better output.
- *Persistent history*: recordings and transcripts live locally so you can retry failed jobs.
- *macOS-first*: SwiftUI, native notifications, Keychain storage

## Core Features
- **Push-to-talk**: Hold the right ⌘ (Command key) for 1 second to start recording; release to stop
- **Clipboard & paste**: Copy transcripts to the clipboard; auto-paste into the active text field (requires Accessibility).
- **ChatGPT post-processing**: Run transcripts through GPT with your custom system prompt.
- **History & retries**: Browse recordings, re-run failed/pending transcriptions, copy or open files in Finder, and clear history.
- **Smart Silence Removal**: Automatically trims long pauses and silence from your audio before processing to improve transcription accuracy and reduce API usage.
- **Privacy-aware**: API key stays in Keychain, audio files stay local (Application Support), only the transcription request hits OpenAI.

## Quick Start
1. Launch the app; it lives in the menu bar.
2. Open `Settings → Processing`, paste your OpenAI API key, and save it (stored in Keychain).
3. Press and hold the right Command key for 1s to start talking, then release to stop. Or click the menu bar icon to toggle.
4. Optional tweaks in `Settings → General`:
   - Run at system startup
   - Enable push-to-talk
   - Copy to clipboard
   - Paste into the active input
5. Check `Settings → History` for transcripts; copy, re-run, or open recordings from there.

## Requirements
- macOS 14.0+ (built with Xcode 15+)
- An OpenAI API key with Whisper access (create one at https://platform.openai.com/account/api-keys)
- Internet access for transcription and optional ChatGPT post-processing

## Install from Source
1. Clone this repo and open `Dictant.xcodeproj` in Xcode.
2. Select your signing team if needed.
3. Build and run the `Dictant` target.
4. Grant microphone access when prompted.

## Build a PKG
Use the bundled helper scripts to create a standard macOS installer package.
** PKG Installer requires extra privacy and security permission via System Settings **

Build and package in one shot: `./packaging/build_and_pkg.sh`


## Usage Notes
- **Menu bar and pointer states**: solid icon (idle), blinking red (recording), blinking green (processing).
- **Status menu (right-click)**: start/stop, cancel processing, open settings, open history, quit.
- **Auto-paste**: Requires Accessibility permission; if missing, the app will prompt and temporarily disable paste until trusted.
- **ChatGPT prompt**: Set your own system prompt to shape the post-processed text (defaults to a polishing prompt).

## Permissions
- **Microphone**: Required to record audio.
- **Accessibility**: Needed for auto-paste and the global push-to-talk hotkey.
- **Notifications**: Used for success/failure and permission guidance.

## Troubleshooting
- **Invalid or missing API key**: Add a valid key in `Settings → Processing`; the app surfaces notifications when the key is rejected.
- **Cannot start recording**: Ensure microphone permission is granted in System Settings → Privacy & Security → Microphone.
- **Auto-paste disabled**: Enable Accessibility access for Dictant in System Settings → Privacy & Security → Accessibility.
- **Short recordings discarded**: Clips under a few seconds (or entirely silent/too quiet) are dropped automatically.
- **Retries**: Use `Settings → History` to re-run failed or pending transcriptions.

## Contributing
- Open issues for bugs and feature ideas; PRs are welcome.
- Please describe repro steps and expected behavior when filing bugs.

## License

Dictant is released under the MIT License (c) 2026 mikhail l ilin. See `LICENSE` for details. You are responsible for any OpenAI API charges and must follow OpenAI’s terms of service.
