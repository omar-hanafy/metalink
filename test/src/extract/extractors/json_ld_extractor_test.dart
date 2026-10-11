import 'dart:convert';

import 'package:metalink/src/cache/memory_cache_store.dart';
import 'package:metalink/src/client.dart';
import 'package:metalink/src/extract/extractors/json_ld_extractor.dart';
import 'package:metalink/src/extract/extractors/open_graph_extractor.dart';
import 'package:metalink/src/extract/extractors/standard_meta_extractor.dart';
import 'package:metalink/src/extract/extractors/twitter_card_extractor.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../../support/fake_fetcher.dart';
import '../../../support/fixture_loader.dart';
import '../../../support/html_fetch_result.dart';
import '../../../support/test_helpers.dart';

void main() {
  test('extracts JSON-LD fields', () async {
    final html = readFixture('html/json_ld_article.html');
    // The fixture's Article declares `url` https://example.com/articles/1. An
    // Article whose `url` names another document describes that document, so
    // the fixture runs at the URL it declares.
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
      originalUrl: Uri.parse('https://example.com/articles/1'),
    );

    expect(metadata.title, 'JSON LD Title');
    expect(metadata.description, 'JSON LD Description');
    expect(metadata.author, 'Json Author');
    expect(metadata.siteName, 'Json Publisher');
    expect(metadata.kind, LinkKind.article);
    expect(metadata.images.length, 1);
    expect(
      metadata.images.first.url.toString(),
      'https://example.com/img-json.png',
    );
    expect(metadata.keywords, containsAll(['alpha', 'beta']));
  });

  test('handles @graph and arrays', () async {
    const html =
        '<script type="application/ld+json">'
        '{"@graph": ['
        '{"@type": "WebSite", "name": "Site"},'
        '{"@type": "Article", "headline": "Head"}'
        ']}'
        '</script>';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );
    expect(metadata.title, 'Head');
    expect(metadata.siteName, 'Site');
    expect(metadata.structuredData?.nodes, hasLength(2));
  });

  test('ignores invalid JSON-LD', () async {
    const html = '<script type="application/ld+json">{bad</script>';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );
    expect(metadata.isEmpty, isTrue);
  });

  test('reports malformed JSON-LD as an observable warning', () async {
    const html = '<script type="application/ld+json">{bad</script>';
    final pipeline = ExtractPipeline(stages: const [JsonLdExtractor()]);
    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(
      output.warnings.any(
        (warning) => warning.code == MetaLinkWarningCode.partialParse,
      ),
      isTrue,
    );
  });

  test('enforces finite JSON-LD visit and depth budgets', () async {
    const html =
        '<script type="application/ld+json">'
        '{"outer":{"middle":{"inner":{"@type":"Article","name":"Deep"}}}}'
        '</script>';
    final pipeline = ExtractPipeline(
      stages: const [
        JsonLdExtractor(
          limits: JsonLdTraversalLimits(
            maxNodes: 10,
            maxVisitedValues: 10,
            maxDepth: 1,
          ),
        ),
      ],
    );
    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.title, isNull);
    expect(
      output.warnings.any(
        (warning) =>
            warning.message.contains('configured node, visit, or depth'),
      ),
      isTrue,
    );
  });

  test('bounds queued JSON-LD collection entries by visit budget', () async {
    const html =
        '<script type="application/ld+json">'
        '[{"@type":"Article","name":"A"},'
        '{"@type":"Article","name":"B"},'
        '{"@type":"Article","name":"C"}]'
        '</script>';
    final pipeline = ExtractPipeline(
      stages: const [
        JsonLdExtractor(
          limits: JsonLdTraversalLimits(
            maxNodes: 10,
            maxVisitedValues: 2,
            maxDepth: 10,
          ),
        ),
      ],
    );
    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.structuredData?.nodes.length, lessThanOrEqualTo(1));
    expect(
      output.warnings.any(
        (warning) =>
            warning.message.contains('configured node, visit, or depth'),
      ),
      isTrue,
    );
  });

  test('skips JSON-LD scripts beyond the aggregate decode budget', () async {
    const html =
        '<script type="application/ld+json">'
        '{"@type":"Article","headline":"Too large"}'
        '</script>';
    final pipeline = ExtractPipeline(
      stages: const [
        JsonLdExtractor(limits: JsonLdTraversalLimits(maxJsonCharacters: 16)),
      ],
    );

    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.title, isNull);
    expect(
      output.warnings.any((warning) => warning.message.contains('JSON size')),
      isTrue,
    );
  });

  test(
    'bounds nested derived-field walks independently of node collection',
    () async {
      // Collection visits only the root object and the keyword list, so only
      // the derived-value budget can stop this walk.
      final keywords = [for (var i = 0; i < 20; i++) '"k$i"'].join(',');
      final html =
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Bounded","keywords":[$keywords]}'
          '</script>';
      final pipeline = ExtractPipeline(
        stages: const [
          JsonLdExtractor(limits: JsonLdTraversalLimits(maxDerivedValues: 8)),
        ],
      );

      final output = await pipeline.runLocal(
        page: buildHtmlFetchResult(
          originalUrl: testBaseUrl,
          statusCode: 200,
          bodyText: html,
        ),
        extractOptions: const ExtractOptions(),
      );

      expect(output.metadata.title, 'Bounded');
      expect(output.metadata.keywords.length, lessThan(20));
      expect(output.warnings.map((warning) => warning.message), [
        contains('derived-field traversal'),
      ]);
    },
  );

  test(
    'values deeper than maxDepth are pruned before fields are derived',
    () async {
      // Storage keeps values only down to `maxDepth` below the script root, so
      // the too-deep author is gone before derivation and the collection walk
      // reports the dropped depth.
      final output = await _runLocal(
        '<script type="application/ld+json">'
        '{"@type":"Article","headline":"Bounded",'
        '"author":[[[{"name":"Too deep"}]]]}'
        '</script>',
        stages: const [
          JsonLdExtractor(limits: JsonLdTraversalLimits(maxDepth: 1)),
        ],
      );

      expect(output.metadata.title, 'Bounded');
      expect(output.metadata.author, isNull);
      expect(output.metadata.structuredData!.nodes.single['author'], [null]);
      expect(
        output.warnings.any(
          (warning) =>
              warning.message.contains('configured node, visit, or depth'),
        ),
        isTrue,
      );
    },
  );

  test('equal-relevance JSON-LD nodes retain document order', () async {
    const html =
        '<script type="application/ld+json">'
        '[{"@type":"Article","headline":"First"},'
        '{"@type":"Article","headline":"Second"}]'
        '</script>';

    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.title, 'First');
  });

  test('rejects hostless HTTP URLs from JSON-LD', () async {
    const html =
        '<script type="application/ld+json">'
        '{"@type":"Article","headline":"Hostless",'
        '"url":"https:/canonical","image":"http:image.png"}'
        '</script>';

    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.title, 'Hostless');
    expect(metadata.canonicalUrl, isNull);
    expect(metadata.images, isEmpty);
  });

  test('an out-of-range integer date keeps the rest of the node', () async {
    const html = '''
<script type="application/ld+json">
{"@type": "Article", "headline": "Headline", "datePublished": 99999999999999999,
 "keywords": "alpha, beta", "image": "https://example.com/hero.jpg"}
</script>
''';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.publishedAt, isNull);
    expect(metadata.keywords, containsAll(['alpha', 'beta']));
    expect(
      metadata.images.map((image) => image.url.toString()),
      contains('https://example.com/hero.jpg'),
    );
  });

  test('reads zone-less JSON-LD dates as UTC', () async {
    const html = '''
<script type="application/ld+json">
{"@type": "Article", "headline": "Headline", "datePublished": "2024-01-15"}
</script>
''';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.publishedAt, DateTime.utc(2024, 1, 15));
  });

  group('@id references and repeated definitions', () {
    test(
      'reference stubs do not displace later full node definitions',
      () async {
        final output = await _runLocal(
          readFixture('html/json_ld_yoast_graph.html'),
          documentUrl: _yoastPostUrl,
        );
        final metadata = output.metadata;
        final nodes = metadata.structuredData!.nodes;

        expect(nodes.map((node) => node['@type']).toList(), [
          'Article',
          'Person',
          'WebPage',
          'ImageObject',
          'BreadcrumbList',
          'ListItem',
          'ListItem',
          'WebSite',
          'SearchAction',
          'EntryPoint',
          'Organization',
          'ImageObject',
          'ImageObject',
        ]);
        expect(
          nodes.where((node) => node.length == 1 && node.containsKey('@id')),
          isEmpty,
        );
        expect(metadata.title, 'Sourdough guide');
        expect(metadata.kind, LinkKind.article);
        expect(metadata.description, 'A step-by-step sourdough guide.');
        // The Article's publisher reference resolves to the Organization, and a
        // publisher name takes precedence over the WebSite name.
        expect(metadata.siteName, 'Example Bakery LLC');
        expect(metadata.locale, 'en-US');
        expect(metadata.author, 'Jane Baker');
        expect(metadata.canonicalUrl, _yoastPostUrl);
        expect(output.warnings, isEmpty);
      },
    );

    test('merges repeated @id definitions into the first definition', () async {
      const html =
          '<script type="application/ld+json">'
          '[{"@type":"Article","headline":"Head",'
          '"publisher":{"@id":"https://example.com/#org"}},'
          '{"@type":"Organization","@id":"https://example.com/#org",'
          '"name":"First name"}]'
          '</script>'
          '<script type="application/ld+json">'
          '{"@id":"https://example.com/#org","name":"Second name",'
          '"url":"https://example.com/"}'
          '</script>';

      final output = await _runLocal(html);
      final nodes = output.metadata.structuredData!.nodes;

      expect(nodes, hasLength(2));
      expect(nodes.first['@type'], 'Article');
      expect(nodes.last, {
        '@type': 'Organization',
        '@id': 'https://example.com/#org',
        'name': 'First name',
        'url': 'https://example.com/',
      });
    });

    test('resolves @id image references to the referenced image URL', () async {
      const html =
          '<script type="application/ld+json">'
          '[{"@type":"Article","headline":"Head",'
          '"image":{"@id":"https://example.com/page#primaryimage"}},'
          '{"@type":"ImageObject","@id":"https://example.com/page#primaryimage",'
          '"url":"https://cdn.example.com/hero.jpg",'
          '"contentUrl":"https://cdn.example.com/hero.jpg"}]'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.images.map((image) => image.url.toString()), [
        'https://cdn.example.com/hero.jpg',
      ]);
    });

    test('Yoast-style graphs yield the primary image, not page URLs', () async {
      final metadata = (await _runLocal(
        readFixture('html/json_ld_yoast_graph.html'),
        documentUrl: _yoastPostUrl,
      )).metadata;

      expect(metadata.images.map((image) => image.url.toString()), [
        'https://example.com/uploads/sourdough.jpg',
      ]);
    });

    test('image objects use media URLs, never @id or sameAs', () async {
      const html =
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Head",'
          '"image":{"@type":"ImageObject","@id":"https://example.com/#hero",'
          '"url":"https://example.com/hero.jpg",'
          '"sameAs":"https://social.example/hero"}}'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.images.map((image) => image.url.toString()), [
        'https://example.com/hero.jpg',
      ]);
    });

    test(
      'uses an unresolved @id as an image only without a fragment',
      () async {
        const html =
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"Head","image":['
            '{"@id":"https://cdn.example.com/photo.jpg"},'
            '{"@id":"https://example.com/page#missing"}]}'
            '</script>';

        final metadata = (await _runLocal(html)).metadata;

        expect(metadata.images.map((image) => image.url.toString()), [
          'https://cdn.example.com/photo.jpg',
        ]);
      },
    );
  });

  group('page-describing nodes', () {
    test(
      'organization-only JSON-LD does not replace document fields',
      () async {
        const html =
            '<title>How to bake sourdough bread</title>'
            '<script type="application/ld+json">'
            '{"@type":"Organization","name":"Acme Bakery",'
            '"description":"We bake things.","url":"https://example.com/",'
            '"logo":"https://example.com/logo.png"}'
            '</script>';

        final metadata = (await _runLocal(
          html,
          stages: const [StandardMetaExtractor(), JsonLdExtractor()],
        )).metadata;

        expect(metadata.title, 'How to bake sourdough bread');
        expect(metadata.description, isNull);
        expect(metadata.canonicalUrl, isNull);
        expect(metadata.images, isEmpty);
      },
    );

    test('breadcrumb items do not supply the page title', () async {
      const html =
          '<title>Blue widget - Shop</title>'
          '<script type="application/ld+json">'
          '{"@type":"BreadcrumbList","itemListElement":['
          '{"@type":"ListItem","position":1,"name":"Home",'
          '"item":"https://example.com/"},'
          '{"@type":"ListItem","position":2,"name":"Widgets",'
          '"item":"https://example.com/widgets"},'
          '{"@type":"ListItem","position":3,"name":"Blue widget"}]}'
          '</script>';

      final metadata = (await _runLocal(
        html,
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
      )).metadata;

      expect(metadata.title, 'Blue widget - Shop');
      expect(metadata.structuredData?.nodes, hasLength(4));
    });

    test('primary strength goes to the best page-describing node', () async {
      // The Organization outranks the Article on raw relevance, but only the
      // Article describes the page, so it must receive primary strength and
      // beat the Twitter title.
      const html =
          '<meta name="twitter:title" content="Twitter title">'
          '<script type="application/ld+json">'
          '[{"@type":"Organization","name":"Acme","url":"https://example.com/",'
          '"description":"Org description","image":"https://example.com/o.png"},'
          '{"@type":"Article","headline":"Article headline"}]'
          '</script>';

      final output = await _runLocal(
        html,
        stages: const [TwitterCardExtractor(), JsonLdExtractor()],
      );

      expect(output.metadata.title, 'Article headline');
      expect(
        output.fieldProvenance[MetaField.title]?.source,
        CandidateSource.jsonLd,
      );
    });

    test('a non-page type that matches the page URL describes the page', () async {
      const html =
          '<title>Welcome</title>'
          '<script type="application/ld+json">'
          '{"@type":"Organization","name":"Acme Bakery",'
          '"url":"https://example.com/","logo":"https://example.com/logo.png"}'
          '</script>';

      final metadata = (await _runLocal(
        html,
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
        documentUrl: Uri.parse('https://example.com/'),
      )).metadata;

      expect(metadata.title, 'Acme Bakery');
      expect(metadata.canonicalUrl, Uri.parse('https://example.com/'));
      expect(metadata.images.map((image) => image.url.toString()), [
        'https://example.com/logo.png',
      ]);
    });

    test(
      'image objects named by a page fragment do not describe the page',
      () async {
        const html =
            '<script type="application/ld+json">'
            '[{"@type":"Article","headline":"Head",'
            '"image":{"@id":"https://example.com/page#primaryimage"}},'
            '{"@type":"ImageObject","@id":"https://example.com/page#primaryimage",'
            '"url":"https://cdn.example.com/hero.jpg",'
            '"description":"Hero image description"}]'
            '</script>';

        final metadata = (await _runLocal(html)).metadata;

        expect(metadata.title, 'Head');
        expect(metadata.description, isNull);
        expect(metadata.canonicalUrl, isNull);
      },
    );

    test('non-page nodes keep their site name contribution', () async {
      const html =
          '<script type="application/ld+json">'
          '[{"@type":"WebSite","name":"Graph Site","url":"https://example.com/"},'
          '{"@type":"Article","headline":"Head",'
          '"author":{"@type":"Person","name":"Writer"}}]'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.title, 'Head');
      expect(metadata.siteName, 'Graph Site');
      expect(metadata.author, 'Writer');
      expect(metadata.kind, LinkKind.article);
    });
  });

  group('author and publisher references', () {
    test('resolves an author @id reference to the referenced name', () async {
      const html =
          '<script type="application/ld+json">'
          '{"@context":"https://schema.org","@graph":['
          '{"@type":"Article","@id":"https://example.com/page#article",'
          '"headline":"Head",'
          '"author":{"@id":"https://example.com/#/schema/person/x"},'
          '"mainEntityOfPage":{"@id":"https://example.com/page"}},'
          '{"@type":"Person","@id":"https://example.com/#/schema/person/x",'
          '"name":"Jane Baker","url":"https://example.com/author/jane/"}]}'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.author, 'Jane Baker');
    });

    test('an unresolved author reference yields no author', () async {
      const html =
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Head",'
          '"author":{"@id":"https://example.com/#/schema/person/missing"}}'
          '</script>';

      final output = await _runLocal(html);

      expect(output.metadata.author, isNull);
      expect(output.candidateDecisions[MetaField.author] ?? const [], isEmpty);
    });

    test('an inline author object still supplies its name', () async {
      const html =
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Head",'
          '"author":{"@type":"Person","name":"Inline Writer",'
          '"@id":"https://example.com/#/schema/person/inline"}}'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.author, 'Inline Writer');
    });

    test('resolves a publisher @id reference for the site name', () async {
      const html =
          '<script type="application/ld+json">'
          '[{"@type":"Article","headline":"Head",'
          '"publisher":{"@id":"https://example.com/#organization"}},'
          '{"@type":"Organization","@id":"https://example.com/#organization",'
          '"name":"Acme Publishing"}]'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.siteName, 'Acme Publishing');
    });

    test('an unresolved publisher reference yields no site name', () async {
      const html =
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Head",'
          '"publisher":{"@id":"https://example.com/#organization"}}'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.siteName, isNull);
    });
  });

  group('generic WebPage kind', () {
    test('og:type wins over a WebPage-only graph', () async {
      const html =
          '<meta property="og:type" content="article">'
          '<script type="application/ld+json">'
          '{"@type":"WebPage","url":"https://example.com/page","name":"Page"}'
          '</script>';

      final metadata = (await _runLocal(
        html,
        stages: const [OpenGraphExtractor(), JsonLdExtractor()],
      )).metadata;

      expect(metadata.kind, LinkKind.article);
    });

    test('a plain WebPage does not outrank a more specific JSON-LD type', () async {
      // The URL-matched WebPage takes primary strength, while the Article
      // only describes the page by type and receives secondary strength.
      const html =
          '<script type="application/ld+json">'
          '[{"@type":"WebPage","url":"https://example.com/page","name":"Page"},'
          '{"@type":"Article","headline":"Head"}]'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.kind, LinkKind.article);
    });

    test(
      'a WebPage-only page without other signals keeps the generic kind',
      () async {
        const html =
            '<title>Plain page</title>'
            '<script type="application/ld+json">'
            '{"@type":"WebPage","url":"https://example.com/page","name":"Page"}'
            '</script>';

        final metadata = (await _runLocal(
          html,
          stages: const [
            OpenGraphExtractor(),
            StandardMetaExtractor(),
            JsonLdExtractor(),
          ],
        )).metadata;

        expect(metadata.kind, LinkKind.other);
      },
    );

    test('WebPage subtypes keep their specific kinds', () async {
      for (final entry in const {
        'ProfilePage': LinkKind.profile,
        'CollectionPage': LinkKind.gallery,
        'ImageGallery': LinkKind.gallery,
      }.entries) {
        final metadata = (await _runLocal(
          '<script type="application/ld+json">'
          '{"@type":"${entry.key}","url":"https://example.com/page"}'
          '</script>',
        )).metadata;

        expect(metadata.kind, entry.value, reason: entry.key);
      }
    });
  });

  group('JSON-LD script budgets', () {
    test(
      'an exactly filled node budget ignores later non-JSON-LD scripts',
      () async {
        const html =
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"Only"}'
            '</script>'
            '<script src="app.js"></script>';

        final output = await _runLocal(
          html,
          stages: const [
            JsonLdExtractor(limits: JsonLdTraversalLimits(maxNodes: 1)),
          ],
        );

        expect(output.metadata.title, 'Only');
        expect(output.warnings, isEmpty);
      },
    );

    test(
      'a filled node budget still reports skipped JSON-LD scripts',
      () async {
        const html =
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"First"}'
            '</script>'
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"Second"}'
            '</script>'
            '<script src="app.js"></script>';

        final output = await _runLocal(
          html,
          stages: const [
            JsonLdExtractor(limits: JsonLdTraversalLimits(maxNodes: 1)),
          ],
        );

        expect(output.metadata.title, 'First');
        expect(
          output.warnings.any(
            (warning) =>
                warning.message.contains('configured node, visit, or depth'),
          ),
          isTrue,
        );
      },
    );

    test(
      'an oversized script does not suppress later scripts that fit',
      () async {
        final html =
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"${'x' * 200}"}'
            '</script>'
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"Small"}'
            '</script>';

        final output = await _runLocal(
          html,
          stages: const [
            JsonLdExtractor(
              limits: JsonLdTraversalLimits(maxJsonCharacters: 100),
            ),
          ],
        );

        expect(output.metadata.title, 'Small');
        expect(
          output.warnings.any(
            (warning) => warning.message.contains('JSON size'),
          ),
          isTrue,
        );
      },
    );
  });

  group('page-describing rules', () {
    test('FAQ questions do not replace the FAQ page title', () async {
      final metadata = (await _runLocal(
        '<title>Shipping FAQ | Shop</title>'
        '<script type="application/ld+json">'
        '{"@context":"https://schema.org","@type":"FAQPage","mainEntity":['
        '{"@type":"Question","name":"How long does shipping take?",'
        '"acceptedAnswer":{"@type":"Answer","text":"Three days."}},'
        '{"@type":"Question","name":"Do you ship abroad?",'
        '"acceptedAnswer":{"@type":"Answer","text":"Yes."}}]}'
        '</script>',
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
      )).metadata;

      expect(metadata.title, 'Shipping FAQ | Shop');
    });

    test('a course instance does not replace its course', () async {
      final metadata = (await _runLocal(
        '<title>Intro to X | Academy</title>'
        '<script type="application/ld+json">'
        '{"@context":"https://schema.org","@type":"Course",'
        '"name":"Intro to X","description":"Learn X.",'
        '"provider":{"@type":"Organization","name":"Academy"},'
        '"hasCourseInstance":[{"@type":"CourseInstance",'
        '"name":"Spring cohort","courseMode":"Online",'
        '"startDate":"2025-03-01"}]}'
        '</script>',
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
      )).metadata;

      expect(metadata.title, 'Intro to X');
      expect(metadata.description, 'Learn X.');
      expect(metadata.kind, isNot(LinkKind.event));
    });

    test(
      'a comment with a fragment URL takes no primary, author, or date',
      () async {
        const comment =
            '{"@type":"Comment","url":"https://example.com/page#comment-1",'
            '"text":"Nice post","author":{"@type":"Person","name":"Commenter"},'
            '"datePublished":"2024-05-01T00:00:00Z"}';

        final withPostFields = (await _runLocal(
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Post headline",'
          '"author":{"@type":"Person","name":"Post Author"},'
          '"datePublished":"2024-01-01T00:00:00Z","comment":[$comment]}'
          '</script>',
        )).metadata;
        expect(withPostFields.title, 'Post headline');
        expect(withPostFields.author, 'Post Author');
        expect(withPostFields.publishedAt, DateTime.utc(2024));

        final withoutPostFields = (await _runLocal(
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Post headline","comment":[$comment]}'
          '</script>',
        )).metadata;
        expect(withoutPostFields.author, isNull);
        expect(withoutPostFields.publishedAt, isNull);
      },
    );

    test('ItemList entries with their own URLs do not describe a listing page', () async {
      const html =
          '<title>World news - Example News</title>'
          '<script type="application/ld+json">'
          '{"@type":"ItemList","itemListElement":['
          '{"@type":"ListItem","position":1,"item":{"@type":"NewsArticle",'
          '"url":"https://example.com/news/story-1","headline":"Story one",'
          '"datePublished":"2024-02-01T00:00:00Z",'
          '"author":{"name":"Reporter One"}}},'
          '{"@type":"ListItem","position":2,"item":{"@type":"NewsArticle",'
          '"url":"https://example.com/news/story-2","headline":"Story two"}}]}'
          '</script>';

      final metadata = (await _runLocal(
        html,
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
        documentUrl: Uri.parse('https://example.com/news/world'),
      )).metadata;

      expect(metadata.title, 'World news - Example News');
      expect(metadata.canonicalUrl, isNull);
      expect(metadata.kind, LinkKind.unknown);
      expect(metadata.author, isNull);
      expect(metadata.publishedAt, isNull);
    });

    test('a page-like node whose mainEntityOfPage names another page does not describe this page', () async {
      const html =
          '<title>Document title</title>'
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Other story",'
          '"mainEntityOfPage":"https://example.com/other"}'
          '</script>';

      final metadata = (await _runLocal(
        html,
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
      )).metadata;

      expect(metadata.title, 'Document title');
      expect(metadata.kind, LinkKind.unknown);
    });

    test('structural nodes never describe the page, even at its URL', () async {
      const html =
          '<title>About us - Acme</title>'
          '<script type="application/ld+json">'
          '[{"@type":"SiteNavigationElement","name":"About",'
          '"url":"https://example.com/page"},'
          '{"@type":"ImageObject","url":"https://example.com/page",'
          '"description":"Image caption text"},'
          '{"@type":"Offer","url":"https://example.com/page","price":"10"}]'
          '</script>';

      final metadata = (await _runLocal(
        html,
        stages: const [StandardMetaExtractor(), JsonLdExtractor()],
      )).metadata;

      expect(metadata.title, 'About us - Acme');
      expect(metadata.description, isNull);
      expect(metadata.canonicalUrl, isNull);
      expect(metadata.kind, LinkKind.unknown);
    });

    for (final breadcrumbFirst in [true, false]) {
      test('a breadcrumb leaf does not rename the WebPage '
          '(breadcrumb ${breadcrumbFirst ? 'first' : 'last'})', () async {
        const breadcrumb =
            '{"@type":"BreadcrumbList","itemListElement":['
            '{"@type":"ListItem","position":1,'
            '"item":{"@id":"https://example.com/","name":"Home"}},'
            '{"@type":"ListItem","position":2,'
            '"item":{"@id":"https://example.com/page","name":"Leaf"}}]}';
        const webPage =
            '{"@type":"WebPage","@id":"https://example.com/page",'
            '"url":"https://example.com/page","name":"Real page title"}';
        final graph = breadcrumbFirst
            ? '[$breadcrumb,$webPage]'
            : '[$webPage,$breadcrumb]';

        final metadata = (await _runLocal(
          '<script type="application/ld+json">$graph</script>',
        )).metadata;
        final pageNode = metadata.structuredData!.nodes.singleWhere(
          (node) => node['@id'] == 'https://example.com/page',
        );

        expect(metadata.title, 'Real page title');
        expect(pageNode['@type'], 'WebPage');
        expect(pageNode['name'], 'Real page title');
      });
    }

    test('identity URLs without a trailing slash match the homepage', () async {
      for (final (documentUrl, nodeUrl) in [
        ('https://example.com/', 'https://example.com'),
        ('https://example.com', 'https://example.com/'),
      ]) {
        final metadata = (await _runLocal(
          '<title>Welcome</title>'
          '<script type="application/ld+json">'
          '{"@type":"Organization","name":"Acme Bakery","url":"$nodeUrl"}'
          '</script>',
          stages: const [StandardMetaExtractor(), JsonLdExtractor()],
          documentUrl: Uri.parse(documentUrl),
        )).metadata;

        expect(metadata.title, 'Acme Bakery', reason: documentUrl);
      }
    });

    test(
      'trailing-slash and www variants of the page URL name this page',
      () async {
        for (final (documentUrl, nodeUrl) in [
          ('https://example.com/post', 'https://example.com/post/'),
          ('https://example.com/post/', 'https://example.com/post'),
          ('https://example.com/post', 'https://www.example.com/post/'),
          ('https://www.example.com/post', 'https://example.com/post'),
        ]) {
          final metadata = (await _runLocal(
            '<title>Document title</title>'
            '<script type="application/ld+json">'
            '{"@type":"Article","headline":"Story","url":"$nodeUrl",'
            '"author":{"@type":"Person","name":"Writer"}}'
            '</script>',
            stages: const [StandardMetaExtractor(), JsonLdExtractor()],
            documentUrl: Uri.parse(documentUrl),
          )).metadata;

          final reason = '$documentUrl vs $nodeUrl';
          expect(metadata.title, 'Story', reason: reason);
          expect(metadata.author, 'Writer', reason: reason);
        }
      },
    );

    test(
      'the page canonical link or og:url keeps its article from being foreign',
      () async {
        for (final declaration in [
          '<link rel="canonical" href="https://example.com/post/">',
          '<link rel="CANONICAL" href="/post/">',
          '<meta property="og:url" content="https://example.com/post/">',
        ]) {
          final metadata = (await _runLocal(
            '<title>AMP title</title>$declaration'
            '<script type="application/ld+json">'
            '{"@type":"NewsArticle","headline":"Story",'
            '"mainEntityOfPage":"https://example.com/post/",'
            '"image":"https://example.com/story.jpg"}'
            '</script>',
            stages: const [StandardMetaExtractor(), JsonLdExtractor()],
            documentUrl: Uri.parse('https://example.com/post/amp/'),
          )).metadata;

          expect(metadata.title, 'Story', reason: declaration);
          expect(metadata.images.map((image) => image.url.toString()), [
            'https://example.com/story.jpg',
          ], reason: declaration);
        }
      },
    );

    test(
      'a declared canonical never makes a non-page-like node describe the page',
      () async {
        final metadata = (await _runLocal(
          '<title>Article title</title>'
          '<link rel="canonical" href="https://example.com/">'
          '<meta property="og:url" content="https://example.com/">'
          '<script type="application/ld+json">'
          '{"@type":"Organization","name":"Acme","url":"https://example.com/"}'
          '</script>',
          stages: const [StandardMetaExtractor(), JsonLdExtractor()],
          documentUrl: Uri.parse('https://example.com/post'),
        )).metadata;

        expect(metadata.title, 'Article title');
      },
    );

    test(
      'a listing story stays foreign when the page declares a canonical',
      () async {
        final metadata = (await _runLocal(
          '<title>Latest news</title>'
          '<link rel="canonical" href="https://www.example.com/">'
          '<script type="application/ld+json">'
          '{"@type":"NewsArticle","headline":"Story one",'
          '"url":"https://www.example.com/story-1"}'
          '</script>',
          stages: const [StandardMetaExtractor(), JsonLdExtractor()],
          documentUrl: Uri.parse('https://example.com/'),
        )).metadata;

        expect(metadata.title, 'Latest news');
      },
    );
  });

  group('stored node depth', () {
    test(
      'deeply nested values are pruned so structured data serializes',
      () async {
        final output = await _runLocal(_deepJsonLdHtml);

        expect(output.metadata.title, 'Deep');
        expect(() => jsonEncode(output.metadata.toJson()), returnsNormally);
        expect(
          output.warnings.any(
            (warning) =>
                warning.message.contains('configured node, visit, or depth'),
          ),
          isTrue,
        );
      },
    );

    test('deeply nested values are cached through the client', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/deep');
      fetcher.registerGetResponse(
        url,
        FakeFetcher.buildResponse(
          url: url,
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText: _deepJsonLdHtml,
        ),
      );
      final client = MetaLinkClient(
        fetcher: fetcher,
        cacheStore: MemoryCacheStore(),
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
        ),
      );
      addTearDown(client.dispose);

      final first = await client.extract(url.toString());
      final second = await client.extract(url.toString());

      expect(
        first.warnings.where(
          (warning) => warning.code == MetaLinkWarningCode.cacheWriteFailed,
        ),
        isEmpty,
      );
      expect(second.diagnostics.cacheHit, isTrue);
      expect(second.metadata.title, 'Deep');
    });
  });

  group('limit warnings at exact limits', () {
    Future<PipelineOutput> runWith(String json, JsonLdTraversalLimits limits) {
      return _runLocal(
        '<script type="application/ld+json">$json</script>',
        stages: [JsonLdExtractor(limits: limits)],
      );
    }

    test('a flat node within a one-value visit budget', () async {
      final output = await runWith(
        '{"@type":"Article","headline":"Flat"}',
        const JsonLdTraversalLimits(maxVisitedValues: 1),
      );
      expect(output.metadata.title, 'Flat');
      expect(output.warnings, isEmpty);
    });

    test('a flat root at depth zero', () async {
      final output = await runWith(
        '{"@type":"Article","headline":"Flat"}',
        const JsonLdTraversalLimits(maxDepth: 0),
      );
      expect(output.metadata.title, 'Flat');
      expect(output.warnings, isEmpty);
    });

    test('a flat graph node at the depth limit', () async {
      final output = await runWith(
        '{"@graph":[{"@type":"Article","headline":"Flat"}]}',
        const JsonLdTraversalLimits(maxDepth: 2),
      );
      expect(output.metadata.title, 'Flat');
      expect(output.warnings, isEmpty);
    });

    test('an empty list at the default depth limit', () async {
      final output = await runWith(
        '{"@type":"Article","headline":"Deep","x":${'[' * 64}${']' * 64}}',
        const JsonLdTraversalLimits(),
      );
      expect(output.metadata.title, 'Deep');
      expect(output.warnings, isEmpty);
    });

    test('a non-empty list beyond the depth limit still warns', () async {
      final output = await runWith(
        '{"@type":"Article","headline":"Deep","x":${'[' * 66}${']' * 66}}',
        const JsonLdTraversalLimits(),
      );
      expect(output.warnings, isNotEmpty);
    });

    String graphOf(int count) =>
        '{"@graph":[${[for (var i = 0; i < count; i++) '{"@type":"Thing","name":"N$i","keywords":["a"]}'].join(',')}]}';

    test('exactly the node budget with trailing scalar lists', () async {
      final output = await runWith(graphOf(250), const JsonLdTraversalLimits());
      expect(output.metadata.structuredData?.nodes, hasLength(250));
      expect(output.warnings, isEmpty);
    });

    test('one node beyond the node budget still warns', () async {
      final output = await runWith(graphOf(251), const JsonLdTraversalLimits());
      expect(output.metadata.structuredData?.nodes, hasLength(250));
      expect(output.warnings, isNotEmpty);
    });
  });

  group('array-valued publisher', () {
    test('resolves publisher references entry by entry', () async {
      const html =
          '<script type="application/ld+json">'
          '[{"@type":"Article","headline":"Head","publisher":['
          '{"@id":"https://example.com/#missing"},'
          '{"@id":"https://example.com/#organization"}]},'
          '{"@type":"Organization","@id":"https://example.com/#organization",'
          '"name":"Acme Publishing"}]'
          '</script>';

      final metadata = (await _runLocal(html)).metadata;

      expect(metadata.siteName, 'Acme Publishing');
    });
  });

  group('relative identity URLs', () {
    test('resolve against <base href> before matching the page', () async {
      final metadata = (await _runLocal(
        '<html><head><title>Site | Post</title><base href="https://e.com/">'
        '<script type="application/ld+json">{"@type":"BlogPosting",'
        '"url":"2024/01/post","headline":"Post headline",'
        '"datePublished":"2024-01-02T00:00:00Z","image":"img/hero.jpg"}'
        '</script></head><body></body></html>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://e.com/2024/01/post'),
      )).metadata;

      expect(metadata.title, 'Post headline');
      expect(metadata.kind, LinkKind.article);
      expect(metadata.publishedAt, DateTime.utc(2024, 1, 2));
      expect(metadata.images.map((image) => image.url.toString()), [
        'https://e.com/img/hero.jpg',
      ]);
      expect(metadata.canonicalUrl, Uri.parse('https://e.com/2024/01/post'));
    });
  });

  group('query-aware page identity', () {
    test('a sibling URL with another query is a foreign document', () async {
      final metadata = (await _runLocal(
        '<title>Help with my engine - Forum</title>'
        '<script type="application/ld+json">[{"@type":"DiscussionForumPosting",'
        '"headline":"Help with my engine",'
        '"url":"https://forum.example.com/viewtopic.php?t=100"},'
        '{"@type":"Article","headline":"Oil change tips",'
        '"url":"https://forum.example.com/viewtopic.php?t=7",'
        '"author":{"@type":"Person","name":"Someone else"},'
        '"datePublished":"2010-01-01T00:00:00Z"}]</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://forum.example.com/viewtopic.php?t=100'),
      )).metadata;

      expect(metadata.title, 'Help with my engine');
      expect(metadata.author, isNull);
      expect(metadata.publishedAt, isNull);
      expect(
        metadata.canonicalUrl,
        Uri.parse('https://forum.example.com/viewtopic.php?t=100'),
      );
    });

    test('a sitewide WebSite does not describe a query-routed post', () async {
      final metadata = (await _runLocal(
        '<title>How to bake bread</title>'
        '<meta name="description" content="A bread recipe post.">'
        '<script type="application/ld+json">{"@type":"WebSite",'
        '"url":"https://example.com/","name":"Bob\'s Blog",'
        '"description":"Just another WordPress site"}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://example.com/?p=42'),
      )).metadata;

      expect(metadata.title, 'How to bake bread');
      expect(metadata.description, 'A bread recipe post.');
      expect(metadata.siteName, "Bob's Blog");
      expect(metadata.kind, isNot(LinkKind.homepage));
    });

    test('product variants with their own query are not the page', () async {
      final metadata = (await _runLocal(
        '<meta property="og:url" content="https://shop.example.com/coat">'
        '<title>Wool coat | Shop</title>'
        '<script type="application/ld+json">{"@type":"ProductGroup",'
        '"name":"Wool coat","description":"Warm wool coat",'
        '"url":"https://shop.example.com/coat","hasVariant":['
        '{"@type":"Product","name":"Wool coat - red",'
        '"description":"Red wool coat",'
        '"url":"https://shop.example.com/coat?color=red"},'
        '{"@type":"Product","name":"Wool coat - blue",'
        '"url":"https://shop.example.com/coat?color=blue"}]}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://shop.example.com/coat'),
      )).metadata;

      expect(metadata.title, 'Wool coat');
      expect(metadata.description, 'Warm wool coat');
      expect(metadata.canonicalUrl, Uri.parse('https://shop.example.com/coat'));
      expect(metadata.kind, LinkKind.product);
    });

    test('tracking parameters on the fetched URL keep the article', () async {
      final metadata = (await _runLocal(
        '<title>Document title</title>'
        '<script type="application/ld+json">{"@type":"Article",'
        '"headline":"Story","url":"https://example.com/post",'
        '"author":{"@type":"Person","name":"Writer"},'
        '"datePublished":"2024-01-01T00:00:00Z"}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse(
          'https://example.com/post?utm_source=x&fbclid=y',
        ),
      )).metadata;

      expect(metadata.title, 'Story');
      expect(metadata.author, 'Writer');
      expect(metadata.publishedAt, DateTime.utc(2024));
    });

    test('a URL with a subset of the page query keeps the posting', () async {
      final metadata = (await _runLocal(
        '<title>Forum</title>'
        '<script type="application/ld+json">{"@type":"DiscussionForumPosting",'
        '"headline":"Help with my engine",'
        '"url":"https://forum.example.com/viewtopic.php?t=100",'
        '"author":{"@type":"Person","name":"op"}}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse(
          'https://forum.example.com/viewtopic.php?t=100&sid=abc',
        ),
      )).metadata;

      expect(metadata.title, 'Help with my engine');
      expect(metadata.author, 'op');
    });

    test('query parameter order does not change page identity', () async {
      final metadata = (await _runLocal(
        '<title>Document title</title>'
        '<script type="application/ld+json">[{"@type":"WebPage",'
        '"url":"https://example.com/view?b=2&a=1&a=0","name":"Page name"},'
        '{"@type":"Thing","name":"Other"}]</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://example.com/view?a=0&a=1&b=2'),
      )).metadata;

      expect(metadata.title, 'Page name');
    });
  });

  group('schema.org subtypes', () {
    test('an OpinionNewsArticle-only page keeps its fields', () async {
      final metadata = (await _runLocal(
        '<title>Why X matters | Opinion | News Co</title>'
        '<script type="application/ld+json">{"@type":"OpinionNewsArticle",'
        '"headline":"Why X matters","description":"A column about X",'
        '"image":"https://news.example.com/img/x.jpg","inLanguage":"en-GB"}'
        '</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://news.example.com/opinion/why-x'),
      )).metadata;

      expect(metadata.title, 'Why X matters');
      expect(metadata.description, 'A column about X');
      expect(metadata.images.map((image) => image.url.toString()), [
        'https://news.example.com/img/x.jpg',
      ]);
      expect(metadata.locale, 'en-GB');
    });

    test('HowTo and DiscussionForumPosting pages describe the page', () async {
      for (final type in ['HowTo', 'DiscussionForumPosting']) {
        final metadata = (await _runLocal(
          '<title>Document title</title>'
          '<script type="application/ld+json">{"@type":"$type",'
          '"name":"Node title","description":"Node description"}</script>',
          stages: _metaStages,
        )).metadata;

        expect(metadata.title, 'Node title', reason: type);
        expect(metadata.description, 'Node description', reason: type);
      }
    });

    test('listed OpinionNewsArticle stories leak no context', () async {
      final metadata = (await _runLocal(
        '<meta property="og:title" content="Opinion">'
        '<script type="application/ld+json">{"@type":"ItemList",'
        '"itemListElement":[{"@type":"ListItem","position":1,'
        '"item":{"@type":"OpinionNewsArticle",'
        '"url":"https://news.example.com/opinion/why-x","headline":"Why X",'
        '"author":{"@type":"Person","name":"Columnist A"},'
        '"datePublished":"2024-05-01T10:00:00Z","keywords":"x,policy",'
        '"publisher":{"@type":"Organization","name":"Syndicate Partner"}}}]}'
        '</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://news.example.com/opinion/'),
      )).metadata;

      expect(metadata.title, 'Opinion');
      expect(metadata.author, isNull);
      expect(metadata.publishedAt, isNull);
      expect(metadata.siteName, isNull);
      expect(metadata.keywords, isEmpty);
    });

    test('an OpinionNewsArticle page has the NewsArticle kind', () async {
      Future<LinkKind> kindOf(String type) async => (await _runLocal(
        '<script type="application/ld+json">'
        '{"@type":"$type","headline":"Story"}</script>',
      )).metadata.kind;

      expect(await kindOf('NewsArticle'), LinkKind.article);
      expect(await kindOf('OpinionNewsArticle'), await kindOf('NewsArticle'));
    });
  });

  group('untyped nodes', () {
    test(
      'a breadcrumb item at the page URL does not supply the title',
      () async {
        final metadata = (await _runLocal(
          '<title>My Great Post Title | Blog</title>'
          '<script type="application/ld+json">{"@type":"BlogPosting",'
          '"headline":"My Great Post Title"}</script>'
          '<script type="application/ld+json">{"@type":"BreadcrumbList",'
          '"itemListElement":[{"@type":"ListItem","position":1,'
          '"item":{"@id":"https://example.com/","name":"Home"}},'
          '{"@type":"ListItem","position":2,'
          '"item":{"@id":"https://example.com/blog/post-1","name":"Post 1"}}]}'
          '</script>',
          stages: _metaStages,
          documentUrl: Uri.parse('https://example.com/blog/post-1'),
        )).metadata;

        expect(metadata.title, 'My Great Post Title');
      },
    );

    test(
      'an untyped graph node at the page URL does not describe it',
      () async {
        final metadata = (await _runLocal(
          '<title>My Great Post Title | Blog</title>'
          '<script type="application/ld+json">{"@graph":['
          '{"@type":"BlogPosting","headline":"My Great Post Title"},'
          '{"@id":"https://example.com/blog/post-1","name":"Leaf",'
          '"description":"Leaf description"}]}</script>',
          stages: _metaStages,
          documentUrl: Uri.parse('https://example.com/blog/post-1'),
        )).metadata;

        expect(metadata.title, 'My Great Post Title');
        expect(metadata.description, isNull);
        expect(metadata.canonicalUrl, isNull);
      },
    );
  });

  group('nested nodes', () {
    test('recipes in a same-page ItemList do not describe the page', () async {
      final metadata = (await _runLocal(
        '<title>Dessert recipes | Example</title>'
        '<script type="application/ld+json">{"@type":"ItemList",'
        '"itemListElement":[{"@type":"ListItem","position":1,'
        '"item":{"@type":"Recipe",'
        '"url":"https://example.com/dessert-recipes/#cherry-pie",'
        '"name":"Cherry pie","image":"https://example.com/photos/cherry.jpg",'
        '"author":{"@type":"Person","name":"Mary Stone"},'
        '"datePublished":"2018-03-10"}},'
        '{"@type":"ListItem","position":2,"item":{"@type":"Recipe",'
        '"url":"https://example.com/dessert-recipes/#apple-pie",'
        '"name":"Apple pie"}}]}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://example.com/dessert-recipes/'),
      )).metadata;

      expect(metadata.title, 'Dessert recipes | Example');
      expect(metadata.author, isNull);
      expect(metadata.publishedAt, isNull);
      expect(metadata.images, isEmpty);
    });

    test('nested reviews supply no author or date', () async {
      final metadata = (await _runLocal(
        '<title>Trail shoe | Shop</title>'
        '<script type="application/ld+json">{"@type":"Product",'
        '"name":"Trail shoe","url":"https://example.com/shoe",'
        '"review":[{"@type":"Review","name":"Great shoe",'
        '"reviewBody":"Comfortable.",'
        '"author":{"@type":"Person","name":"Reviewer A"},'
        '"datePublished":"2023-05-01"}]}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://example.com/shoe'),
      )).metadata;

      expect(metadata.title, 'Trail shoe');
      expect(metadata.author, isNull);
      expect(metadata.publishedAt, isNull);
    });

    test('listed videos add no page videos', () async {
      final metadata = (await _runLocal(
        '<meta property="og:title" content="Cats channel">'
        '<script type="application/ld+json">{"@type":"ItemList",'
        '"itemListElement":[{"@type":"ListItem","position":1,'
        '"item":{"@type":"VideoObject","url":"https://video.example.com/v/1",'
        '"name":"Cat 1","thumbnailUrl":"https://video.example.com/t/1.jpg",'
        '"contentUrl":"https://cdn.video.example.com/1.mp4"}}]}</script>',
        stages: _metaStages,
        documentUrl: Uri.parse('https://video.example.com/channel/cats'),
      )).metadata;

      expect(metadata.title, 'Cats channel');
      expect(metadata.videos, isEmpty);
      expect(metadata.images, isEmpty);
    });

    test('an embedded article video still adds its video', () async {
      final metadata = (await _runLocal(
        '<script type="application/ld+json">{"@type":"Article",'
        '"headline":"Story","video":{"@type":"VideoObject","name":"Clip",'
        '"url":"https://www.youtube.com/watch?v=abc",'
        '"embedUrl":"https://www.youtube.com/embed/abc",'
        '"thumbnailUrl":"https://i.ytimg.com/vi/abc/hq.jpg",'
        '"uploadDate":"2020-01-01"}}</script>',
      )).metadata;

      expect(metadata.title, 'Story');
      expect(metadata.videos.map((video) => video.url.toString()), [
        'https://www.youtube.com/embed/abc',
      ]);
      expect(metadata.publishedAt, isNull);
    });

    test('a later top-level definition un-nests a listed node', () async {
      final metadata = (await _runLocal(
        '<title>Document title</title>'
        '<script type="application/ld+json">[{"@type":"ItemList",'
        '"itemListElement":[{"@type":"ListItem","position":1,'
        '"item":{"@id":"https://example.com/#post","name":"Listed name"}}]},'
        '{"@type":"Article","@id":"https://example.com/#post",'
        '"headline":"Story","author":{"@type":"Person","name":"Writer"}}]'
        '</script>',
        stages: _metaStages,
      )).metadata;

      expect(metadata.title, 'Story');
      expect(metadata.author, 'Writer');
    });

    test('a Rank Math graph keeps its fields', () async {
      final output = await _runLocal(
        _rankMathGraphHtml,
        stages: _metaStages,
        documentUrl: Uri.parse('https://example.com/post/'),
      );
      final metadata = output.metadata;

      expect(metadata.title, 'Post title');
      expect(metadata.description, 'Post description');
      expect(metadata.kind, LinkKind.article);
      expect(metadata.author, 'Jane');
      expect(metadata.siteName, 'Site Owner');
      expect(metadata.locale, 'en-US');
      expect(metadata.publishedAt, DateTime.utc(2024, 1, 2, 10));
      expect(metadata.images.map((image) => image.url.toString()), [
        'https://example.com/hero.jpg',
      ]);
      expect(output.warnings, isEmpty);
    });
  });

  group('visit budget used exactly', () {
    Future<PipelineOutput> runScripts(List<String> scripts) => _runLocal(
      [
        for (final script in scripts)
          '<script type="application/ld+json">$script</script>',
      ].join(),
      stages: const [
        JsonLdExtractor(limits: JsonLdTraversalLimits(maxVisitedValues: 1)),
      ],
    );

    for (final empty in ['{}', '[]']) {
      test('a later empty script $empty is not reported', () async {
        final output = await runScripts([
          '{"@type":"Article","headline":"Flat"}',
          empty,
        ]);

        expect(output.metadata.title, 'Flat');
        expect(output.warnings, isEmpty);
      });
    }

    test('a later non-empty script is still reported', () async {
      final output = await runScripts([
        '{"@type":"Article","headline":"Flat"}',
        '{"@type":"Article","headline":"Unread"}',
      ]);

      expect(output.metadata.title, 'Flat');
      expect(
        output.warnings.any(
          (warning) =>
              warning.message.contains('configured node, visit, or depth'),
        ),
        isTrue,
      );
    });
  });
}

const List<HtmlMetadataExtractorStage> _metaStages = [
  OpenGraphExtractor(),
  StandardMetaExtractor(),
  JsonLdExtractor(),
];

const String _rankMathGraphHtml =
    '<script type="application/ld+json">{"@context":"https://schema.org",'
    '"@graph":[{"@type":["Person","Organization"],'
    '"@id":"https://example.com/#person","name":"Site Owner",'
    '"logo":{"@type":"ImageObject","@id":"https://example.com/#logo",'
    '"url":"https://example.com/logo.png"}},'
    '{"@type":"WebSite","@id":"https://example.com/#website",'
    '"url":"https://example.com","name":"Example Site",'
    '"publisher":{"@id":"https://example.com/#person"},"inLanguage":"en-US"},'
    '{"@type":"ImageObject","@id":"https://example.com/hero.jpg",'
    '"url":"https://example.com/hero.jpg","width":"1200","height":"630"},'
    '{"@type":"BreadcrumbList","@id":"https://example.com/post/#breadcrumb",'
    '"itemListElement":[{"@type":"ListItem","position":"1",'
    '"item":{"@id":"https://example.com","name":"Home"}},'
    '{"@type":"ListItem","position":"2",'
    '"item":{"@id":"https://example.com/post/","name":"Post"}}]},'
    '{"@type":"WebPage","@id":"https://example.com/post/#webpage",'
    '"url":"https://example.com/post/","name":"Post title - Example Site",'
    '"datePublished":"2024-01-02T10:00:00+00:00",'
    '"isPartOf":{"@id":"https://example.com/#website"},'
    '"primaryImageOfPage":{"@id":"https://example.com/hero.jpg"},'
    '"inLanguage":"en-US",'
    '"breadcrumb":{"@id":"https://example.com/post/#breadcrumb"}},'
    '{"@type":"Person","@id":"https://example.com/author/jane/",'
    '"name":"Jane","url":"https://example.com/author/jane/",'
    '"image":{"@type":"ImageObject",'
    '"@id":"https://secure.gravatar.com/avatar/x",'
    '"url":"https://secure.gravatar.com/avatar/x","caption":"Jane"}},'
    '{"@type":"BlogPosting","headline":"Post title",'
    '"datePublished":"2024-01-02T10:00:00+00:00",'
    '"author":{"@id":"https://example.com/author/jane/","name":"Jane"},'
    '"publisher":{"@id":"https://example.com/#person"},'
    '"description":"Post description","name":"Post title",'
    '"@id":"https://example.com/post/#richSnippet",'
    '"isPartOf":{"@id":"https://example.com/post/#webpage"},'
    '"image":{"@id":"https://example.com/hero.jpg"},"inLanguage":"en-US",'
    '"mainEntityOfPage":{"@id":"https://example.com/post/#webpage"}}]}'
    '</script>';

final String _deepJsonLdHtml =
    '<script type="application/ld+json">'
    '{"@type":"Article","headline":"Deep",'
    '"x":${'[' * 20000}${']' * 20000}}'
    '</script>';

final Uri _yoastPostUrl = Uri.parse(
  'https://example.com/2024/sourdough-guide/',
);

Future<PipelineOutput> _runLocal(
  String html, {
  List<HtmlMetadataExtractorStage> stages = const [JsonLdExtractor()],
  Uri? documentUrl,
}) {
  return ExtractPipeline(stages: stages).runLocal(
    page: buildHtmlFetchResult(
      originalUrl: documentUrl ?? testBaseUrl,
      statusCode: 200,
      bodyText: html,
    ),
    extractOptions: const ExtractOptions(),
  );
}
