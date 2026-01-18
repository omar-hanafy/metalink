import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/raw_metadata.dart';

/// The outcome of an extraction operation.
///
/// Contains the resolved [metadata], diagnostic information, and any errors or warnings
/// collected during the process.
class ExtractionResult<T> {
  const ExtractionResult({
    required this.metadata,
    required this.diagnostics,
    this.raw,
    this.warnings = const [],
    this.errors = const [],
  });

  /// The extracted metadata.
  ///
  /// Even if errors occurred (e.g., partial failure), this field will be populated
  /// with whatever data could be recovered (best-effort).
  final T metadata;

  /// Operational details about the extraction (timings, cache status, etc.).
  final ExtractionDiagnostics diagnostics;

  /// The raw HTML metadata (meta tags, link tags) found in the document.
  ///
  /// Only populated if `ExtractOptions.includeRawMetadata` was `true`.
  /// Otherwise `null`.
  final RawMetadata? raw;

  /// Non-fatal issues encountered during extraction.
  ///
  /// Examples: "Cache write failed", "oEmbed endpoint unreachable".
  /// The presence of warnings does not imply [metadata] is invalid.
  final List<MetaLinkWarning> warnings;

  /// Fatal or serious errors encountered during extraction.
  ///
  /// Examples: "Network timeout", "DNS failure", "HTML parsing failed".
  /// If errors are present, [metadata] may be incomplete or empty.
  final List<MetaLinkError> errors;

  /// Returns `true` if no errors were encountered.
  bool get isSuccess => errors.isEmpty;
}
