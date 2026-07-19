import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:test/test.dart';

void main() {
  test('FieldProvenance toJson and fromJson', () {
    const fp = FieldProvenance(
      source: CandidateSource.openGraph,
      score: 0.9,
      evidence: 'e',
    );
    final decoded = FieldProvenance.fromJson(fp.toJson());
    expect(decoded.source, CandidateSource.openGraph);
    expect(decoded.score, 0.9);
    expect(decoded.evidence, 'e');
  });

  test('FetchDiagnostics toJson and fromJson', () {
    final diag = FetchDiagnostics(
      requestedUrl: Uri.parse('https://example.com/a'),
      finalUrl: Uri.parse('https://example.com/b'),
      statusCode: 200,
      redirects: [
        RedirectHop(
          from: Uri.parse('https://example.com/a'),
          to: Uri.parse('https://example.com/b'),
          statusCode: 301,
          location: 'https://example.com/b',
        ),
      ],
      bytesRead: 10,
      truncated: false,
      detectedCharset: 'utf-8',
      charsetSource: CharsetSource.header,
      duration: const Duration(milliseconds: 3),
    );

    final decoded = FetchDiagnostics.fromJson(diag.toJson());
    expect(decoded.requestedUrl.toString(), 'https://example.com/a');
    expect(decoded.finalUrl.toString(), 'https://example.com/b');
    expect(decoded.statusCode, 200);
    expect(decoded.redirects.length, 1);
    expect(decoded.bytesRead, 10);
    expect(decoded.detectedCharset, 'utf-8');
    expect(decoded.charsetSource, CharsetSource.header);
  });

  test('ExtractionDiagnostics toJson and fromJson', () {
    const diag = ExtractionDiagnostics(
      cacheHit: true,
      totalTime: Duration(milliseconds: 5),
      fetch: null,
      provenanceAvailable: false,
      fieldProvenance: {
        MetaField.title: FieldProvenance(
          source: CandidateSource.openGraph,
          score: 0.9,
        ),
      },
      itemProvenance: {
        MetaField.images: [
          ItemProvenance(
            itemKey: 'https://example.com/image.png',
            provenance: FieldProvenance(
              source: CandidateSource.openGraph,
              score: 0.8,
            ),
            contributors: [
              FieldProvenance(source: CandidateSource.openGraph, score: 0.8),
              FieldProvenance(source: CandidateSource.twitterCard, score: 0.7),
            ],
          ),
        ],
      },
      candidateDecisions: {
        MetaField.title: [
          CandidateDecision(
            valueKey: 'Title',
            source: CandidateSource.openGraph,
            score: 0.9,
            effectiveScore: 0.9,
            selected: true,
          ),
        ],
      },
    );

    final decoded = ExtractionDiagnostics.fromJson(diag.toJson());
    expect(decoded.cacheHit, isTrue);
    expect(decoded.totalTime.inMilliseconds, 5);
    expect(decoded.provenanceAvailable, isFalse);
    expect(decoded.fieldProvenance[MetaField.title]!.score, 0.9);
    expect(
      decoded.itemProvenance[MetaField.images]?.single.itemKey,
      'https://example.com/image.png',
    );
    expect(
      decoded.itemProvenance[MetaField.images]?.single.contributors.map(
        (contributor) => contributor.source,
      ),
      <CandidateSource>[CandidateSource.openGraph, CandidateSource.twitterCard],
    );
    expect(
      decoded.candidateDecisions[MetaField.title]?.single.selected,
      isTrue,
    );
  });

  test('legacy diagnostics default provenance availability to true', () {
    final decoded = ExtractionDiagnostics.fromJson({
      'cacheHit': false,
      'totalTimeMs': 1,
      'fieldProvenance': const <String, dynamic>{},
    });

    expect(decoded.provenanceAvailable, isTrue);
  });

  test('legacy item provenance treats the leading source as a contributor', () {
    final decoded = ItemProvenance.fromJson({
      'itemKey': 'https://example.com/image.png',
      'provenance': {'source': 'openGraph', 'score': 0.8},
    });

    expect(decoded.contributors, hasLength(1));
    expect(decoded.contributors.single.source, CandidateSource.openGraph);
    expect(decoded.contributors.single.score, 0.8);
  });

  test('ExtractionDiagnostics ignores invalid fieldProvenance entries', () {
    final decoded = ExtractionDiagnostics.fromJson({
      'cacheHit': false,
      'totalTimeMs': 1,
      'fieldProvenance': {
        'invalid': {'source': 'openGraph', 'score': 1.0},
        'title': 'not-a-map',
      },
    });
    expect(decoded.fieldProvenance, isEmpty);
  });
}
