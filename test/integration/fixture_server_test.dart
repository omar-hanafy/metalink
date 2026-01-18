import 'package:metalink/metalink.dart';
import 'package:test/test.dart';

import '../support/fixture_server.dart';

void main() {
  group('fixture server integration', tags: ['integration'], () {
    late FixtureServer server;

    const enrichOptions = MetaLinkClientOptions(
      extract: ExtractOptions(
        enableOEmbed: true,
        enableManifest: true,
      ),
    );

    bool hasWarning(
      ExtractionResult<LinkMetadata> result,
      MetaLinkWarningCode code,
    ) {
      return result.warnings.any((w) => w.code == code);
    }

    bool hasError(
      ExtractionResult<LinkMetadata> result,
      MetaLinkErrorCode code,
    ) {
      return result.errors.any((e) => e.code == code);
    }

    Future<ExtractionResult<LinkMetadata>> extract(
      String path, {
      MetaLinkClientOptions options = enrichOptions,
    }) {
      return MetaLink.extract(server.uri(path).toString(), options: options);
    }

    setUpAll(() async {
      server = await FixtureServer.start();
    });

    tearDownAll(() async {
      await server.close();
    });

    test('OG rich page extracts media, dates, and tags', () async {
      final result = await extract('/page/og-rich');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, 'OG Rich Title');
      expect(result.metadata.description, 'OG Rich Description');
      expect(result.metadata.siteName, 'OG Rich Site');
      expect(result.metadata.kind, LinkKind.article);
      expect(result.metadata.images.length, greaterThanOrEqualTo(2));
      expect(
        result.metadata.images
            .any((img) => img.url == server.uri('/static/og-image.svg')),
        isTrue,
      );
      expect(result.metadata.videos, isNotEmpty);
      expect(result.metadata.audios, isNotEmpty);
      expect(result.metadata.publishedAt, isNotNull);
      expect(result.metadata.modifiedAt, isNotNull);
      expect(result.metadata.keywords, containsAll(['Tag One', 'Tag Two']));
      expect(result.metadata.locale, 'en_US');
      expect(result.metadata.canonicalUrl, server.uri('/canonical/og-rich'));
    });

    test('Twitter only page extracts title and image', () async {
      final result = await extract('/page/twitter-only');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, 'Twitter Only Title');
      expect(result.metadata.description, 'Twitter Only Description');
      expect(
        result.metadata.images
            .any((img) => img.url == server.uri('/static/twitter-image.svg')),
        isTrue,
      );
      expect(
        result.diagnostics.fieldProvenance[MetaField.title]?.source,
        CandidateSource.twitterCard,
      );
    });

    test('JSON LD heavy page extracts kind, author, and video', () async {
      final result = await extract('/page/jsonld-heavy');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, 'JSON LD Video Title');
      expect(result.metadata.author, 'Video Author');
      expect(result.metadata.kind, LinkKind.video);
      expect(result.metadata.videos, isNotEmpty);
      expect(result.metadata.images, isNotEmpty);
      expect(result.metadata.publishedAt, isNotNull);
      expect(result.metadata.siteName, 'Graph Site');
    });

    test('Mixed sources prefer Open Graph', () async {
      final result = await extract('/page/mixed-sources');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, 'OG Title');
      expect(result.metadata.description, 'OG Description');
      expect(
        result.diagnostics.fieldProvenance[MetaField.title]?.source,
        CandidateSource.openGraph,
      );
      expect(result.metadata.canonicalUrl, server.uri('/canonical/mixed'));
    });

    test('Relative URLs resolve against request URL', () async {
      final result = await extract('/page/relative-urls');

      expect(result.isSuccess, isTrue);
      expect(
        result.metadata.images.any(
          (img) => img.url == server.uri('/page/images/relative.svg'),
        ),
        isTrue,
      );
      expect(
        result.metadata.icons.any(
          (icon) => icon.url == server.uri('/static/icon.svg'),
        ),
        isTrue,
      );
      expect(result.metadata.canonicalUrl, server.uri('/canonical/relative'));
    });

    test('Base href overrides relative resolution', () async {
      final result = await extract('/page/base-href');

      expect(result.isSuccess, isTrue);
      expect(
        result.metadata.images.any(
          (img) => img.url == server.uri('/base/img.svg'),
        ),
        isTrue,
      );
      expect(
        result.metadata.icons.any(
          (icon) => icon.url == server.uri('/base/icons/icon.svg'),
        ),
        isTrue,
      );
    });

    test('Malformed OG falls back to standard meta', () async {
      final result = await extract('/page/malformed-meta');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, 'Standard Fallback Title');
      expect(result.metadata.description, 'Standard Fallback Description');
    });

    test('OEmbed enrichment fills missing fields', () async {
      final result = await extract('/page/oembed-only');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.oembed, isNotNull);
      expect(result.metadata.title, 'OEmbed Title');
      expect(result.metadata.author, 'OEmbed Author');
      expect(result.metadata.siteName, 'OEmbed Provider');
      expect(
        result.metadata.images.any(
          (img) => img.url == Uri.parse('https://example.com/thumb.png'),
        ),
        isTrue,
      );
    });

    test('Manifest enrichment fills title, siteName, and icons', () async {
      final result = await extract('/page/manifest-only');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.manifest, isNotNull);
      expect(result.metadata.siteName, 'Test App');
      expect(result.metadata.title, 'Test');
      expect(result.metadata.icons, isNotEmpty);
      expect(
        result.metadata.icons.any(
          (icon) => icon.url == server.uri('/static/icon.svg'),
        ),
        isTrue,
      );
    });

    test('Media rich page extracts multiple images, videos, and audio',
        () async {
      final result = await extract('/page/media-rich');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.images.length, greaterThanOrEqualTo(2));
      expect(result.metadata.videos.length, greaterThanOrEqualTo(2));
      expect(result.metadata.audios.length, greaterThanOrEqualTo(1));
      expect(result.metadata.kind, LinkKind.video);
    });

    test('International page extracts locale and unicode title', () async {
      final result = await extract('/page/i18n');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.locale, 'ja_JP');
      expect(result.metadata.title, contains('\u65e5'));
    });

    test('Redirect chain resolves final URL', () async {
      final result = await extract('/r/chain1');

      expect(result.isSuccess, isTrue);
      expect(result.metadata.resolvedUrl, server.uri('/page/og-rich'));
      expect(
          result.diagnostics.fetch?.redirects.length, greaterThanOrEqualTo(1));
    });

    test('Non HTML response returns error', () async {
      final result = await extract('/data/json');

      expect(result.isSuccess, isFalse);
      expect(hasError(result, MetaLinkErrorCode.nonHtmlContent), isTrue);
      expect(hasWarning(result, MetaLinkWarningCode.nonHtmlResponse), isTrue);
    });

    test('Blocked response returns http status error', () async {
      final result = await extract('/blocked');

      expect(result.isSuccess, isFalse);
      expect(hasError(result, MetaLinkErrorCode.httpStatus), isTrue);
    });

    test('Charset fallback produces warning', () async {
      final result = await extract('/page/no-charset');

      expect(result.isSuccess, isTrue);
      expect(hasWarning(result, MetaLinkWarningCode.charsetFallback), isTrue);
    });

    test('Large response triggers truncation warning', () async {
      const options = MetaLinkClientOptions(
        fetch: FetchOptions(maxBytes: 512),
        extract: ExtractOptions(
          enableOEmbed: true,
          enableManifest: true,
        ),
      );

      final result = await extract('/page/large', options: options);

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, 'Large Page');
      expect(hasWarning(result, MetaLinkWarningCode.truncatedHtml), isTrue);
    });
  });
}
