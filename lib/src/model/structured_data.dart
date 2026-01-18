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
  const StructuredDataGraph({
    required this.nodes,
  });

  /// The list of JSON-LD objects found in the document.
  ///
  /// Each node is a schema.org entity with `@type`, `@context`, etc.
  final List<Map<String, dynamic>> nodes;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'nodes': nodes,
    };
  }

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
