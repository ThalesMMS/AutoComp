# AutoComp

AutoComp is a macOS 14+ menu bar autocomplete app for Apple Silicon Macs. It watches the active accessible text field, requests a short completion from a configured remote OpenAI-compatible endpoint, displays it inline or in a mirror window, and lets the user accept text with Tab.

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
- Emoji suggestions after `:`.
- Privacy controls with collection off by default.
- Encrypted local personalization storage with Keychain-managed keys and delete-all support.

## Remote model integration

The app always uses the remote OpenAI-compatible backend configured in Settings > Model. For local development, `.env.local` can provide initial defaults:

- `AUTOCOMP_REMOTE_BASE_URL`
- `AUTOCOMP_REMOTE_API_KEY`
- `AUTOCOMP_REMOTE_MODEL`

Current development defaults point at `http://127.0.0.1:8000` with `Qwen/Qwen3.6-35B-A3B`. Autocomplete text is sent to the configured endpoint.
