import 'dart:convert';

import 'package:convert_object/convert_object.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/icon.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:test/test.dart';

/// URLs containing `@` that convert_object would coerce into `mailto:` URIs.
const _urlsWithAt = <String, String>{
  'path': 'https://medium.com/@john.doe',
  'path asset': 'https://cdn.example.com/logo@2x.png',
  'userinfo': 'https://u:p@host.example/',
  'query': 'https://example.com/?email=a@b.co',
  'fragment': 'https://example.com/page#x@y.z',
};

/// Encodes and decodes [json] the way a JSON cache store does.
Map<String, dynamic> _viaJson(Map<String, dynamic> json) {
  return Map<String, dynamic>.from(
    jsonDecode(jsonEncode(json)) as Map<dynamic, dynamic>,
  );
}

void main() {
  for (final MapEntry(key: label, value: raw) in _urlsWithAt.entries) {
    group('URL with @ in the $label round-trips exactly', () {
      final url = Uri.parse(raw);

      void expectSame(Uri? actual) {
        expect(actual, url);
        expect(actual.toString(), raw);
      }

      test('LinkMetadata', () {
        final decoded = LinkMetadata.fromJson(
          _viaJson(
            LinkMetadata(
              originalUrl: url,
              resolvedUrl: url,
              canonicalUrl: url,
              images: [ImageCandidate(url: url)],
              icons: [IconCandidate(url: url)],
              videos: [VideoCandidate(url: url)],
              audios: [AudioCandidate(url: url)],
              oembed: OEmbedData(endpoint: url, authorUrl: url),
              manifest: WebAppManifestData(manifestUrl: url, startUrl: url),
            ).toJson(),
          ),
        );
        expectSame(decoded.originalUrl);
        expectSame(decoded.resolvedUrl);
        expectSame(decoded.canonicalUrl);
        expectSame(decoded.images.single.url);
        expectSame(decoded.icons.single.url);
        expectSame(decoded.videos.single.url);
        expectSame(decoded.audios.single.url);
        expectSame(decoded.oembed?.endpoint);
        expectSame(decoded.manifest?.manifestUrl);
      });

      test('ImageCandidate, VideoCandidate, AudioCandidate', () {
        expectSame(
          ImageCandidate.fromJson(_viaJson(ImageCandidate(url: url).toJson()))
              .url,
        );
        expectSame(
          VideoCandidate.fromJson(_viaJson(VideoCandidate(url: url).toJson()))
              .url,
        );
        expectSame(
          AudioCandidate.fromJson(_viaJson(AudioCandidate(url: url).toJson()))
              .url,
        );
      });

      test('IconCandidate', () {
        expectSame(
          IconCandidate.fromJson(_viaJson(IconCandidate(url: url).toJson()))
              .url,
        );
      });

      test('ManifestIcon and WebAppManifestData', () {
        expectSame(
          ManifestIcon.fromJson(_viaJson(ManifestIcon(src: url).toJson())).src,
        );
        final manifest = WebAppManifestData.fromJson(
          _viaJson(
            WebAppManifestData(
              manifestUrl: url,
              startUrl: url,
              icons: [ManifestIcon(src: url)],
            ).toJson(),
          ),
        );
        expectSame(manifest.manifestUrl);
        expectSame(manifest.startUrl);
        expectSame(manifest.icons.single.src);
      });

      test('OEmbedEndpoint and OEmbedData', () {
        expectSame(
          OEmbedEndpoint.fromJson(
            _viaJson(
              OEmbedEndpoint(url: url, format: OEmbedFormat.json).toJson(),
            ),
          ).url,
        );
        final data = OEmbedData.fromJson(
          _viaJson(
            OEmbedData(
              endpoint: url,
              authorUrl: url,
              providerUrl: url,
              thumbnailUrl: url,
            ).toJson(),
          ),
        );
        expectSame(data.endpoint);
        expectSame(data.authorUrl);
        expectSame(data.providerUrl);
        expectSame(data.thumbnailUrl);
      });

      test('FetchDiagnostics, RedirectHop, ExtractionDiagnostics', () {
        final fetch = FetchDiagnostics(
          requestedUrl: url,
          finalUrl: url,
          statusCode: 200,
          redirects: [RedirectHop(from: url, to: url, statusCode: 301)],
          bytesRead: 0,
          truncated: false,
          detectedCharset: null,
          charsetSource: CharsetSource.unknown,
          duration: Duration.zero,
        );
        final decoded = FetchDiagnostics.fromJson(_viaJson(fetch.toJson()));
        expectSame(decoded.requestedUrl);
        expectSame(decoded.finalUrl);
        expectSame(decoded.redirects.single.from);
        expectSame(decoded.redirects.single.to);

        final hop = RedirectHop.fromJson(
          _viaJson(RedirectHop(from: url, to: url, statusCode: 302).toJson()),
        );
        expectSame(hop.from);
        expectSame(hop.to);

        final diagnostics = ExtractionDiagnostics.fromJson(
          _viaJson(
            ExtractionDiagnostics(
              cacheHit: false,
              totalTime: Duration.zero,
              fetch: fetch,
              fieldProvenance: const {},
            ).toJson(),
          ),
        );
        expectSame(diagnostics.fetch?.finalUrl);
      });

      test('MetaLinkError and MetaLinkWarning', () {
        expectSame(
          MetaLinkError.fromJson(
            _viaJson(
              MetaLinkError(
                code: MetaLinkErrorCode.network,
                message: 'm',
                uri: url,
              ).toJson(),
            ),
          ).uri,
        );
        expectSame(
          MetaLinkWarning.fromJson(
            _viaJson(
              MetaLinkWarning(
                code: MetaLinkWarningCode.truncatedHtml,
                message: 'm',
                uri: url,
              ).toJson(),
            ),
          ).uri,
        );
      });
    });
  }

  test('relative icon file names with @ are not rewritten', () {
    final decoded = IconCandidate.fromJson({'url': 'apple-touch-icon@2x.png'});
    expect(decoded.url.toString(), 'apple-touch-icon@2x.png');
    expect(decoded.url.scheme, isEmpty);
  });

  group('URL failure contract is unchanged', () {
    test('required URLs that are missing, blank, or invalid throw', () {
      for (final value in <Object?>[null, '', '   ', 'http://[::1']) {
        expect(
          () => ImageCandidate.fromJson({'url': value}),
          throwsA(isA<ConversionException>()),
          reason: 'url: $value',
        );
        expect(
          () => LinkMetadata.fromJson({
            'originalUrl': value,
            'resolvedUrl': 'https://example.com',
          }),
          throwsA(isA<ConversionException>()),
          reason: 'originalUrl: $value',
        );
      }
    });

    test('optional URLs that are missing or invalid become null', () {
      final decoded = OEmbedData.fromJson({
        'endpoint': 'https://example.com/oembed',
        'authorUrl': 'http://[::1',
        'providerUrl': '',
      });
      expect(decoded.authorUrl, isNull);
      expect(decoded.providerUrl, isNull);
      expect(decoded.thumbnailUrl, isNull);
    });

    test('defaulted URLs keep their empty Uri fallback', () {
      final fetch = FetchDiagnostics.fromJson({'finalUrl': 'http://[::1'});
      expect(fetch.requestedUrl, Uri());
      expect(fetch.finalUrl, Uri());
      final hop = RedirectHop.fromJson(const {});
      expect(hop.from, Uri());
      expect(hop.to, Uri());
    });

    test('surrounding whitespace is trimmed and Uri values are accepted', () {
      expect(
        ImageCandidate.fromJson({'url': '  https://example.com/a@b.png  '}).url
            .toString(),
        'https://example.com/a@b.png',
      );
      final uri = Uri.parse('https://example.com/@me');
      expect(ImageCandidate.fromJson({'url': uri}).url, same(uri));
    });
  });
}
