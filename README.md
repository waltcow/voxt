# Voxt

Hold a global hotkey, speak, and the transcribed text is automatically pasted into whatever app you're using.


https://github.com/user-attachments/assets/8fde004a-e07a-45fc-ae3c-8f8a216873d3


## How it works

1. **Hold** `Option + Command` -- recording starts and a floating waveform overlay appears at the bottom of your screen
2. **Speak** -- your audio is captured and transcribed
3. **Release** -- transcribed text is pasted into the focused app (your clipboard is preserved and restored)

The app lives entirely in the menu bar with no Dock icon. The only UI during use is a minimal floating pill showing audio levels and live transcription.

## Features

- **MLX Audio speech engine** -- on-device speech-to-text using MLX Audio models (Qwen3-ASR, Parakeet, GLM-ASR)
- **Optional Apple Dictation fallback** -- zero-setup speech recognition via `SFSpeechRecognizer`
- **Apple Intelligence enhancement** -- optionally post-process transcriptions with on-device Foundation Models to fix grammar, punctuation, and formatting (macOS 26.0+)
- **Global push-to-talk hotkey** -- works from any app without switching focus
- **Animated waveform overlay** -- floating non-activating panel with real-time audio level bars and scrolling transcription text
- **Clipboard-safe** -- saves and restores your clipboard contents around each paste

## Tech stack

- **SwiftUI** + **AppKit** -- SwiftUI for the settings and overlay views, AppKit for the menu bar, floating panel, clipboard, and simulated key events
- **MLX Audio Swift** -- local on-device MLX speech-to-text models with Hugging Face cache management
- **Speech framework** -- `SFSpeechRecognizer` for real-time streaming dictation
- **Foundation Models** -- Apple Intelligence on-device LLM for text enhancement
- **CGEvent** -- global hotkey detection via a low-level event tap
- **Combine** -- reactive state bridging between transcription engines and the UI

## Requirements

- macOS 26.0+
- Xcode 26+
- Accessibility permission (for global hotkey)
- Microphone permission

## Building

Open `Voxt.xcodeproj` in Xcode and build. MLX Audio Swift is resolved automatically via Swift Package Manager.

## License

MIT
