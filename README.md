# Dictant

Dictant is a tiny (<1 MB) macOS menu bar push-to-talk app that turns your voice into polished text with OpenAI Whisper and optional ChatGPT cleanup.

Free and open-source—there are no paywalls, you only cover your own OpenAI API usage.

## Why Dictant
- Built for speed: hold the right Command key or tap the menu bar icon to start/stop recording in a second.
- Clipboard automation: copy and optionally paste the result straight into the active app.
- Reliable status cues: menu bar icon blinks red while recording and green while processing.
- Smart post-processing: optional ChatGPT pass with your own system prompt for better output.
- Persistent history: recordings and transcripts live locally so you can retry failed jobs.
- macOS-first: Swift, native notifications, Keychain storage, launch-at-login toggle, and accessibility-safe prompts.

## Core Features
- **Push-to-talk**: Hold the right Command key for 1 second to start recording; release to stop (configurable).
- **Menu bar workflow**: Left-click to toggle recording, right-click for quick actions (start/stop, settings, history, quit).
- **Clipboard & paste**: Copy transcripts to the clipboard; optionally auto-paste into the active text field (requires Accessibility).
- **ChatGPT post-processing**: Run transcripts through GPT with your custom system prompt.
- **History & retries**: Browse recordings, re-run failed/pending transcriptions, copy or open files in Finder, and clear history.
- **Launch at login**: Keep Dictant running in the background after reboot.
- **Smart Silence Removal**: Automatically trims long pauses and silence from your audio before processing to improve transcription accuracy and reduce API usage.
- **Notifications**: Get alerts for missing/invalid API keys, permission issues, success, and failures.
- **Privacy-aware**: API key stays in Keychain, audio files stay local (Application Support), only the transcription request hits OpenAI.

## Requirements
- macOS 14.0+ (built with Xcode 15+)
- An OpenAI API key with Whisper access (create one at https://platform.openai.com/account/api-keys)
- Internet access for transcription and optional ChatGPT post-processing

## Install from Source
1. Clone this repo and open `Dictant.xcodeproj` in Xcode.
2. Select your signing team if needed.
3. Build and run the `Dictant` target.
4. Grant microphone access when prompted.

## Build a DMG
Use the bundled helper script plus `create-dmg` for a polished installer.

1. Install the utility: `brew install create-dmg`.
2. Build a universal Release app bundle (Xcode or `xcodebuild -scheme Dictant -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`).
3. Package it: `./packaging/create_dmg.sh` (override paths with `./packaging/create_dmg.sh /path/to/Dictant.app CustomName.dmg`).
4. For a one-shot build + DMG from the terminal: `./packaging/build_and_dmg.sh` (override with env vars like `DERIVED_DATA=build/DerivedData DMG_NAME=Custom.dmg ARCHS="arm64 x86_64"`).

The script renders a gradient background on the fly, applies the app icon to the volume, lays out the app and Applications link, and writes the DMG to `build/Dictant.dmg`.

## Quick Start
1. Launch the app; it lives in the menu bar.
2. Open `Settings → Processing`, paste your OpenAI API key, and save it (stored in Keychain).
3. Optional tweaks in `Settings → General`:
   - Run at system startup
   - Copy to clipboard / paste into the active input
   - Enable push-to-talk (hold right Command)
4. Press and hold the right Command key for 1s to start talking, then release to stop. Or click the menu bar icon to toggle.
5. Check notifications or `Settings → History` for transcripts; copy, re-run, or open recordings from there.

## Usage Notes
- **Menu bar icon states**: solid icon (idle), blinking red (recording), blinking green (processing).
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
