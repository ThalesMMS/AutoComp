# AutoComp

AutoComp is a macOS 14+ menu bar autocomplete app for Apple Silicon Macs. It watches the active accessible text field, requests a short completion from a configured completion backend, displays it inline or in a mirror window, and lets the user accept text with Tab.

## Run

```sh
./script/build_and_run.sh --verify
```

The script builds the SwiftPM package, stages `dist/AutoComp.app`, launches it as a macOS app bundle, and verifies the process is running. The Codex app Run button is wired to the same script through `.codex/environments/environment.toml`.

## Current MVP

- Menu bar app with onboarding and settings windows.
- Accessibility permission gate and optional Screen Recording permission.
- Accessibility-based focused text capture with password/unsupported-field exclusion.
- Inline overlay and mirror-window suggestion modes.
- Tab accepts the next suggestion word; the backtick key (`` ` ``) accepts the full suggestion.
- Compatibility catalog for browsers, writing apps, terminals, code editors, and unsupported apps.
- Google Docs setup detection and Sheets/Slides unsupported handling.
- Remote OpenAI-compatible completion backend configurable from Settings > Model.
- Apple Intelligence completion backend support when FoundationModels is available on the current macOS release.
- Local in-process llama.cpp runtime support when an app build links the optional runtime and a GGUF model file is configured.
- Emoji suggestions after `:`.
- Privacy controls with collection off by default.
- Encrypted local personalization storage with Keychain-managed keys and delete-all support.

## Completion backends

The app defaults to the remote OpenAI-compatible backend configured in Settings > Model. For local development, `.env.local` can provide initial defaults:

- `AUTOCOMP_REMOTE_BASE_URL`
- `AUTOCOMP_REMOTE_API_KEY`
- `AUTOCOMP_REMOTE_MODEL`
- `AUTOCOMP_LOCAL_MODEL_PATH`
- `AUTOCOMP_LOCAL_MAX_RAM_BYTES`

Current development defaults point at `http://127.0.0.1:8000` with `Qwen/Qwen3.6-35B-A3B`.

Backend modes:

- Remote OpenAI-compatible sends autocomplete text to the configured endpoint.
- Apple Intelligence uses FoundationModels only when the framework is available and the OS supports it; otherwise the app reports the backend as unavailable and can use remote fallback when enabled.
- Local in-process is available only in app builds that link the optional llama.cpp runtime and have a configured GGUF model file. The package builds the optional runtime and harness targets when Homebrew llama.cpp headers/libraries are present. Settings > Model shows the local runtime state, model path, load state, last local error, memory limit, and remote fallback state.

AutoComp's baseline is macOS 14+. Apple Intelligence remains conditional and may require a newer macOS release such as macOS 26. Local in-process completion is also conditional; the app should not be treated as local-capable unless Settings reports both runtime and model file availability.
