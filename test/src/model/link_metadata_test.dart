import 'package:metalink/src/model/icon.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/model/structured_data.dart';
import 'package:test/test.dart';

void main() {
  test('LinkMetadata toJson and fromJson', () {
    final metadata = LinkMetadata(
      originalUrl: Uri.parse('https://example.com/orig'),
      resolvedUrl: Uri.parse('https://example.com/final'),
      canonicalUrl: Uri.parse('https://example.com/canonical'),
      title: 'Title',
      description: 'Desc',
      siteName: 'Site',
      locale: 'en',
      kind: LinkKind.article,
      images: [ImageCandidate(url: Uri.parse('https://example.com/img'))],
      icons: [IconCandidate(url: Uri.parse('https://example.com/icon'))],
      videos: [VideoCandidate(url: Uri.parse('https://example.com/vid'))],
      audios: [AudioCandidate(url: Uri.parse('https://example.com/aud'))],
      publishedAt: DateTime.utc(2024, 1, 1),
      modifiedAt: DateTime.utc(2024, 1, 2),
      author: 'Author',
      keywords: const ['a', 'b'],
      oembed: OEmbedData(endpoint: Uri.parse('https://example.com/o')),
      manifest: WebAppManifestData(
        manifestUrl: Uri.parse('https://example.com/manifest.json'),
      ),
      structuredData: const StructuredDataGraph(nodes: [
        {'@type': 'Article'}
      ]),
    );

    final decoded = LinkMetadata.fromJson(metadata.toJson());
    expect(decoded.originalUrl.toString(), 'https://example.com/orig');
    expect(decoded.resolvedUrl.toString(), 'https://example.com/final');
    expect(decoded.canonicalUrl.toString(), 'https://example.com/canonical');
    expect(decoded.title, 'Title');
    expect(decoded.description, 'Desc');
    expect(decoded.siteName, 'Site');
    expect(decoded.locale, 'en');
    expect(decoded.kind, LinkKind.article);
    expect(decoded.images.length, 1);
    expect(decoded.icons.length, 1);
    expect(decoded.videos.length, 1);
    expect(decoded.audios.length, 1);
    expect(decoded.author, 'Author');
    expect(decoded.keywords, ['a', 'b']);
    expect(decoded.oembed, isNotNull);
    expect(decoded.manifest, isNotNull);
    expect(decoded.structuredData, isNotNull);
  });

  test('LinkMetadata isEmpty reflects fields', () {
    final empty = LinkMetadata(
      originalUrl: Uri.parse('https://example.com'),
      resolvedUrl: Uri.parse('https://example.com'),
    );
    expect(empty.isEmpty, isTrue);

    final nonEmpty = LinkMetadata(
      originalUrl: Uri.parse('https://example.com'),
      resolvedUrl: Uri.parse('https://example.com'),
      title: 'x',
    );
    expect(nonEmpty.isEmpty, isFalse);
  });

  test('LinkMetadata.fromJson skips invalid list entries', () {
    final decoded = LinkMetadata.fromJson({
      'originalUrl': 'https://example.com',
      'resolvedUrl': 'https://example.com',
      'images': [
        {'url': 'https://example.com/img.png'},
        'bad'
      ],
    });
    expect(decoded.images.length, 1);
  });
}
