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

  test(
    'ExtractionDiagnostics.fromJson keeps provenance from untyped nested maps',
    () {
      final diag = ExtractionDiagnostics(
        cacheHit: true,
        totalTime: const Duration(milliseconds: 5),
        fetch: FetchDiagnostics(
          requestedUrl: Uri.parse('https://example.com/a'),
          finalUrl: Uri.parse('https://example.com/b'),
          statusCode: 200,
          redirects: [
            RedirectHop(
              from: Uri.parse('https://example.com/a'),
              to: Uri.parse('https://example.com/b'),
              statusCode: 301,
            ),
          ],
          bytesRead: 10,
          truncated: false,
          detectedCharset: 'utf-8',
          charsetSource: CharsetSource.header,
          duration: const Duration(milliseconds: 3),
        ),
        fieldProvenance: const {
          MetaField.title: FieldProvenance(
            source: CandidateSource.openGraph,
            score: 0.9,
            evidence: 'og:title',
          ),
          MetaField.description: FieldProvenance(
            source: CandidateSource.standardMeta,
            score: 0.6,
          ),
        },
        itemProvenance: const {
          MetaField.images: [
            ItemProvenance(
              itemKey: 'https://example.com/image.png',
              provenance: FieldProvenance(
                source: CandidateSource.openGraph,
                score: 0.8,
              ),
              contributors: [
                FieldProvenance(source: CandidateSource.openGraph, score: 0.8),
              ],
            ),
          ],
        },
        candidateDecisions: const {
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

      // A custom CacheStore codec can hand back maps typed as
      // Map<dynamic, dynamic> at every nesting level.
      final untyped = Map<String, dynamic>.from(
        _untyped(diag.toJson())! as Map<dynamic, dynamic>,
      );
      expect(untyped['fieldProvenance'], isNot(isA<Map<String, dynamic>>()));

      final decoded = ExtractionDiagnostics.fromJson(untyped);

      expect(decoded.provenanceAvailable, isTrue);
      expect(decoded.fieldProvenance.keys, <MetaField>[
        MetaField.title,
        MetaField.description,
      ]);
      final title = decoded.fieldProvenance[MetaField.title]!;
      expect(title.source, CandidateSource.openGraph);
      expect(title.score, 0.9);
      expect(title.evidence, 'og:title');
      expect(
        decoded.fieldProvenance[MetaField.description]!.source,
        CandidateSource.standardMeta,
      );
      expect(
        decoded.itemProvenance[MetaField.images]?.single.itemKey,
        'https://example.com/image.png',
      );
      expect(
        decoded.candidateDecisions[MetaField.title]?.single.selected,
        isTrue,
      );
      expect(decoded.fetch?.redirects.single.statusCode, 301);
    },
  );

  test('FetchDiagnostics.fromJson skips malformed redirect entries', () {
    final decoded = FetchDiagnostics.fromJson({
      'requestedUrl': 'https://example.com/a',
      'finalUrl': 'https://example.com/b',
      'redirects': [
        {
          'from': 'https://example.com/a',
          'to': 'https://example.com/b',
          'statusCode': 301,
        },
        'garbage',
        null,
      ],
    });

    expect(decoded.redirects, hasLength(1));
    expect(decoded.redirects.single.statusCode, 301);
    expect(decoded.redirects.single.to.toString(), 'https://example.com/b');
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

  group('ExtractionDiagnostics.fromJson skips values of the wrong shape', () {
    const provenance = <String, dynamic>{'source': 'openGraph', 'score': 1.0};
    const decision = <String, dynamic>{
      'valueKey': 'Title',
      'source': 'openGraph',
      'score': 1.0,
      'effectiveScore': 1.0,
      'selected': true,
    };
    const item = <String, dynamic>{
      'itemKey': 'https://example.com/a.png',
      'provenance': provenance,
    };

    test('itemProvenance entries whose value is not a list', () {
      for (final value in <Object>['notalist', 7, '[]', item]) {
        final decoded = ExtractionDiagnostics.fromJson({
          'itemProvenance': <String, dynamic>{
            'title': value,
            'images': [item],
          },
        });

        expect(decoded.itemProvenance.keys, [
          MetaField.images,
        ], reason: 'value $value');
      }
    });

    test('candidateDecisions entries whose value is not a list', () {
      for (final value in <Object>['notalist', 7, '[]', decision]) {
        final decoded = ExtractionDiagnostics.fromJson({
          'candidateDecisions': <String, dynamic>{
            'title': value,
            'description': [decision],
          },
        });

        expect(decoded.candidateDecisions.keys, [
          MetaField.description,
        ], reason: 'value $value');
      }
    });

    test('fieldProvenance entries whose value is not a map', () {
      for (final value in <Object>[
        'notamap',
        7,
        '{"source":"openGraph","score":1.0}',
        [provenance],
      ]) {
        final decoded = ExtractionDiagnostics.fromJson({
          'fieldProvenance': <String, dynamic>{
            'title': value,
            'description': provenance,
          },
        });

        expect(decoded.fieldProvenance.keys, [
          MetaField.description,
        ], reason: 'value $value');
      }
    });

    test('loosely typed lists and maps are still read', () {
      final decoded = ExtractionDiagnostics.fromJson(<String, dynamic>{
        'fieldProvenance': _untyped({'title': provenance}),
        'itemProvenance': _untyped({
          'images': [item],
        }),
        'candidateDecisions': _untyped({
          'title': [decision],
        }),
      });

      expect(decoded.fieldProvenance.keys, [MetaField.title]);
      expect(decoded.itemProvenance[MetaField.images], hasLength(1));
      expect(decoded.candidateDecisions[MetaField.title], hasLength(1));
    });
  });
}

/// Recursively rebuilds [value] so every map is `Map<dynamic, dynamic>` and
/// every list is `List<dynamic>`, as a loosely typed cache codec would.
Object? _untyped(Object? value) {
  if (value is Map) {
    return <dynamic, dynamic>{
      for (final entry in value.entries) entry.key: _untyped(entry.value),
    };
  }
  if (value is List) {
    return <dynamic>[for (final element in value) _untyped(element)];
  }
  return value;
}
