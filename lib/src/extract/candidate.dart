/// @docImport 'package:metalink/src/extract/ranking.dart';
library;

import 'package:metalink/src/model/diagnostics.dart';

/// A scored candidate value with provenance information.
///
/// [Candidate] represents a potential metadata value extracted from the HTML
/// document. Multiple candidates may exist for each field, and a
/// [RankingPolicy] orders them to choose the result.
///
/// ### Scoring
/// * Built-in extractors use scores from `0.0` (lowest confidence) to `1.0`
///   (highest). The range is a convention and is not enforced.
/// * Higher-priority sources (e.g., Open Graph) receive higher base scores.
/// * [DefaultRankingPolicy] selects the highest-scoring candidate for each
///   field, keeps the earliest candidate on ties, and rejects candidates whose
///   score is `NaN` or infinite.
///
/// Candidates do not override `==`; the pipeline tracks them by identity.
///
/// ### Fields
/// * [value] - The extracted value.
/// * [source] - Where the value came from (see [CandidateSource]).
/// * [score] - Confidence score for ranking.
/// * [evidence] - Optional debug context (e.g., the raw tag).
class Candidate<T> {
  /// Creates a [Candidate].
  const Candidate({
    required this.value,
    required this.source,
    required this.score,
    this.evidence,
  });

  /// The extracted value.
  final T value;

  /// The source that provided this value.
  final CandidateSource source;

  /// Confidence score for ranking, conventionally `0.0` to `1.0`.
  final double score;

  /// Optional debug context (e.g., the raw attribute value).
  final String? evidence;
}
