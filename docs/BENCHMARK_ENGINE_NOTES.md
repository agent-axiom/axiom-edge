# Engine measurement boundaries

The benchmark exports the requested generation parameters and each adapter's
`configuration`. Requested controls are not evidence that every engine supports
them. Compare runs using the same model, runtime, settings, measurement source,
and device conditions.

## GGUF / llama.cpp

Verified against the pinned [llamadart 0.19.3 package source][llamadart-source]:

- `llama_cpp_service.dart` calls `_resetRequestPerformance` before generation.
  It resets both native counters and the Dart timing fallback. Performance data
  returned after generation belongs to that request; subtracting the previous
  request's counters would be incorrect.
- Generation supports a sampler seed and prompt-prefix reuse control. Benchmark
  calls explicitly disable prefix reuse so prompt processing is measured again.
  Model weights remain loaded: this is a warm-inference benchmark, not a model
  load or cold-start benchmark.
- Chat requests still use the model's chat template. A seed and temperature zero
  improve repeatability, but do not establish identical output across hardware,
  native runtime builds, or model/template changes.
- Default native text deltas are batched at 8 token pieces or 512 bytes.
  Application TTFT measures arrival of the first nonempty text delta and can
  include multiple generated tokens. It is not backend time to the first token.
- Decode rate uses the request's reported evaluation-token count and evaluation
  time. Prefill rate uses evaluated prompt tokens, not cached or total context
  tokens. Missing or zero-duration counters leave rates unavailable.

## MNN / HTTP SSE

Verified against the pinned [mnn_engine 0.2.0 package source][mnn-source]:

- The HTTP request parser accepts token limit and temperature, but has no seed
  or prompt-prefix reuse controls. These requested benchmark settings cannot
  be enforced through this adapter. Configuration explicitly reports that.
- The upstream device-acceptance notes warn that MNN 3.6.1 constructs its sampler
  at model load: request temperature zero alone does not establish greedy,
  repeatable output. Imported model configuration remains relevant.
- Completion-token usage, when reported, is divided by the whole request's
  elapsed time. The first SSE text delta may contain multiple tokens, so
  subtracting TTFT while retaining every output token would inflate the rate.
  This `sse-wallclock` value includes prefill, HTTP, and scheduling, and must not
  be compared directly with native decode throughput. Prefill rate is unavailable.
- An SSE error, a runtime `cancelled` finish reason, or a connection ending
  without `[DONE]` raises an error rather than returning a seemingly successful
  partial result. An active user-cancel flag lets the benchmark record expected
  cancellation separately from a runtime failure.

Phone inference, thermal behavior, and hardware throughput require actual
on-device runs. Unit tests of benchmark orchestration do not measure them.

[llamadart-source]: https://pub.dev/api/archives/llamadart-0.19.3.tar.gz
[mnn-source]: https://pub.dev/api/archives/mnn_engine-0.2.0.tar.gz
