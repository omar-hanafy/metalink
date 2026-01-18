import 'package:metalink/src/model/diagnostics.dart';

/// A scored candidate value with provenance information.
///
/// [Candidate] represents a potential metadata value extracted from the HTML
/// document. Multiple candidates may exist for each field, and the pipeline
/// selects the best one based on [score].
///
/// ### Scoring
/// * Scores range from `0.0` (lowest confidence) to `1.0` (highest).
/// * Higher-priority sources (e.g., Open Graph) receive higher base scores.
/// * The pipeline selects the highest-scoring candidate for each field.
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

  /// Confidence score for ranking. Range: `0.0` to `1.0`.
  final double score;

  /// Optional debug context (e.g., the raw attribute value).
  final String? evidence;
}
