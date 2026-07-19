import 'package:convert_object/convert_object.dart';
import 'package:metalink/src/model/url_optimization.dart';

/// Indicates how the character encoding was determined for fetched HTML.
///
/// The charset detection process checks multiple sources in priority order:
/// 1. [bom] - From a Byte Order Mark at the start of the response.
/// 2. [header] - From the `Content-Type` HTTP header.
/// 3. [meta] - From a `<meta charset>` or `<meta http-equiv="Content-Type">` tag.
/// 4. [fallback] - Defaulted to UTF-8 when no charset was found.
/// 5. [unknown] - Unable to determine; may produce decoding issues.
enum CharsetSource {
  /// Charset extracted from the `Content-Type` HTTP response header.
  header,

  /// Charset extracted from an HTML `<meta>` tag.
  meta,

  /// Charset inferred from a Byte Order Mark (BOM) in the response body.
  bom,

  /// No charset detected; defaulted to UTF-8.
  fallback,

  /// Charset detection was inconclusive.
  unknown,
}

/// The origin of a metadata candidate during extraction.
///
/// MetaLink scores candidates from multiple sources and selects the best
/// value for each field. [CandidateSource] identifies where a candidate came
/// from, which affects its priority in the scoring pipeline.
///
/// ### Source Priority (General)
/// 1. [openGraph] / [twitterCard] - Explicit social sharing metadata.
/// 2. [jsonLd] - Structured data with semantic context.
/// 3. [oEmbed] - Provider-supplied embed metadata.
/// 4. [standardMeta] / [linkRel] - Basic HTML meta and link tags.
/// 5. [manifest] - Web app manifest data.
/// 6. [heuristic] - Fallback values inferred from page content.
enum CandidateSource {
  /// Open Graph protocol (`og:*` meta tags).
  openGraph,

  /// Twitter Card metadata (`twitter:*` meta tags).
  twitterCard,

  /// Standard HTML meta tags (e.g., `<meta name="description">`).
  standardMeta,

  /// HTML `<link rel="...">` tags (icons, canonical, etc.).
  linkRel,

  /// JSON-LD structured data (`<script type="application/ld+json">`).
  jsonLd,

  /// oEmbed endpoint response.
  oEmbed,

  /// Web App Manifest (`manifest.json`).
  manifest,

  /// Fallback value inferred heuristically from page content.
  heuristic,
}

/// Identifies a specific field in [LinkMetadata].
///
/// Used in [FieldProvenance] to track which source provided the winning
/// value for each metadata field.
enum MetaField {
  /// The canonical URL of the page.
  canonicalUrl,

  /// The page title.
  title,

  /// The page description or summary.
  description,

  /// The site or publisher name.
  siteName,

  /// The locale/language code (e.g., `en_US`).
  locale,

  /// The content author.
  author,

  /// The original publication date.
  publishedAt,

  /// The last modification date.
  modifiedAt,

  /// Keywords or tags associated with the content.
  keywords,

  /// The content type (article, video, product, etc.).
  kind,

  /// Image candidates for the page.
  images,

  /// Icon/favicon candidates.
  icons,

  /// Video candidates.
  videos,

  /// Audio candidates.
  audios,

  /// oEmbed embed data.
  oembed,

  /// Web App Manifest data.
  manifest,

  /// JSON-LD structured data.
  structuredData,
}

/// Records which source provided a metadata field and how confident the match was.
///
/// The extraction pipeline scores candidates for each field. [FieldProvenance]
/// captures the winning source and its confidence score, enabling debugging
/// and quality analysis.
///
/// ### Fields
/// * [source] - The [CandidateSource] that provided this value.
/// * [score] - Confidence score between `0.0` (lowest) and `1.0` (highest).
/// * [evidence] - Optional raw value or context for debugging.
class FieldProvenance {
  /// Creates a [FieldProvenance] record.
  const FieldProvenance({
    required this.source,
    required this.score,
    this.evidence,
  });

  /// The source that provided this field value.
  final CandidateSource source;

  /// Confidence score for this candidate. Range: `0.0` to `1.0`.
  final double score;

  /// Optional raw evidence or context for debugging (e.g., the original tag).
  final String? evidence;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'source': source.name,
      'score': score,
      'evidence': evidence,
    };
  }

  factory FieldProvenance.fromJson(Map<String, dynamic> json) {
    return FieldProvenance(
      source: json.getEnum(
        'source',
        parser: EnumParsers.byName(CandidateSource.values),
        defaultValue: CandidateSource.heuristic,
      ),
      score: json.tryGetDouble('score') ?? 0.0,
      evidence: json.tryGetString('evidence'),
    );
  }
}

/// Provenance for one item in a collection-valued metadata field.
///
/// Unlike [FieldProvenance], which describes the winning field-level value,
/// this record keeps provenance attached to a concrete image, icon, video,
/// audio, or keyword after ranking and deduplication.
class ItemProvenance {
  const ItemProvenance({
    required this.itemKey,
    required this.provenance,
    this.contributors = const <FieldProvenance>[],
  });

  /// Stable identifier for the returned item, usually its normalized URL.
  final String itemKey;

  /// The candidate that supplied the retained item.
  final FieldProvenance provenance;

  /// Every candidate that supplied data retained in the merged item.
  ///
  /// The first value is normally [provenance]. Lower-ranked duplicates appear
  /// only when they filled an attribute missing from the leading candidate.
  final List<FieldProvenance> contributors;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'itemKey': itemKey,
      'provenance': provenance.toJson(),
      'contributors': contributors
          .map((contributor) => contributor.toJson())
          .toList(growable: false),
    };
  }

  factory ItemProvenance.fromJson(Map<String, dynamic> json) {
    final provenance = FieldProvenance.fromJson(
      json.getMap<String, dynamic>(
        'provenance',
        defaultValue: const <String, dynamic>{},
      ),
    );
    final contributorValues = Convert.tryToList<dynamic>(json['contributors']);
    final contributors = contributorValues == null
        ? <FieldProvenance>[provenance]
        : contributorValues
              .whereType<Map>()
              .map(
                (value) =>
                    FieldProvenance.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList(growable: false);

    return ItemProvenance(
      itemKey: json.getString('itemKey', defaultValue: ''),
      provenance: provenance,
      contributors: contributors,
    );
  }
}

/// One candidate considered by the ranking policy for a metadata field.
///
/// Candidate decisions are diagnostic data. They explain the effective score
/// used by the ranking policy without changing the stable metadata model.
class CandidateDecision {
  const CandidateDecision({
    required this.valueKey,
    required this.source,
    required this.score,
    required this.effectiveScore,
    required this.selected,
    this.evidence,
  });

  /// Stable, display-safe representation of the candidate value.
  final String valueKey;

  /// Source that emitted the candidate.
  final CandidateSource source;

  /// Base confidence score emitted by the extractor.
  final double score;

  /// Score after field-specific quality signals were applied.
  final double effectiveScore;

  /// Whether this candidate supplied a retained result.
  final bool selected;

  /// Optional extraction evidence.
  final String? evidence;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'valueKey': valueKey,
      'source': source.name,
      'score': score,
      'effectiveScore': effectiveScore,
      'selected': selected,
      'evidence': evidence,
    };
  }

  factory CandidateDecision.fromJson(Map<String, dynamic> json) {
    return CandidateDecision(
      valueKey: json.getString('valueKey', defaultValue: ''),
      source: json.getEnum(
        'source',
        parser: EnumParsers.byName(CandidateSource.values),
        defaultValue: CandidateSource.heuristic,
      ),
      score: json.tryGetDouble('score') ?? 0.0,
      effectiveScore: json.tryGetDouble('effectiveScore') ?? 0.0,
      selected: json.getBool('selected', defaultValue: false),
      evidence: json.tryGetString('evidence'),
    );
  }
}

/// Diagnostic information about the HTTP fetch phase.
///
/// [FetchDiagnostics] provides insight into what happened during the network
/// request, including redirects, response size, charset detection, and timing.
///
/// ### When to Use
/// Access via [ExtractionDiagnostics.fetch] to debug slow or failed extractions.
///
/// ### Example
/// ```dart
/// final result = await MetaLink.extract(url);
/// final fetch = result.diagnostics.fetch;
/// if (fetch != null) {
///   print('Fetched ${fetch.bytesRead} bytes in ${fetch.duration.inMilliseconds}ms');
///   print('Redirects: ${fetch.redirects.length}');
/// }
/// ```
class FetchDiagnostics {
  /// Creates a [FetchDiagnostics] record.
  const FetchDiagnostics({
    required this.requestedUrl,
    required this.finalUrl,
    required this.statusCode,
    required this.redirects,
    required this.bytesRead,
    required this.truncated,
    required this.detectedCharset,
    required this.charsetSource,
    required this.duration,
  });

  /// The URL that was originally requested.
  final Uri requestedUrl;

  /// The final URL after following redirects.
  final Uri finalUrl;

  /// The HTTP status code, or `null` if the request failed before receiving a response.
  final int? statusCode;

  /// The sequence of redirect hops from [requestedUrl] to [finalUrl].
  final List<RedirectHop> redirects;

  /// The number of bytes read from the response body.
  final int bytesRead;

  /// Whether the response was truncated due to size limits.
  final bool truncated;

  /// The detected character encoding (e.g., `utf-8`, `iso-8859-1`).
  final String? detectedCharset;

  /// How the charset was determined. See [CharsetSource].
  final CharsetSource charsetSource;

  /// Total time spent on the HTTP fetch operation.
  final Duration duration;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'requestedUrl': requestedUrl.toString(),
      'finalUrl': finalUrl.toString(),
      'statusCode': statusCode,
      'redirects': redirects.map((e) => e.toJson()).toList(),
      'bytesRead': bytesRead,
      'truncated': truncated,
      'detectedCharset': detectedCharset,
      'charsetSource': charsetSource.name,
      'durationMs': duration.inMilliseconds,
    };
  }

  factory FetchDiagnostics.fromJson(Map<String, dynamic> json) {
    return FetchDiagnostics(
      requestedUrl: json.getUri('requestedUrl', defaultValue: Uri()),
      finalUrl: json.getUri('finalUrl', defaultValue: Uri()),
      statusCode: json.tryGetInt('statusCode'),
      redirects: Convert.toList<RedirectHop>(
        json['redirects'],
        elementConverter: (e) =>
            RedirectHop.fromJson(Map<String, dynamic>.from(e as Map)),
        defaultValue: [],
      ),
      bytesRead: json.getInt('bytesRead', defaultValue: 0),
      truncated: json.getBool('truncated', defaultValue: false),
      detectedCharset: json.tryGetString('detectedCharset'),
      charsetSource: json.getEnum(
        'charsetSource',
        parser: EnumParsers.byName(CharsetSource.values),
        defaultValue: CharsetSource.unknown,
      ),
      duration: Duration(
        milliseconds: json.getInt('durationMs', defaultValue: 0),
      ),
    );
  }
}

/// Diagnostic information about the entire extraction process.
///
/// [ExtractionDiagnostics] provides a complete picture of how metadata was
/// extracted, including cache status, timing, and field provenance.
///
/// ### When to Use
/// Access via [ExtractionResult.diagnostics] to understand extraction behavior,
/// debug issues, or analyze metadata quality.
///
/// ### Example
/// ```dart
/// final result = await MetaLink.extract(url);
/// final diag = result.diagnostics;
/// if (diag != null) {
///   print('Cache hit: ${diag.cacheHit}');
///   print('Total time: ${diag.totalTime.inMilliseconds}ms');
///   for (final entry in diag.fieldProvenance.entries) {
///     print('${entry.key}: ${entry.value.source} (score: ${entry.value.score})');
///   }
/// }
/// ```
class ExtractionDiagnostics {
  /// Creates an [ExtractionDiagnostics] record.
  const ExtractionDiagnostics({
    required this.cacheHit,
    required this.totalTime,
    required this.fetch,
    required this.fieldProvenance,
    this.provenanceAvailable = true,
    this.itemProvenance = const <MetaField, List<ItemProvenance>>{},
    this.candidateDecisions = const <MetaField, List<CandidateDecision>>{},
  });

  /// Whether the result was served from cache.
  final bool cacheHit;

  /// Total time for the extraction operation (including cache lookup and fetch).
  final Duration totalTime;

  /// HTTP fetch diagnostics, or `null` if served from cache.
  final FetchDiagnostics? fetch;

  /// Maps each [MetaField] to its [FieldProvenance], showing which source won.
  final Map<MetaField, FieldProvenance> fieldProvenance;

  /// Whether provenance was retained by the producer of these diagnostics.
  ///
  /// A metadata-only cache entry sets this to `false`, so an empty provenance
  /// map is distinguishable from a fresh extraction that found no candidates.
  final bool provenanceAvailable;

  /// Provenance for each retained item in collection-valued metadata fields.
  final Map<MetaField, List<ItemProvenance>> itemProvenance;

  /// Ranked candidates considered for each field.
  ///
  /// This is empty when the producer did not request or retain decision data,
  /// such as a compact metadata-only cache entry.
  final Map<MetaField, List<CandidateDecision>> candidateDecisions;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'cacheHit': cacheHit,
      'totalTimeMs': totalTime.inMilliseconds,
      'fetch': fetch?.toJson(),
      'provenanceAvailable': provenanceAvailable,
      'fieldProvenance': <String, dynamic>{
        for (final entry in fieldProvenance.entries)
          entry.key.name: entry.value.toJson(),
      },
      'itemProvenance': <String, dynamic>{
        for (final entry in itemProvenance.entries)
          entry.key.name: entry.value
              .map((item) => item.toJson())
              .toList(growable: false),
      },
      'candidateDecisions': <String, dynamic>{
        for (final entry in candidateDecisions.entries)
          entry.key.name: entry.value
              .map((decision) => decision.toJson())
              .toList(growable: false),
      },
    };
  }

  factory ExtractionDiagnostics.fromJson(Map<String, dynamic> json) {
    final fpRaw = json.tryGetMap<String, dynamic>('fieldProvenance');
    final fp = <MetaField, FieldProvenance>{};
    final itemProvenance = <MetaField, List<ItemProvenance>>{};
    final candidateDecisions = <MetaField, List<CandidateDecision>>{};

    if (fpRaw != null) {
      for (final entry in fpRaw.entries) {
        final field = Convert.tryToEnum(
          entry.key,
          parser: EnumParsers.byName(MetaField.values),
        );
        if (field != null) {
          try {
            fp[field] = FieldProvenance.fromJson(entry.value);
          } catch (_) {
            // Skip invalid entries to keep diagnostics parsing resilient.
          }
        }
      }
    }

    final itemRaw = json.tryGetMap<String, dynamic>('itemProvenance');
    if (itemRaw != null) {
      for (final entry in itemRaw.entries) {
        final field = Convert.tryToEnum(
          entry.key,
          parser: EnumParsers.byName(MetaField.values),
        );
        final values = Convert.tryToList<dynamic>(entry.value);
        if (field == null || values == null) continue;

        itemProvenance[field] = values
            .whereType<Map>()
            .map(
              (item) =>
                  ItemProvenance.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList(growable: false);
      }
    }

    final decisionsRaw = json.tryGetMap<String, dynamic>('candidateDecisions');
    if (decisionsRaw != null) {
      for (final entry in decisionsRaw.entries) {
        final field = Convert.tryToEnum(
          entry.key,
          parser: EnumParsers.byName(MetaField.values),
        );
        final values = Convert.tryToList<dynamic>(entry.value);
        if (field == null || values == null) continue;

        candidateDecisions[field] = values
            .whereType<Map>()
            .map(
              (decision) => CandidateDecision.fromJson(
                Map<String, dynamic>.from(decision),
              ),
            )
            .toList(growable: false);
      }
    }

    return ExtractionDiagnostics(
      cacheHit: json.getBool('cacheHit', defaultValue: false),
      totalTime: Duration(
        milliseconds: json.getInt('totalTimeMs', defaultValue: 0),
      ),
      fetch: json.tryParse('fetch', FetchDiagnostics.fromJson),
      provenanceAvailable: json.getBool(
        'provenanceAvailable',
        defaultValue: true,
      ),
      fieldProvenance: fp,
      itemProvenance: itemProvenance,
      candidateDecisions: candidateDecisions,
    );
  }
}

/// Severity level for internal logging.
///
/// Used by [MetaLinkLogRecord] to categorize log messages.
enum MetaLinkLogLevel {
  /// Verbose debugging information.
  debug,

  /// Informational messages about normal operation.
  info,

  /// Non-fatal issues that may affect results.
  warning,

  /// Errors that caused extraction to fail.
  error,
}

/// A structured log record emitted during extraction.
///
/// [MetaLinkLogRecord] captures internal events for debugging and monitoring.
/// Pass a [MetaLinkLogSink] to `MetaLinkClient(logSink: ...)` to receive them.
///
/// ### Example
/// ```dart
/// final client = MetaLinkClient(
///   logSink: (record) {
///     print('[${record.level.name}] ${record.message}');
///   },
/// );
/// ```
class MetaLinkLogRecord {
  /// Creates a [MetaLinkLogRecord].
  const MetaLinkLogRecord({
    required this.level,
    required this.message,
    required this.timestamp,
    this.error,
    this.stackTrace,
    this.context,
  });

  /// The severity level of this log entry.
  final MetaLinkLogLevel level;

  /// The log message.
  final String message;

  /// When this log entry was created.
  final DateTime timestamp;

  /// The error that triggered this log, if any.
  final Object? error;

  /// Stack trace associated with [error], if available.
  final StackTrace? stackTrace;

  /// Additional context (e.g., URL, field name, etc.).
  final Map<String, Object?>? context;
}

/// Callback signature for receiving log records.
///
/// Pass this callback to the `MetaLinkClient` constructor.
typedef MetaLinkLogSink = void Function(MetaLinkLogRecord record);
