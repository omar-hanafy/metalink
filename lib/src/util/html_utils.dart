import 'package:html/dom.dart';

/// Utility functions for extracting data from parsed HTML documents.
///
/// [HtmlUtils] provides helper methods for common HTML extraction tasks
/// like reading meta tag content, link tag hrefs, and element text.
/// All methods return `null` for missing or empty values.
class HtmlUtils {
  /// Retrieves the `content` or `value` attribute from a meta tag.
  ///
  /// Returns `null` if the selector matches nothing or the value is empty.
  static String? metaContent(Document doc, String selector) {
    final el = doc.querySelector(selector);
    if (el == null) return null;
    return _clean(_attr(el, 'content') ?? _attr(el, 'value'));
  }

  /// Retrieves all `content` or `value` attributes from matching meta tags.
  ///
  /// Empty values are filtered out.
  static List<String> metaContents(Document doc, String selector) {
    final els = doc.querySelectorAll(selector);
    if (els.isEmpty) return const [];

    final out = <String>[];
    for (final el in els) {
      final v = _clean(_attr(el, 'content') ?? _attr(el, 'value'));
      if (v != null) out.add(v);
    }
    return out;
  }

  /// Retrieves an attribute value from the first matching element.
  ///
  /// Returns `null` if the selector matches nothing or the attribute is empty.
  static String? attr(Document doc, String selector, String attribute) {
    final el = doc.querySelector(selector);
    if (el == null) return null;
    return _clean(_attr(el, attribute));
  }

  /// Returns all elements matching [selector].
  static List<Element> all(Document doc, String selector) {
    return doc.querySelectorAll(selector);
  }

  /// Retrieves the text content of the first matching element.
  ///
  /// Whitespace is normalized to single spaces.
  static String? text(Document doc, String selector) {
    final el = doc.querySelector(selector);
    if (el == null) return null;
    return _clean(el.text);
  }

  /// Retrieves all `href` values from `<link>` tags with the given `rel`.
  ///
  /// The [rel] matching is case-insensitive and supports multiple tokens.
  static List<String> relLinksHrefs(Document doc, String rel) {
    final relLower = rel.toLowerCase().trim();
    if (relLower.isEmpty) return const [];

    final out = <String>[];
    for (final el in doc.querySelectorAll('link[rel]')) {
      final relAttr = _clean(_attr(el, 'rel'));
      if (relAttr == null) continue;

      final tokens = relAttr
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toSet();

      if (!tokens.contains(relLower)) continue;

      final href = _clean(_attr(el, 'href'));
      if (href != null) out.add(href);
    }
    return out;
  }

  /// Retrieves the canonical URL from `<link rel="canonical">`.
  ///
  /// Returns `null` if no canonical link is found.
  static String? canonicalHref(Document doc) {
    final hrefs = relLinksHrefs(doc, 'canonical');
    if (hrefs.isEmpty) return null;
    return hrefs.first;
  }

  /// Returns all `<meta>` elements in the document.
  static List<Element> allMetaTags(Document doc) {
    return doc.querySelectorAll('meta');
  }

  /// Returns all `<link>` elements in the document.
  static List<Element> allLinkTags(Document doc) {
    return doc.querySelectorAll('link');
  }

  static String? _attr(Element el, String name) {
    // Attribute names are case-insensitive, but the parser may preserve case.
    final direct = el.attributes[name];
    if (direct != null) return direct;

    final lower = el.attributes[name.toLowerCase()];
    if (lower != null) return lower;

    final upper = el.attributes[name.toUpperCase()];
    if (upper != null) return upper;

    // Fallback to a full scan for uncommon casing.
    final needle = name.toLowerCase();
    for (final entry in el.attributes.entries) {
      if (entry.key.toString().toLowerCase() == needle) {
        return entry.value;
      }
    }
    return null;
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    // Collapse consecutive whitespace so comparisons stay consistent.
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }
}
