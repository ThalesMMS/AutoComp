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
- Privacy controls with optional collection off by default, source-specific limits, and browser domain collection rules.
- Encrypted local personalization storage with Keychain-managed keys and local privacy delete-all support.

## Completion backends

The app defaults to the remote OpenAI-compatible backend configured in Settings > Model. For local development, `.env.local` can provide initial defaults:

- `AUTOCOMP_REMOTE_BASE_URL`
- `AUTOCOMP_REMOTE_API_KEY`
- `AUTOCOMP_REMOTE_MODEL`
- `AUTOCOMP_LOCAL_MODEL_PATH`
- `AUTOCOMP_LOCAL_MAX_RAM_BYTES`

Current development defaults point at `http://100.98.1.45:8000` with `default`.

Backend modes:

- Remote OpenAI-compatible sends autocomplete text to the configured endpoint.
- Apple Intelligence uses FoundationModels only when the framework is available and the OS supports it; otherwise the app reports the backend as unavailable. Remote fallback is opt-in. Settings > Model shows Apple availability, OS/SDK requirement text, fallback state, and the last Apple error.
- Local in-process is available only in app builds that link the optional llama.cpp runtime and have a configured GGUF model file. The default package build does not link that runtime. Set `AUTOCOMP_ENABLE_LLAMA_RUNTIME=1` to build it through `pkg-config llama`, or set both `AUTOCOMP_LLAMA_CFLAGS` and `AUTOCOMP_LLAMA_LIBS` to provide explicit compiler and linker flags. Remote fallback is opt-in. Settings > Model shows the local runtime state, model path, load state, last local error, memory limit, remote fallback state, and a diagnostics report that checks the GGUF file, runtime dylibs, architecture compatibility, and estimated memory fit.

AutoComp's baseline is macOS 14+. Apple Intelligence remains conditional and may require a newer macOS release such as macOS 26. Local in-process completion is also conditional; the app should not be treated as local-capable unless Settings reports both runtime and model file availability.

Settings > Model shows the selected engine, request destination, `Data leaves this Mac`, whether `Remote fallback` is enabled, the last backend used for a completion, and the last Local Llama, Apple, or remote error. Settings > Privacy repeats the active backend privacy summary, and the Model Playground labels the destination before revealing the sensitive prompt preview. Enabling `Remote fallback` displays an inline warning because autocomplete text may be sent to the configured Remote OpenAI-compatible endpoint after a Local Llama or Apple Intelligence failure.

Backend/model behavior is tracked in `Docs/ModelCompatibilityMatrix.md`. Settings > Model uses that matrix to avoid recommending FIM optimized behavior, multi-completion behavior, or latency expectations until a row has publishable non-content evidence.

To validate a local-runtime build environment before enabling it, run:

```sh
./script/check_llama_pkg_config.sh
AUTOCOMP_ENABLE_LLAMA_RUNTIME=1 swift build
```

To validate the **local model diagnostics** UX (GGUF validation, dylib discovery, architecture checks, and memory-fit estimates), use:

- Manual checklist: `Docs/LocalModelDiagnosticsManualQA.md`
- Troubleshooting guide: `Docs/TroubleshootingLocalModels.md`

If `pkg-config llama` is unavailable or incomplete, provide the same flags manually:

```sh
AUTOCOMP_LLAMA_CFLAGS="-I/path/to/include" \
AUTOCOMP_LLAMA_LIBS="-L/path/to/lib -llama -lggml" \
swift build
```

Settings > Privacy includes a source policy table for AX text, clipboard context, Screen OCR, debug logs, and local productivity metrics. Local metrics can include redacted stage latency reports for bug reports, with numeric timings only. The same policy, including remote-backend exposure and retention limits, is documented in `Docs/PrivacyPolicy.md`.

## Architecture Policy

AutoComp implementation and review work must follow the clean-room policy in `Docs/CleanRoomPolicy.md` when behavior is informed by external autocomplete applications. The policy requires AutoComp-owned code, names, tests, UI text, prompts, and assets.

The app pipeline, composition root, capture flow, prediction flow, overlay tiers, insertion path, privacy boundaries, and testing entry points are mapped in `Docs/Architecture.md`.

## Safe debug

Normal debug logging must not include user text, prompts, raw OCR, or clipboard content. Use hashes, sizes, states, and reasons when recording completion or geometry behavior.

Sensitive prompt previews and local debug artifacts require explicit opt-in in Settings > Privacy. When enabled, artifacts are written under Application Support with a warning header and may contain prompts, OCR, clipboard context, or typed text. Use Settings > Privacy > Debug > Export Debug Logs to save a local debug bundle, Delete Debug Artifacts to remove them, or Delete All Local Privacy Data to clear personalization, writing preferences, productivity metrics, and sensitive debug artifacts together.

`./script/qa_real_app_matrix.sh` redacts command logs before they are attached to QA notes. Keep sensitive local debug artifacts out of reports unless the opt-in was intentional and the contents were reviewed.

## Release

Release planning, signing, notarization, DMG packaging, Sparkle update checks, and appcast generation are documented in `Docs/ReleasePipeline.md`. The release build fetches the pinned Sparkle archive, embeds `Sparkle.framework`, injects `SUFeedURL` and `SUPublicEDKey`, notarizes and staples the DMG, then signs the final DMG bytes into `appcast.xml`.

Run a release dry run before using signing credentials:

```sh
./script/release_build.sh --dry-run --version 0.0.0 --build 0 \
  --download-url https://example.invalid/AutoComp.dmg \
  --release-notes-url https://example.invalid/releases/v0.0.0
```

Run the beta readiness gate before beta release builds:

```sh
./script/release_build.sh --beta-gate
```

Use `--skip-llama-build "reason"` or `--skip-ui-smoke "reason"` only when that host cannot run the conditional local-runtime or UI automation checks; the gate records those as structured skips.

Real releases require `AUTOCOMP_RELEASE_SIGNING_IDENTITY`, `AUTOCOMP_NOTARY_PROFILE`, `AUTOCOMP_SPARKLE_FEED_URL`, `AUTOCOMP_SPARKLE_PUBLIC_KEY`, and a Sparkle private key available through `AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE` or the local Keychain. Keep release secrets out of the repository. After publishing the DMG and appcast, verify an older installed app detects the update with `Check for Updates...`.

## Uninstall

Run a dry run before removing local state:

```sh
./script/uninstall.sh --dry-run
```

The uninstall script removes installed AutoComp app bundles, preferences, caches, logs, Keychain items, and `~/Library/Application Support/AutoComp`, including optional local models and debug artifacts. It is idempotent. It does not modify macOS TCC permissions; revoke Accessibility, Input Monitoring, Screen Recording, Local Network, and Apple Events manually in System Settings > Privacy & Security when a full reset is required.

## QA

Use the headless CI gate for deterministic build/test coverage that does not require macOS GUI permissions or real host apps:

```sh
./script/ci_headless.sh
```

The local-runtime build matrix is split into explicit legs:

```sh
./script/build_without_llama.sh
./script/build_with_llama.sh
```

`build_with_llama.sh` requires `pkg-config llama` or explicit `AUTOCOMP_LLAMA_CFLAGS` and `AUTOCOMP_LLAMA_LIBS` values before it compiles the optional runtime targets. Set `AUTOCOMP_CI_RUN_LLAMA_MATRIX=1` to include that leg in `./script/ci_headless.sh`.

Real-app validation coverage is documented in `Docs/AppQAMatrix.md`. Use `./script/qa_real_app_matrix.sh` to run and record the automated smoke coverage, or to record skipped UI smoke checks with an explicit host-environment reason.
