import 'package:metalink/src/extract/candidate.dart';
import 'package:metalink/src/model/diagnostics.dart';

/// A ranked candidate and the deterministic position assigned by a policy.
class RankedCandidate<T> {
  const RankedCandidate({
    required this.candidate,
    required this.effectiveScore,
    required this.originalIndex,
  });

  final Candidate<T> candidate;
  final double effectiveScore;
  final int originalIndex;
}

/// The ordered outcome of ranking candidates for one metadata field.
class RankingDecision<T> {
  const RankingDecision({required this.ranked});

  final List<RankedCandidate<T>> ranked;

  RankedCandidate<T>? get winner => ranked.isEmpty ? null : ranked.first;
}

/// Central policy for ordering metadata candidates.
///
/// A policy receives every candidate for a field and must return a complete,
/// deterministic ordering. Keeping this boundary explicit lets future ranking
/// improvements evolve without spreading score comparisons across extractors.
abstract interface class RankingPolicy {
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
class DefaultRankingPolicy implements RankingPolicy {
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
