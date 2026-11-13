# Axiom Edge

**Open-source offline LLM harness for Android and iOS.** Import, download,
chat with, benchmark and smoke-test small on-device language models.

Android APK downloads: [GitHub Releases](https://github.com/agent-axiom/axiom-edge/releases).

## Status

**v0.1.2 development prototype.** A user-supplied v0.1.1 GGUF smoke export
from Nothing A059P / Android 17 reports 2 of 3 checks passed; that phone run
has not been independently reproduced. The new sustained benchmark still
needs an on-device run.

Local validation on 2026-11-10:

- Flutter 3.38.6 / Dart 3.10.7: formatting and static analysis pass; 4 tests pass.
- Rust 1.99.1: formatting, Clippy (`-D warnings`) and all 4 integration tests pass.
- Platform bootstrap: 11 Python tests pass; both GitHub workflows pass actionlint.
- Android ARM64 release APK builds successfully (Android 9 / API 28 minimum);
  its APK v2 debug signature and ARM64-only native libraries were verified.
- iOS compilation and on-device model inference remain unverified.

The Android project limits Gradle workers and compiles Kotlin in-process to
reduce memory use. A 4 GB Linux host may still need swap for Dart AOT compilation.

GitHub CI provides mobile integration builds and tagged APK releases.
Performance measurements have not been independently verified.

## v0.1 features

| Feature | Android (arm64) | iOS (16.4+) |
|---|---|---|
| GGUF via llama.cpp (`llamadart`) | Implemented in source | Implemented in source |
| Import a GGUF file | Yes | Yes |
| Download Pocket Q4_1 (~192 MB) from HF | Yes | Yes |
| MNN INT4 (~173 MB) direct HF download/import | Experimental, may fail | Not available |
| Import complete MNN directory via system folder picker | Yes | Not available |
| Streaming local chat | Yes | Yes, GGUF |
| Deterministic smoke evals (exact, JSON, contains) | Yes | Yes |
| TTFT + native/sampled throughput + JSON export | Yes | Yes |
| Warm benchmark: 2 warmups + 5 repeated long generations | Yes | Yes, GGUF |
| Median/p90 and replay inputs in JSON schema 2.0 | Yes | Yes |

Official model sources:

- [Pocket GGUF](https://huggingface.co/taobao-mnn/MNN-Pocket-0.3B-GGUF), license Apache-2.0.
- [Pocket MNN](https://huggingface.co/taobao-mnn/MNN-Pocket-0.3B-MNN), license Apache-2.0.

## Quickstart

Validated toolchain: Flutter **3.38.6**, Dart **3.10.7**, Python **3.10+**, Android SDK
(API 28+, arm64 phone), or macOS + Xcode for iOS **16.4+**.

```bash
# Generate Android (Linux/Windows) or Android + iOS (macOS) platform projects:
# On macOS first: flutter config --enable-swift-package-manager
python3 tool/bootstrap.py
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub

# Connect Android ARM64 phone with USB debugging:
flutter run -d <android-device-id>

# For an Android test APK signed with a debug key:
flutter build apk --release --target-platform android-arm64 --split-per-abi

# On macOS with Xcode, for iOS:
flutter config --enable-swift-package-manager
python3 tool/bootstrap.py --platforms ios --configure-only
flutter run --no-pub -d <ios-device-id>
```

Flutter 3.38.6 requires Xcode to resolve SwiftPM-only plugins when an iOS
project is present. Generate iOS only on macOS; Linux Android CI uses
`python3 tool/bootstrap.py --platforms android`.

The bootstrap sets Android minSdk to 28 and Android Gradle Plugin to at least
8.12.1, permits HTTP only for localhost
(MNN internal API) and sets the iOS deployment target to 16.4. The generated
Android project is included. The iOS shell is generated on macOS and ignored
by Git to keep Linux dependency resolution working with Flutter 3.38.6.
After resolving dependencies on macOS, `--configure-only` reapplies iOS 16.4
to the generated Swift package. Run iOS builds with `--no-pub` afterwards;
a new dependency resolution regenerates that package with Flutter's default target.

On the phone:

1. Open **Models**, select **Download** for Pocket GGUF; or **Import GGUF**.
2. Tap the stored model to load it.
3. Open **Chat** for streaming responses.
4. Open **Checks**, tap **Измерить скорость** for the warm benchmark,
   or **Проверить ответы** for the separate `pocket-smoke-v1` suite.
5. Export each result using its own JSON button through the share sheet.

On Android, MNN can also import a **directory** through SAF; importing a
single `llm.mnn` file is insufficient. The downloaded MNN weights may need
re-exporting / a matching MNN native runtime if you see `Load module failed`.

## Benchmarks and limitations

- Native llama.cpp timing comes from `getPerformanceContext()`. Decode and
  prefill rates are omitted if the backend does not report them.
- MNN streams via a loopback server. Its decode rate (only if the SSE response
  includes `completion_tokens`) is a **whole-request wall-clock estimate**, not equivalent
  to native llama.cpp eval timing.
- Time to first text is observed at the application layer and includes
  scheduling/buffering; it is not necessarily the backend TTFT.
- The bundled 3-case suite is a smoke test, **not** a scientific leaderboard.
- The speed benchmark uses 2 warmups and 5 measured generations, each capped
  at 256 tokens. Outputs below 128 reported decode tokens are excluded from
  throughput summaries but retained in raw results and latency summaries.
- GGUF requests temperature 0, seed 42 and no prompt-prefix reuse.
  MNN cannot enforce seed or prefix-cache controls through its current API;
  its model-load sampler can determine effective temperature behavior.
- Sources are summarized separately. Median and nearest-rank p90 use per-run
  values; with five valid values p90 is the maximum.
- JSON schema 2.0 preserves prompts, assertions, requested settings, runtime
  capabilities, run/export times, warmups, measured samples and incomplete state.
- No memory/temperature tracking, cold-start trials, download resume,
  quantization provenance verification or iOS MNN engine in v0.1.

See [benchmark protocol](docs/BENCHMARK.md) and
[engine measurement notes](docs/BENCHMARK_ENGINE_NOTES.md).

## Publish under agent-axiom

To publish from a workstation, install `gh`, configure your Git author identity,
and sign in with `gh auth login` using an account allowed to create repositories
under `agent-axiom`. Then run:

```bash
bash tool/publish.sh
```

The script creates `agent-axiom/axiom-edge` if missing, configures `origin`,
commits changes and pushes `main`. It refuses to overwrite an unrelated `origin`.

## CI and version releases

`.github/workflows/mobile.yml` runs on pushes to `main`, pull requests, manual
runs, and tags `v*`:

- `android`: test/bootstrap Flutter project, verify formatting, analyze, test, build **ARM64 release APK**,
  upload workflow artifact retained 30 days.
- `ios`: analyze/test and build unsigned iOS release (not an installable IPA).
- `release`: only for `v*` tags and only after the Android job succeeds; downloads
  that **same built APK**, computes `SHA256SUMS` and publishes both to GitHub Releases.

After **verifying a green Android CI** for `main`, publish the first version:

```bash
git tag v0.1.1
git push origin v0.1.1
```

View APK build output in `Actions → Mobile CI → Artifacts` and tagged APKs in
`Releases`. If repository policy disallows job-level write tokens, allow GitHub
Actions to publish releases (`contents: write`) in repository settings.

No signing credentials are required for Android test APKs. Flutter release APKs
are test-signed by the default debug keystore unless a real signing configuration
is added. Fresh CI runners generate different debug keys, so installing a new
build over an old one may require uninstalling the previous build (which removes
its app data). Do not ship them via Play Store without release signing. Review the
code and build results before distributing builds.

## Development

- Flutter code: `lib/`
- Deterministic evaluation suite: `assets/evals/smoke.json`
- Rust evaluator (currently independent, not linked into Flutter):
  `rust/axiom_edge_core`; run `cargo test --locked` there.
- Android/iOS CI builds: `.github/workflows/mobile.yml`
- Rust CI: `.github/workflows/rust.yml`
- Bootstrap regression tests: `python3 -m unittest discover -s tool/tests -v`
- Architecture / roadmap: `docs/ARCHITECTURE.md`

License: MIT for Axiom Edge sources. Third-party plugins, runtimes and model
weights retain their respective licenses.
