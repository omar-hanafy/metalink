import 'package:html/dom.dart';

/// Utility functions for extracting data from parsed HTML documents.
///
/// [HtmlUtils] provides helper methods for common HTML extraction tasks
/// like reading meta tag content, link tag hrefs, and element text.
/// All methods return `null` for missing or empty values.
class HtmlUtils {
  /// The first non-empty `content` or `value` attribute among the elements
  /// matching [selector], in document order.
  ///
  /// An element whose value is missing or blank is skipped, so an empty
  /// duplicate cannot hide a later usable one. Whitespace runs are collapsed
  /// to single spaces. Returns `null` if no matching element has a value.
  ///
  /// Selector attribute values match case-sensitively; use [MetaTagIndex] to
  /// look up `name`, `property`, or `http-equiv` keys case-insensitively.
  static String? metaContent(Document doc, String selector) {
    for (final el in doc.querySelectorAll(selector)) {
      final value = _clean(_attr(el, 'content') ?? _attr(el, 'value'));
      if (value != null) return value;
    }
    return null;
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

  /// [value] trimmed with each whitespace run collapsed to one space, or
  /// `null` when [value] is `null` or blank.
  static String? collapseWhitespace(String? value) => _clean(value);

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

/// The attribute that names the metadata key of a `<meta>` element.
enum MetaKeyAttribute {
  /// The `name` attribute, as in `<meta name="description">`.
  name,

  /// The `property` attribute used by Open Graph and RDFa.
  property,

  /// The `http-equiv` pragma attribute, as in
  /// `<meta http-equiv="content-language">`.
  httpEquiv,

  /// The microdata `itemprop` attribute.
  itemProp,
}

/// A `<meta>` element reduced to its key attributes and value.
///
/// The `name`, `property`, and `http-equiv` keys are trimmed and ASCII
/// lowercased because HTML defines them as ASCII case-insensitive. The
/// microdata [itemProp] key keeps its case because microdata property names
/// are case-sensitive. Blank attributes are stored as `null`.
final class MetaTag {
  /// Creates a [MetaTag] from already normalized attribute values.
  const MetaTag({
    required this.position,
    this.name,
    this.property,
    this.httpEquiv,
    this.itemProp,
    this.content,
  });

  /// Reads the key attributes and value of [element].
  ///
  /// [position] records the element's document order within its
  /// [MetaTagIndex].
  factory MetaTag.fromElement(Element element, {required int position}) {
    String? key(String attribute) {
      final value = HtmlUtils._attr(element, attribute)?.trim();
      if (value == null || value.isEmpty) return null;
      return _asciiLowerCase(value);
    }

    String? trimmed(String? value) {
      final v = value?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    return MetaTag(
      position: position,
      name: key('name'),
      property: key('property'),
      httpEquiv: key('http-equiv'),
      itemProp: trimmed(HtmlUtils._attr(element, 'itemprop')),
      content: trimmed(
        HtmlUtils._attr(element, 'content') ??
            HtmlUtils._attr(element, 'value'),
      ),
    );
  }

  /// Zero-based document order of this element among all `<meta>` elements.
  final int position;

  /// The ASCII-lowercased `name` attribute, or `null` when absent or blank.
  final String? name;

  /// The ASCII-lowercased `property` attribute, or `null` when absent or
  /// blank.
  final String? property;

  /// The ASCII-lowercased `http-equiv` attribute, or `null` when absent or
  /// blank.
  final String? httpEquiv;

  /// The trimmed, case-preserved `itemprop` attribute, or `null` when absent
  /// or blank.
  final String? itemProp;

  /// The trimmed `content` attribute, falling back to `value`.
  ///
  /// Interior whitespace is preserved so URL values are not altered. `null`
  /// when the chosen attribute is absent or blank; a blank `content` does not
  /// fall back to `value`.
  final String? content;

  /// [content] with each whitespace run collapsed to one space, suitable for
  /// text fields.
  String? get text => HtmlUtils.collapseWhitespace(content);

  /// The normalized key this element declares through [attribute], or `null`
  /// when it does not use that attribute.
  String? keyFor(MetaKeyAttribute attribute) {
    return switch (attribute) {
      MetaKeyAttribute.name => name,
      MetaKeyAttribute.property => property,
      MetaKeyAttribute.httpEquiv => httpEquiv,
      MetaKeyAttribute.itemProp => itemProp,
    };
  }
}

/// A per-document index of `<meta>` elements by key.
///
/// Build one index per parsed document and share it between extractors so
/// every lookup applies the same matching rules: `name`, `property`, and
/// `http-equiv` keys match ASCII case-insensitively, `itemprop` keys match
/// exactly, and results keep document order. Lookups skip elements whose
/// value is blank, so an empty duplicate never hides a later usable one.
///
/// The index is a snapshot; it does not observe later changes to the
/// document.
final class MetaTagIndex {
  MetaTagIndex._(this.tags);

  /// Indexes every `<meta>` element in [document], in document order.
  factory MetaTagIndex.fromDocument(Document document) {
    final elements = document.getElementsByTagName('meta');
    return MetaTagIndex._(
      List<MetaTag>.unmodifiable(<MetaTag>[
        for (var i = 0; i < elements.length; i++)
          MetaTag.fromElement(elements[i], position: i),
      ]),
    );
  }

  /// Every `<meta>` element in document order, including elements without a
  /// key or value.
  final List<MetaTag> tags;

  /// Tags with a non-blank [MetaTag.content] whose key matches one of [keys],
  /// in document order.
  ///
  /// By default a tag matches when its `name` or `property` equals a key,
  /// which mirrors how Open Graph and Twitter tags appear in either
  /// attribute. Pass [attributes] to restrict matching, for example to
  /// `{MetaKeyAttribute.httpEquiv}`. Keys for `name`, `property`, and
  /// `http-equiv` are compared ASCII case-insensitively; `itemprop` keys are
  /// compared exactly. A tag that matches through several attributes is
  /// returned once.
  List<MetaTag> find(
    Iterable<String> keys, {
    Set<MetaKeyAttribute> attributes = nameOrProperty,
  }) {
    final exact = keys.toSet();
    final folded = exact.map(_asciiLowerCase).toSet();
    return <MetaTag>[
      for (final tag in tags)
        if (tag.content != null &&
            attributes.any((attribute) {
              final key = tag.keyFor(attribute);
              if (key == null) return false;
              return attribute == MetaKeyAttribute.itemProp
                  ? exact.contains(key)
                  : folded.contains(key);
            }))
          tag,
    ];
  }

  /// The first whitespace-collapsed value among tags matching [keys], or
  /// `null` when none has a value.
  ///
  /// Matching follows [find].
  String? firstText(
    Iterable<String> keys, {
    Set<MetaKeyAttribute> attributes = nameOrProperty,
  }) {
    for (final tag in find(keys, attributes: attributes)) {
      final value = tag.text;
      if (value != null) return value;
    }
    return null;
  }

  /// Whitespace-collapsed values of all tags matching [keys], in document
  /// order.
  ///
  /// Matching follows [find].
  List<String> texts(
    Iterable<String> keys, {
    Set<MetaKeyAttribute> attributes = nameOrProperty,
  }) {
    return <String>[
      for (final tag in find(keys, attributes: attributes)) ?tag.text,
    ];
  }

  /// The default [find] attributes: `name` and `property`.
  static const Set<MetaKeyAttribute> nameOrProperty = <MetaKeyAttribute>{
    MetaKeyAttribute.name,
    MetaKeyAttribute.property,
  };
}

/// [value] with only ASCII `A`-`Z` mapped to lowercase, as HTML requires for
/// ASCII case-insensitive comparison.
String _asciiLowerCase(String value) {
  final units = value.codeUnits;
  var changed = false;
  final out = List<int>.of(units, growable: false);
  for (var i = 0; i < out.length; i++) {
    final unit = out[i];
    if (unit >= 0x41 && unit <= 0x5A) {
      out[i] = unit + 0x20;
      changed = true;
    }
  }
  return changed ? String.fromCharCodes(out) : value;
}
