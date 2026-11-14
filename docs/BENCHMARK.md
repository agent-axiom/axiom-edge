# Benchmark protocol and export

The Checks screen separates model correctness from sustained generation speed.
Neither mode is a general model-quality leaderboard.

## Warm generation

The `sustained-generation-v1` default protocol retains the loaded model and
executes two warmups followed by five measured generations, sequentially.
Each call has a fresh user conversation, the same prompt asking for at least
600 words, and a 256-token limit. The prompt encourages long output but cannot
guarantee it. Outputs with fewer than 128 reported decode tokens, or unknown
counts, remain in raw results but are excluded from throughput summaries.
Completed short outputs still enter latency summaries. Warmups enter neither.

Requested parameters are temperature 0, seed 42 and no prompt-prefix reuse.
GGUF applies them through llamadart. MNN cannot enforce seed or prefix caching
through the current bridge, and its model-load sampler can determine effective
temperature behavior. The export distinguishes requested settings from runtime
capabilities. A seed does not promise identical outputs across devices/builds.

Weights are not reloaded, filesystem caches are not forced cold, and battery
state, CPU scheduling and temperature are not normalized. Keep device conditions
similar when comparing runs. `BenchmarkConfig` allows other repeat counts for
development; the app uses the default protocol.

## Statistics

Measured samples are grouped by `measurement_source`; native llama.cpp and
whole-request MNN SSE timings are never pooled or treated as equivalent.
Distributions include count, missing/invalid counts, minimum, maximum, median
and p90. The median averages the middle pair for even counts. P90 uses nearest
rank `ceil(0.9 * n)` (one-based); with five valid values it is the maximum.
These are unweighted distributions of per-run rates, not pooled token/time rates.

First-text latency is application-observed, includes scheduling/buffering, and
can be batched. It is not a native first-token measurement. Runtime versions,
capabilities and measurement definitions are preserved in the export.

Cancelled/error samples never enter completed-run statistics. The session
stops on cancellation or the first error and retains any streamed partial text.
Protocol completion and throughput eligibility are separate: all calls may
finish with zero sufficiently long outputs, in which case no speed is reported.

## Correctness

Each `pocket-smoke-v2` probe uses a fresh conversation, 96-token limit,
temperature 0, seed 42 and no prompt-prefix reuse where supported. Reports
preserve prompts, assertions, expected values, responses and requested settings.
The JSON probe uses `json_success_true`: a top-level object must contain
`success` with the JSON boolean value `true`. Additional fields are allowed.
Missing, false, null, numeric, string and nested-only values fail, as do arrays,
malformed JSON and Markdown wrappers. The legacy `json_valid` rule remains
available for historical suites; its weaker object-only condition is not used
by `pocket-smoke-v2`.
Cancelled generations are not scored; backend errors retain the interrupted
case, error text and partial response. Completed and planned counts are separate.

## JSON schema 2.0

Both report types contain app version, device, model identity/source/hash when
known, engine, run start and export time. Sharing later does not change run time.

- `report_type=correctness`: runtime, status, summary, cases, plus optional
  error and interrupted_case.
- `report_type=performance`: benchmark config, runtime configuration, all
  samples, summaries by source, aggregation methods and completion state.

Benchmark samples record phase, index, start time, full prompt/messages,
requested settings, response, status and available metrics. Nonfinite metrics
become null with their names listed under `non_finite_metric_fields`. Missing
metrics are never replaced by zero. Historical schema 1.0 files are not rewritten
or imported; their missing prompts/settings cannot be recovered from JSON alone.

## Validation boundary

Scripted-runner tests check orchestration, exclusions, statistics, cancellation
and export provenance. They do not measure native model or phone performance.
Mobile CI checks Android and unsigned iOS compilation; installation and a new
benchmark run on a real phone remain separate checks.
