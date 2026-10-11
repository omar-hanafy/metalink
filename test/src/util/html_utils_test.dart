import 'package:html/parser.dart' as html_parser;
import 'package:metalink/src/util/html_utils.dart';
import 'package:test/test.dart';

void main() {
  test('metaContent reads content or value', () {
    final doc = html_parser.parse(
      '<meta name="description" content="  hello  ">'
      '<meta name="alt" value="world">',
    );
    expect(HtmlUtils.metaContent(doc, 'meta[name="description"]'), 'hello');
    expect(HtmlUtils.metaContent(doc, 'meta[name="alt"]'), 'world');
  });

  test('metaContents collects multiple values', () {
    final doc = html_parser.parse(
      '<meta name="keywords" content="a">'
      '<meta name="keywords" content="b">',
    );
    final values = HtmlUtils.metaContents(doc, 'meta[name="keywords"]');
    expect(values, ['a', 'b']);
  });

  test('attr is case-insensitive', () {
    final doc = html_parser.parse('<meta NAME="x" CONTENT="y">');
    expect(HtmlUtils.attr(doc, 'meta', 'content'), 'y');
  });

  test('text collapses whitespace', () {
    final doc = html_parser.parse('<div>  hello\n  world  </div>');
    expect(HtmlUtils.text(doc, 'div'), 'hello world');
  });

  test('relLinksHrefs filters by rel token', () {
    final doc = html_parser.parse(
      '<link rel="canonical" href="/a">'
      '<link rel="shortcut icon" href="/b">'
      '<link rel="alternate" href="/c">',
    );
    expect(HtmlUtils.relLinksHrefs(doc, 'canonical'), ['/a']);
    expect(HtmlUtils.relLinksHrefs(doc, 'icon'), ['/b']);
  });

  test('canonicalHref returns first canonical', () {
    final doc = html_parser.parse(
      '<link rel="canonical" href="/a">'
      '<link rel="canonical" href="/b">',
    );
    expect(HtmlUtils.canonicalHref(doc), '/a');
  });

  test('metaContent skips an empty first match', () {
    final doc = html_parser.parse(
      '<meta property="og:title" content="">'
      '<meta property="og:title" content="Real OG">',
    );
    expect(HtmlUtils.metaContent(doc, 'meta[property="og:title"]'), 'Real OG');
  });

  group('MetaTagIndex', () {
    test('matches name, property, and http-equiv ASCII case-insensitively', () {
      final index = MetaTagIndex.fromDocument(
        html_parser.parse(
          '<meta name="Description" content="d">'
          '<meta property="OG:Title" content="t">'
          '<meta http-equiv="Content-Language" content="fr">',
        ),
      );

      expect(index.firstText(['description']), 'd');
      expect(index.firstText(['og:title']), 't');
      expect(index.firstText(['OG:TITLE']), 't');
      expect(
        index.firstText(
          ['content-language'],
          attributes: {MetaKeyAttribute.httpEquiv},
        ),
        'fr',
      );
      expect(index.firstText(['content-language']), isNull);
    });

    test('folds only ASCII letters', () {
      final index = MetaTagIndex.fromDocument(
        html_parser.parse('<meta name="İtem" content="x">'),
      );

      expect(index.firstText(['İtem']), 'x');
      expect(index.firstText(['i̇tem']), isNull);
    });

    test('matches itemprop exactly', () {
      final index = MetaTagIndex.fromDocument(
        html_parser.parse('<meta itemprop="datePublished" content="2024">'),
      );
      const itemProp = {MetaKeyAttribute.itemProp};

      expect(index.firstText(['datePublished'], attributes: itemProp), '2024');
      expect(index.firstText(['datepublished'], attributes: itemProp), isNull);
    });

    test('keeps document order across keys and skips blank values', () {
      final index = MetaTagIndex.fromDocument(
        html_parser.parse(
          '<meta property="b" content=" ">'
          '<meta name="a" content="first">'
          '<meta property="b" content="second">'
          '<meta name="a" value="third">',
        ),
      );

      expect(index.texts(['b', 'a']), ['first', 'second', 'third']);
      expect(index.firstText(['b']), 'second');
      expect(index.tags, hasLength(4));
    });

    test('returns a tag matched by name and property once', () {
      final index = MetaTagIndex.fromDocument(
        html_parser.parse(
          '<meta name="og:title" property="og:title" content="x">',
        ),
      );

      expect(index.find(['og:title']), hasLength(1));
    });

    test(
      'preserves interior whitespace in content and collapses it in text',
      () {
        final index = MetaTagIndex.fromDocument(
          html_parser.parse('<meta name="k" content="  a \n  b  ">'),
        );
        final tag = index.find(['k']).single;

        expect(tag.content, 'a \n  b');
        expect(tag.text, 'a b');
      },
    );
  });
}
