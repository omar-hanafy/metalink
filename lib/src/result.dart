import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/raw_metadata.dart';

/// The high-level outcome of an extraction.
///
/// This additive status lets automation distinguish a complete value, a
/// usable but degraded value, and a failure without inferring intent from
/// placeholder metadata. The existing [ExtractionResult.isSuccess] contract
/// remains unchanged for v2 compatibility.
enum ExtractionStatus {
  /// Extraction completed without a known loss of requested information.
  success,

  /// Extraction produced usable metadata with a known degradation.
  partial,

  /// Extraction could not produce a usable result.
  failure,
}

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
    ExtractionStatus? status,
    double? completeness,
  }) : _explicitStatus = status,
       _completeness = completeness,
       assert(
         status != ExtractionStatus.failure || errors.length > 0,
         'failure status requires at least one error',
       ),
       assert(
         completeness == null || (completeness >= 0 && completeness <= 1),
         'completeness must be between 0 and 1',
       );

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

  final ExtractionStatus? _explicitStatus;

  /// A caller-facing estimate from 0 to 1 when the extraction engine can
  /// quantify completeness. `null` means no estimate was calculated.
  final double? _completeness;

  /// A normalized completeness estimate, or `null` when none is valid.
  double? get completeness {
    final value = _completeness;
    if (value == null || !value.isFinite || value < 0 || value > 1) {
      return null;
    }
    return value;
  }

  /// The explicit outcome status.
  ///
  /// Results produced by the v2-compatible constructor infer failure from
  /// [errors] and otherwise infer success. New engine paths can explicitly
  /// identify a partial result.
  ExtractionStatus get status {
    // Fatal errors always dominate an explicit status so callers cannot
    // observe success and failure simultaneously.
    if (errors.isNotEmpty) return ExtractionStatus.failure;
    final explicit = _explicitStatus;
    if (explicit == ExtractionStatus.failure) {
      // Keep release builds internally consistent even when a caller bypasses
      // constructor assertions.
      return ExtractionStatus.success;
    }
    return explicit ?? inferStatus(warnings: warnings, errors: errors);
  }

  /// Infers status from the package's shared warning and error taxonomy.
  static ExtractionStatus inferStatus({
    required List<MetaLinkWarning> warnings,
    required List<MetaLinkError> errors,
  }) {
    if (errors.isNotEmpty) return ExtractionStatus.failure;
    const partialCodes = <MetaLinkWarningCode>{
      MetaLinkWarningCode.redirectedTooMuch,
      MetaLinkWarningCode.truncatedHtml,
      MetaLinkWarningCode.oembedFailed,
      MetaLinkWarningCode.manifestFailed,
      MetaLinkWarningCode.partialParse,
    };
    return warnings.any((warning) => partialCodes.contains(warning.code))
        ? ExtractionStatus.partial
        : ExtractionStatus.success;
  }

  /// Returns `true` if no errors were encountered.
  bool get isSuccess => errors.isEmpty;

  /// Whether the result contains usable but known-incomplete metadata.
  bool get isPartial => status == ExtractionStatus.partial;

  /// Whether the extraction failed to produce usable metadata.
  bool get isFailure => status == ExtractionStatus.failure;

  /// The first structured error, if any.
  MetaLinkError? get primaryError => errors.firstOrNull;

  /// Metadata when the result is usable, otherwise `null`.
  T? get metadataOrNull => isFailure ? null : metadata;

  /// Whether every fatal error is classified as safe to retry.
  bool get retryable =>
      errors.isNotEmpty &&
      errors.every((error) {
        return error.isRetryable;
      });
}
