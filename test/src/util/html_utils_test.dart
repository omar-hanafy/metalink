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
}
