import 'package:convert_object/convert_object.dart';
import 'package:html/dom.dart';

/// Represents a raw `<link>` tag extracted from an HTML document.
///
/// [RawLinkTag] preserves the original attribute values for debugging
/// and inspection before they are processed into typed candidates.
///
/// ### Fields
/// * [rel] - The `rel` attribute (e.g., `icon`, `canonical`, `stylesheet`).
/// * [href] - The `href` attribute (may be relative).
/// * [type] - The `type` attribute (e.g., `image/png`).
/// * [sizes] - The `sizes` attribute (e.g., `32x32`).
/// * [title] - The `title` attribute, if present.
class RawLinkTag {
  /// Creates a [RawLinkTag].
  const RawLinkTag({
    required this.rel,
    required this.href,
    this.type,
    this.sizes,
    this.title,
  });

  /// The `rel` attribute value.
  final String rel;

  /// The `href` attribute value (may be relative).
  final String href;

  /// The `type` attribute value, or `null` if not present.
  final String? type;

  /// The `sizes` attribute value, or `null` if not present.
  final String? sizes;

  /// The `title` attribute value, or `null` if not present.
  final String? title;

  /// A JSON-compatible map of this tag's attributes.
  ///
  /// Absent optional attributes are written as `null`. [RawLinkTag.fromJson]
  /// reads this format back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'rel': rel,
      'href': href,
      'type': type,
      'sizes': sizes,
      'title': title,
    };
  }

  /// Creates a [RawLinkTag] from a map produced by [toJson].
  ///
  /// Parsing is lenient and does not throw for missing or malformed values: a
  /// missing `rel` or `href` becomes an empty string, and other missing
  /// attributes become `null`.
  factory RawLinkTag.fromJson(Map<String, dynamic> json) {
    return RawLinkTag(
      rel: json.getString('rel', defaultValue: ''),
      href: json.getString('href', defaultValue: ''),
      type: json.tryGetString('type'),
      sizes: json.tryGetString('sizes'),
      title: json.tryGetString('title'),
    );
  }
}

/// Raw metadata extracted from an HTML document before normalization.
///
/// [RawMetadata] captures the original meta tags and link tags from the
/// document for debugging and inspection.
///
/// ### When to Use
/// Rarely accessed directly. Useful for debugging extraction issues
/// or understanding what raw data was found in the HTML.
///
/// ### Structure
/// * [meta] - Map of meta tag keys to their content values (supports multiple).
/// * [links] - List of all `<link>` tags found in the document.
class RawMetadata {
  /// Creates a [RawMetadata].
  const RawMetadata({required this.meta, required this.links});

  /// Meta tag values keyed by normalized (lowercase) name/property.
  ///
  /// Each key maps to a list of content values (since tags can repeat).
  final Map<String, List<String>> meta;

  /// All `<link>` tags found in the document.
  final List<RawLinkTag> links;

  /// Collects the raw `<meta>` and `<link>` tags of [document].
  ///
  /// Each `<meta>` tag is keyed by its first non-empty `name`, `property`, or
  /// `http-equiv` attribute, trimmed and lowercased. Its trimmed `content` is
  /// appended under that key in document order. Tags without a key or with
  /// empty content are skipped.
  ///
  /// Each `<link>` tag with a non-empty `rel` and `href` becomes a
  /// [RawLinkTag] with trimmed values. Empty `type`, `sizes`, and `title`
  /// attributes become `null`. Relative `href` values are kept as written.
  static RawMetadata fromDocument(Document document) {
    final metaMap = <String, List<String>>{};

    // Collect raw meta tags for inspection without applying normalization.
    for (final el in document.getElementsByTagName('meta')) {
      final key = _metaKey(el);
      if (key == null) continue;

      final content = el.attributes['content']?.trim();
      if (content == null || content.isEmpty) continue;

      (metaMap[key] ??= <String>[]).add(content);
    }

    // Collect raw link tags for inspection and later debugging.
    final linkTags = <RawLinkTag>[];
    for (final el in document.getElementsByTagName('link')) {
      final rel = el.attributes['rel']?.trim();
      final href = el.attributes['href']?.trim();
      if (rel == null || rel.isEmpty) continue;
      if (href == null || href.isEmpty) continue;

      linkTags.add(
        RawLinkTag(
          rel: rel,
          href: href,
          type: _emptyToNull(el.attributes['type']),
          sizes: _emptyToNull(el.attributes['sizes']),
          title: _emptyToNull(el.attributes['title']),
        ),
      );
    }

    return RawMetadata(meta: metaMap, links: linkTags);
  }

  /// A JSON-compatible map of this raw metadata.
  ///
  /// [meta] is written as a map of string lists, and [links] as a list of
  /// [RawLinkTag.toJson] maps. [RawMetadata.fromJson] reads this format back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'meta': <String, dynamic>{
        for (final entry in meta.entries) entry.key: entry.value,
      },
      'links': links.map((e) => e.toJson()).toList(),
    };
  }

  /// Creates a [RawMetadata] from a map produced by [toJson].
  ///
  /// Parsing is lenient and does not throw. A missing or malformed `meta`
  /// value yields an empty map. Within each `meta` list, `null` entries are
  /// skipped and other values are converted with `toString()`. Each `links`
  /// entry that is not a string-keyed map is skipped, so one malformed tag
  /// does not discard the others.
  factory RawMetadata.fromJson(Map<String, dynamic> json) {
    return RawMetadata(
      meta: Convert.toMap<String, List<String>>(
        json['meta'],
        valueConverter: _stringListFromJson,
        defaultValue: {},
      ),
      links: <RawLinkTag>[
        for (final element
            in Convert.tryToList<dynamic>(json['links']) ?? const <dynamic>[])
          if (Convert.tryToMap<String, dynamic>(element) case final link?)
            RawLinkTag.fromJson(link),
      ],
    );
  }
}

/// Converts each non-null element of [value] to a string, skipping `null`
/// entries so one malformed value cannot discard the rest of its list.
List<String> _stringListFromJson(Object? value) {
  final list = Convert.tryToList<dynamic>(value);
  if (list == null) return <String>[];
  return list.map(Convert.tryToString).whereType<String>().toList();
}

String? _metaKey(Element el) {
  final name = _emptyToNull(el.attributes['name']);
  final property = _emptyToNull(el.attributes['property']);
  final httpEquiv = _emptyToNull(el.attributes['http-equiv']);

  final raw = name ?? property ?? httpEquiv;
  if (raw == null) return null;

  // Normalize keys to lower-case so duplicates collapse consistently.
  return raw.trim().toLowerCase();
}

String? _emptyToNull(String? v) {
  if (v == null) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}
