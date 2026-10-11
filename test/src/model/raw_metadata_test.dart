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
    final doc = html_parser.parse('<meta NAME="Description" content="Desc">');
    final raw = RawMetadata.fromDocument(doc);
    expect(raw.meta.containsKey('description'), isTrue);
  });

  test('RawMetadata toJson and fromJson', () {
    const raw = RawMetadata(
      meta: {
        'k': ['v'],
      },
      links: [RawLinkTag(rel: 'icon', href: '/x')],
    );
    final decoded = RawMetadata.fromJson(raw.toJson());
    expect(decoded.meta['k'], ['v']);
    expect(decoded.links.first.rel, 'icon');
  });

  test('RawMetadata.fromJson skips malformed link entries', () {
    final decoded = RawMetadata.fromJson({
      'meta': <String, dynamic>{},
      'links': [
        {'rel': 'icon', 'href': '/favicon.ico'},
        'garbage',
        null,
      ],
    });
    expect(decoded.links, hasLength(1));
    expect(decoded.links.single.rel, 'icon');
    expect(decoded.links.single.href, '/favicon.ico');
  });

  test('RawMetadata.fromJson skips null values inside a meta list', () {
    final decoded = RawMetadata.fromJson({
      'meta': {
        'keywords': ['a', null, 'b'],
        'description': ['desc'],
      },
      'links': <dynamic>[],
    });
    expect(decoded.meta['keywords'], ['a', 'b']);
    expect(decoded.meta['description'], ['desc']);
  });
}
