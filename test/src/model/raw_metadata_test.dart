import 'package:html/parser.dart' as html_parser;
import 'package:metalink/src/model/raw_metadata.dart';
import 'package:test/test.dart';

void main() {
  test('RawMetadata.fromDocument captures meta and link tags', () {
    final doc = html_parser.parse(
      '<meta name="description" content="desc">'
      '<meta property="og:title" content="title">'
      '<link rel="icon" href="/icon.png" type="image/png">',
    );

    final raw = RawMetadata.fromDocument(doc);
    expect(raw.meta['description'], ['desc']);
    expect(raw.meta['og:title'], ['title']);
    expect(raw.links.length, 1);
    expect(raw.links.first.rel, 'icon');
    expect(raw.links.first.href, '/icon.png');
  });

  test('RawMetadata normalizes meta keys to lowercase', () {
    final doc = html_parser.parse(
      '<meta NAME="Description" content="Desc">',
    );
    final raw = RawMetadata.fromDocument(doc);
    expect(raw.meta.containsKey('description'), isTrue);
  });

  test('RawMetadata toJson and fromJson', () {
    const raw = RawMetadata(
      meta: {
        'k': ['v']
      },
      links: [RawLinkTag(rel: 'icon', href: '/x')],
    );
    final decoded = RawMetadata.fromJson(raw.toJson());
    expect(decoded.meta['k'], ['v']);
    expect(decoded.links.first.rel, 'icon');
  });
}
