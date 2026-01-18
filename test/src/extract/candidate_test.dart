import 'package:metalink/src/extract/candidate.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:test/test.dart';

void main() {
  test('Candidate stores value, source, score, and evidence', () {
    const candidate = Candidate<String>(
      value: 'value',
      source: CandidateSource.openGraph,
      score: 0.75,
      evidence: 'meta[property="og:title"]',
    );

    expect(candidate.value, 'value');
    expect(candidate.source, CandidateSource.openGraph);
    expect(candidate.score, 0.75);
    expect(candidate.evidence, 'meta[property="og:title"]');
  });
}
