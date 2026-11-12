# Axiom Edge · Architecture

## v0.1 data flow

```
Flutter Material UI
  ├── ModelRegistry (app-private JSON metadata)
  ├── ModelDownloadService (Hugging Face HTTPS, staged atomic downloads)
  └── LabState (one active model; no cloud generation)
       ├── GgufRunner -> llamadart -> llama.cpp native runtime
       │     Android CPU / iOS Metal (depending on supported device/build)
       └── MnnRunner -> mnn_engine (Android ARM64 only)
             -> localhost:8081 OpenAI-style SSE (ephemeral bearer key)

Benchmark / eval records -> JSON share sheet
Shared smoke suite: assets/evals/smoke.json
Rust validator: rust/axiom_edge_core (standalone, not yet Flutter-bridged)
```

The first runnable increment uses Dart for orchestration because both inference
runtimes expose Flutter/Dart APIs. Adding Rust FFI here would increase the mobile
build matrix without helping model loading. Rust deterministic validation is
already included with the same suite schema; `flutter_rust_bridge` integration
can follow after device-level smoke tests and engine compatibility checks.

## Design decisions

- One loaded model at a time to keep memory use bounded.
- No telemetry, accounts, third-party inference endpoints, or listening on
  0.0.0.0. MNN's API is loopback only, with a random per-session bearer key.
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
- The app requires network only to download models. Local generation works
  offline once native runtimes and models are installed.

## Planned milestones

1. Device-verified Android arm64 and iOS Metal builds (current package is source-only).
2. Pin model source revision + upstream hash; resume and cancel downloads.
3. Rebuild/verify MNN Android binaries against the specific Pocket export.
4. Streaming memory/thermal samples with OS-specific APIs; cold/warm trials.
5. YAML suites, JSON Schema, regex and tool-call verification in Rust, exposed
   to Flutter via flutter_rust_bridge.
6. Optional ONNX / LiteRT-LM / Core ML adapters; comparison dashboard.
