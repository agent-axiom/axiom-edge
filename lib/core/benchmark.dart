import 'dart:math' as math;

import 'models.dart';
import 'runner.dart';

/// A warm, sequential generation benchmark, not a model-quality evaluation.
class BenchmarkConfig {
  const BenchmarkConfig({
    this.warmupRuns = 2,
    this.measuredRuns = 5,
    this.maxTokens = 256,
    this.minDecodeTokens = 128,
    this.temperature = 0,
    this.seed = 42,
    this.reusePromptPrefix = false,
    this.prompt = defaultPrompt,
  });

  static const defaultPrompt =
      'Write a detailed explanation of how a satellite is built, launched, '
      'controlled in orbit, and safely retired. Use at least 600 words and '
      'explain each stage in full paragraphs. Continue until every stage is '
      'covered; do not give a short summary.';

  final int warmupRuns;
  final int measuredRuns;
  final int maxTokens;
  final int minDecodeTokens;
  final double temperature;
  final int? seed;
  final bool reusePromptPrefix;
  final String prompt;

  int get totalRuns => warmupRuns + measuredRuns;

  void validate() {
    if (warmupRuns < 0 || measuredRuns < 1) {
      throw ArgumentError(
        'Require nonnegative warmups and positive measured runs',
      );
    }
    if (maxTokens < 1 || minDecodeTokens < 1 || minDecodeTokens > maxTokens) {
      throw ArgumentError('Require 1 <= minDecodeTokens <= maxTokens');
    }
    if (!temperature.isFinite || temperature < 0 || prompt.trim().isEmpty) {
      throw ArgumentError(
        'Require a finite nonnegative temperature and a prompt',
      );
    }
  }

  Map<String, Object?> get generation => {
    'max_tokens': maxTokens,
    'temperature': temperature,
    'seed': seed,
    'reuse_prompt_prefix': reusePromptPrefix,
  };

  Map<String, Object?> toJson() => {
    'warmup_runs': warmupRuns,
    'measured_runs': measuredRuns,
    'min_decode_tokens': minDecodeTokens,
    'prompt': prompt,
    'generation': generation,
    'context_policy': 'fresh user conversation for each run',
    'cache_policy':
        'runner retained; see runner_configuration for backend support',
  };
}

class BenchmarkSample {
  const BenchmarkSample({
    required this.phase,
    required this.index,
    required this.startedAt,
    required this.status,
    required this.prompt,
    required this.generation,
    this.response = '',
    this.metrics,
    this.error,
  });

  final String phase;
  final int index;
  final DateTime startedAt;
  final String status;
  final String prompt;
  final Map<String, Object?> generation;
  final String response;
  final InferenceMetrics? metrics;
  final String? error;

  bool get isMeasured => phase == 'measured';
  bool get completed => status == 'completed';

  Map<String, Object?> toJson() {
    final rawMetrics = metrics?.toJson();
    final nonFinite = <String>[];
    if (rawMetrics != null) {
      for (final key in rawMetrics.keys.toList()) {
        final value = rawMetrics[key];
        if (value is num && !value.isFinite) {
          // JSON cannot encode NaN/Infinity. Retain the field and reason.
          nonFinite.add(key);
          rawMetrics[key] = null;
        }
      }
    }
    return {
      'phase': phase,
      'index': index,
      'started_at': startedAt.toUtc().toIso8601String(),
      'status': status,
      'prompt': prompt,
      'messages': [ChatTurn('user', prompt).toJson()],
      'generation': generation,
      'response': response,
      'metrics': rawMetrics,
      if (nonFinite.isNotEmpty) 'non_finite_metric_fields': nonFinite,
      if (error != null) 'error': error,
    };
  }
}

class BenchmarkSession {
  BenchmarkSession({
    required this.config,
    required Iterable<BenchmarkSample> samples,
    required this.startedAt,
    required this.finishedAt,
    required this.complete,
    required this.cancelled,
    Map<String, Object?> runnerConfiguration = const {},
  }) : samples = List.unmodifiable(samples),
       runnerConfiguration = Map.unmodifiable(runnerConfiguration);

  final BenchmarkConfig config;
  final List<BenchmarkSample> samples;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool complete;
  final bool cancelled;
  final Map<String, Object?> runnerConfiguration;

  /// Per-run distributions, never a pooled rate across measurement sources.
  /// Median averages the central pair; p90 uses nearest-rank ceil(0.9*n).
  Map<String, Map<String, Object?>> get summaryBySource {
    final groups = <String, List<BenchmarkSample>>{};
    for (final sample in samples.where((sample) => sample.isMeasured)) {
      final source = sample.metrics?.source ?? 'unavailable';
      groups.putIfAbsent(source, () => []).add(sample);
    }
    return {
      for (final group in groups.entries) group.key: _summarize(group.value),
    };
  }

  Map<String, Object?> _summarize(List<BenchmarkSample> group) {
    final completed = group.where((sample) => sample.completed).toList();
    final eligible = completed.where((sample) {
      final tokens = sample.metrics?.decodeTokens;
      return tokens != null && tokens >= config.minDecodeTokens;
    }).toList();
    return {
      'sample_count': group.length,
      'completed_count': completed.length,
      'cancelled_count': group.where((s) => s.status == 'cancelled').length,
      'error_count': group.where((s) => s.status == 'error').length,
      'short_output_count': completed.where((s) {
        final tokens = s.metrics?.decodeTokens;
        return tokens != null && tokens < config.minDecodeTokens;
      }).length,
      'unknown_decode_tokens_count': completed
          .where((s) => s.metrics?.decodeTokens == null)
          .length,
      'throughput_eligible_count': eligible.length,
      'throughput_excluded_count': group.length - eligible.length,
      'ttft_ms': _distribution(completed.map((s) => s.metrics?.ttftMs)),
      'total_ms': _distribution(completed.map((s) => s.metrics?.totalMs)),
      'decode_tokens_per_s': _distribution(
        eligible.map((s) => s.metrics?.decodeTps),
        positiveOnly: true,
      ),
      'prefill_tokens_per_s': _distribution(
        eligible.map((s) => s.metrics?.prefillTps),
        positiveOnly: true,
      ),
    };
  }

  Map<String, Object?> toJson() => {
    'protocol': 'warm-generation-v1',
    'started_at': startedAt.toUtc().toIso8601String(),
    'finished_at': finishedAt.toUtc().toIso8601String(),
    'complete': complete,
    'cancelled': cancelled,
    'planned_runs': config.totalRuns,
    'recorded_runs': samples.length,
    'config': config.toJson(),
    'runner_configuration': runnerConfiguration,
    'aggregation': {
      'warmups_included': false,
      'throughput_min_decode_tokens': config.minDecodeTokens,
      'distribution': 'unweighted per-run; grouped by measurement_source',
      'median_method': 'central value; mean of central pair for even n',
      'p90_method': 'nearest rank: ceil(0.9 * n), one-based',
      'latency_population': 'completed measured runs, including short outputs',
      'throughput_population': 'completed measured runs meeting token minimum',
      'small_sample_note': 'With five samples, nearest-rank p90 is the maximum',
      'ttft_semantics':
          'application-observed first nonempty text; may be batched',
    },
    'summary_by_source': summaryBySource,
    'samples': samples.map((sample) => sample.toJson()).toList(),
  };
}

Map<String, Object?> _distribution(
  Iterable<num?> raw, {
  bool positiveOnly = false,
}) {
  final values = <double>[];
  var missing = 0;
  var invalid = 0;
  for (final value in raw) {
    if (value == null) {
      missing++;
    } else if (!value.isFinite || (positiveOnly ? value <= 0 : value < 0)) {
      invalid++;
    } else {
      values.add(value.toDouble());
    }
  }
  values.sort();
  final n = values.length;
  return {
    'count': n,
    'missing_count': missing,
    'invalid_count': invalid,
    'min': n == 0 ? null : values.first,
    'max': n == 0 ? null : values.last,
    'median': n == 0
        ? null
        : n.isOdd
        ? values[n ~/ 2]
        : (values[n ~/ 2 - 1] + values[n ~/ 2]) / 2,
    'p90': n == 0 ? null : values[math.max(0, (0.9 * n).ceil() - 1)],
  };
}

class BenchmarkService {
  BenchmarkService(this.runner, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ModelRunner runner;
  final DateTime Function() _now;

  Future<BenchmarkSession> run({
    BenchmarkConfig config = const BenchmarkConfig(),
    bool Function()? isCancelled,
    void Function(BenchmarkSample sample, int completed, int total)? onSample,
    void Function(String phase, int index, int total)? onProgress,
  }) async {
    config.validate();
    final runnerConfiguration = Map<String, Object?>.from(runner.configuration);
    final startedAt = _now();
    final samples = <BenchmarkSample>[];
    var cancelled = false;
    var failed = false;
    for (var i = 0; i < config.totalRuns; i++) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final warmup = i < config.warmupRuns;
      final phase = warmup ? 'warmup' : 'measured';
      final index = warmup ? i + 1 : i - config.warmupRuns + 1;
      onProgress?.call(
        phase,
        index,
        warmup ? config.warmupRuns : config.measuredRuns,
      );
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final sampleStart = _now();
      final streamedText = StringBuffer();
      GenerationResult? result;
      String? error;
      try {
        result = await runner.generate(
          [ChatTurn('user', config.prompt)],
          maxTokens: config.maxTokens,
          temperature: config.temperature,
          seed: config.seed,
          reusePromptPrefix: config.reusePromptPrefix,
          onDelta: streamedText.write,
        );
      } catch (exception) {
        error = exception.toString();
      }
      cancelled = isCancelled?.call() ?? false;
      failed = error != null && !cancelled;
      final sample = BenchmarkSample(
        phase: phase,
        index: index,
        startedAt: sampleStart,
        status: cancelled
            ? 'cancelled'
            : failed
            ? 'error'
            : 'completed',
        prompt: config.prompt,
        generation: config.generation,
        response: result?.text ?? streamedText.toString(),
        metrics: result?.metrics,
        error: error,
      );
      samples.add(sample);
      onSample?.call(sample, samples.length, config.totalRuns);
      if (cancelled || failed) break;
    }
    // Cancellation can be requested from a progress callback after a run.
    cancelled = cancelled || (isCancelled?.call() ?? false);
    return BenchmarkSession(
      config: config,
      samples: samples,
      startedAt: startedAt,
      finishedAt: _now(),
      complete: !cancelled && !failed && samples.length == config.totalRuns,
      cancelled: cancelled,
      runnerConfiguration: runnerConfiguration,
    );
  }
}
