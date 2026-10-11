/// @docImport 'package:metalink/src/model/link_metadata.dart';
library;

import 'package:convert_object/convert_object.dart';

/// JSON-LD structured data extracted from the page.
///
/// [StructuredDataGraph] contains a list of JSON-LD objects found in
/// `<script type="application/ld+json">` blocks.
///
/// ### When to Use
/// Access via [LinkMetadata.structuredData] to get schema.org data
/// for rich previews, SEO analysis, or product/article extraction.
///
/// ### Example
/// ```dart
/// final sd = metadata.structuredData;
/// if (sd != null) {
///   for (final node in sd.nodes) {
///     final type = node['@type'];
///     print('Found: $type');
///   }
/// }
/// ```
class StructuredDataGraph {
  /// Creates a [StructuredDataGraph].
  const StructuredDataGraph({required this.nodes});

  /// The list of JSON-LD objects found in the document.
  ///
  /// Each node is a schema.org entity with `@type`, `@context`, etc.
  final List<Map<String, dynamic>> nodes;

  /// A JSON-compatible map with the [nodes] list under `nodes`.
  ///
  /// The node maps are included as is, not copied.
  /// [StructuredDataGraph.fromJson] reads this format back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'nodes': nodes};
  }

  /// Creates a [StructuredDataGraph] from a map produced by [toJson].
  ///
  /// Parsing is lenient and does not throw. A missing `nodes` value yields an
  /// empty graph. Entries that are not string-keyed maps, and empty maps, are
  /// dropped.
  factory StructuredDataGraph.fromJson(Map<String, dynamic> json) {
    return StructuredDataGraph(
      nodes: Convert.toList<Map<String, dynamic>>(
        json['nodes'],
        elementConverter: (e) =>
            Convert.tryToMap<String, dynamic>(e) ?? const {},
        defaultValue: const [],
      ).where((e) => e.isNotEmpty).toList(),
    );
  }
}
