# Axiom Edge · Architecture

## v0.2 data flow

The primary chat UI uses `ChatState` for provider selection, conversations,
streaming state and drafts. `ChatPersistence` stores a versioned archive inside
Application Support. `ChatKeyVault` stores API keys in the platform secure store.
`CloudGateway` is injected for tests; `HttpCloudGateway` talks directly to the
fixed official OpenAI Responses and Z.AI Chat Completions endpoints over HTTPS.

The independent `LabState` owns local model selection, downloads and benchmark
runs. `GgufRunner` uses llamadart/llama.cpp; `MnnRunner` uses the Android MNN
plugin's authenticated loopback API. Benchmark/evaluation records remain
separate JSON exports. Rust validation is a standalone, unbridged component.


The first runnable increment uses Dart for orchestration because both inference
runtimes expose Flutter/Dart APIs. Adding Rust FFI here would increase the mobile
build matrix without helping model loading. Rust deterministic validation is
already included with the same suite schema; `flutter_rust_bridge` integration
can follow after device-level smoke tests and engine compatibility checks.

## Design decisions

- One loaded model at a time to keep memory use bounded.
- No Axiom account, backend or telemetry. Cloud requests go directly to the
  selected provider using the owner's key; no automatic model fallback. MNN's
  API is loopback only, with a random per-session bearer key.
- Downloaded model weights remain within the app sandbox.
- The upstream MNN plugin has prebuilt binaries at MNN 3.6.1; Pocket INT4 may
  require a newer native runtime due to tied-embedding layout. The MNN path is
  **experimental**, with no promise of compatibility until tested on hardware.
- GGUF inference metrics use native llama.cpp prompt/eval durations. MNN
  throughput, if token usage is provided by SSE, is a wall-clock approximation.
  Null is exported when the token count or latency is unavailable.
- Initial HF URLs point at `main`. The resulting GGUF file SHA-256 is recorded
  in metadata, but source revisions and signed manifests are not pinned yet.
  Reproducibility of benchmarks across different downloads is therefore
  contingent on comparing hashes.
- Cloud inference and live catalogs require a network connection. Saved cloud
  history is readable offline; local generation works offline once native
  runtimes and models are installed. See [cloud chat](CLOUD_CHAT.md).

## Planned milestones

1. Broader device verification for Android arm64 and iOS Metal builds.
2. Pin model source revision + upstream hash; resume and cancel downloads.
3. Rebuild/verify MNN Android binaries against the specific Pocket export.
4. Streaming memory/thermal samples with OS-specific APIs; cold/warm trials.
5. YAML suites, JSON Schema, regex and tool-call verification in Rust, exposed
   to Flutter via flutter_rust_bridge.
6. Optional ONNX / LiteRT-LM / Core ML adapters; comparison dashboard.
