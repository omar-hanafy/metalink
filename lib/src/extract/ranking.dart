import 'package:metalink/src/extract/candidate.dart';
import 'package:metalink/src/model/diagnostics.dart';

/// A ranked candidate and the deterministic position assigned by a policy.
class RankedCandidate<T> {
  /// Creates a ranking entry for [candidate].
  const RankedCandidate({
    required this.candidate,
    required this.effectiveScore,
    required this.originalIndex,
  });

  /// The candidate being ranked.
  ///
  /// Pass the same instance that [RankingPolicy.rank] received. The pipeline
  /// recognizes winners and merge contributors by identity, so a copied
  /// candidate is never reported as selected in [CandidateDecision.selected].
  final Candidate<T> candidate;

  /// The score this entry was ordered by, after any field-specific
  /// adjustments the policy applied.
  ///
  /// Reported as [CandidateDecision.effectiveScore] next to the extractor's
  /// original [Candidate.score]. [DefaultRankingPolicy] uses [Candidate.score]
  /// unchanged.
  final double effectiveScore;

  /// The zero-based position of [candidate] in the list passed to
  /// [RankingPolicy.rank].
  ///
  /// [DefaultRankingPolicy] uses it to break score ties in favor of earlier
  /// candidates, which reflect stage order and then document order.
  final int originalIndex;
}

/// The ordered outcome of ranking candidates for one metadata field.
class RankingDecision<T> {
  /// Creates a decision whose [ranked] entries are ordered best first.
  const RankingDecision({required this.ranked});

  /// The accepted candidates, best first.
  ///
  /// For a single-valued field such as the title, only [winner] is used. For
  /// a collection such as images or keywords, the pipeline walks this order
  /// and keeps the first entry for each distinct item up to the configured
  /// limit; later entries for an image, icon, video, or audio item only fill
  /// attributes the kept entry lacks. A candidate the policy leaves out is
  /// rejected: it cannot be selected and does not appear in candidate
  /// decisions.
  final List<RankedCandidate<T>> ranked;

  /// The best entry, or `null` when [ranked] is empty.
  RankedCandidate<T>? get winner => ranked.isEmpty ? null : ranked.first;
}

/// Central policy for ordering metadata candidates.
///
/// A policy receives every candidate for a field and returns a deterministic
/// ordering, best first. It may leave candidates out to reject them. Keeping
/// this boundary explicit lets ranking improvements evolve without spreading
/// score comparisons across extractors.
///
/// Supply a custom policy through `MetaLinkParser(rankingPolicy: ...)`. The
/// default is [DefaultRankingPolicy].
abstract interface class RankingPolicy {
  /// Orders [candidates] for [field], best first.
  ///
  /// [documentUrl] is the final URL of the parsed document, available for
  /// URL-aware signals. [candidates] is in stage order and then document
  /// order, and may be empty.
  ///
  /// The pipeline can call this more than once for the same field, for
  /// example to choose a value and again to record candidate decisions, so
  /// the result must depend only on the arguments. Return the received
  /// [Candidate] instances unchanged inside each [RankedCandidate].
  RankingDecision<T> rank<T>({
    required MetaField field,
    required List<Candidate<T>> candidates,
    required Uri documentUrl,
  });
}

/// Compatibility-preserving default ranking policy.
///
/// Higher extractor scores win. Equal scores retain stage and document order
/// through the explicit [RankedCandidate.originalIndex] tie-break. This matches
/// the v2 behavior while making the rule deterministic and replaceable.
/// Candidates whose score is `NaN` or infinite are rejected.
class DefaultRankingPolicy implements RankingPolicy {
  /// Creates the stateless default policy.
  const DefaultRankingPolicy();

  @override
  RankingDecision<T> rank<T>({
    required MetaField field,
    required List<Candidate<T>> candidates,
    required Uri documentUrl,
  }) {
    if (candidates.isEmpty) {
      return const RankingDecision(ranked: []);
    }

    final ranked = <RankedCandidate<T>>[];
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      if (!candidate.score.isFinite) continue;

      ranked.add(
        RankedCandidate<T>(
          candidate: candidate,
          effectiveScore: candidate.score,
          originalIndex: index,
        ),
      );
    }

    ranked.sort((left, right) {
      final byScore = right.effectiveScore.compareTo(left.effectiveScore);
      if (byScore != 0) return byScore;
      return left.originalIndex.compareTo(right.originalIndex);
    });

    return RankingDecision<T>(
      ranked: List<RankedCandidate<T>>.unmodifiable(ranked),
    );
  }
}
