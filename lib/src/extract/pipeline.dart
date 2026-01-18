import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:metalink/src/options.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/icon.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/model/raw_metadata.dart';
import 'package:metalink/src/model/structured_data.dart';
import 'package:metalink/src/util/url_normalizer.dart';

import 'package:metalink/src/extract/candidate.dart';
import 'package:metalink/src/extract/extractors/manifest_enricher.dart';
import 'package:metalink/src/extract/extractors/oembed_enricher.dart';
import 'package:metalink/src/extract/url_resolver.dart';

/// Interface for metadata extractor stages in the pipeline.
///
/// Each stage examines the parsed HTML [Document] and adds scored
/// [Candidate] values to the [HtmlExtractContext]. The pipeline runs
/// all stages and then selects the best candidate for each field.
///
/// ### Implementing a Stage
/// ```dart
/// class MyExtractor implements HtmlMetadataExtractorStage {
///   @override
///   void extract(HtmlExtractContext context) {
///     final value = context.document.querySelector('...');
///     if (value != null) {
///       context.addTitle(value.text, source: CandidateSource.heuristic, score: 0.3);
///     }
///   }
/// }
/// ```
abstract interface class HtmlMetadataExtractorStage {
  /// Extracts metadata from the document and adds candidates to [context].
  void extract(HtmlExtractContext context);
}

/// Context passed to extractor stages during metadata extraction.
///
/// [HtmlExtractContext] provides access to the parsed HTML document and
/// methods for adding scored candidate values. Stages use `add*` methods
/// to contribute candidates for each metadata field.
///
/// ### Available Methods
/// * [addTitle], [addDescription], [addSiteName] - Text fields
/// * [addCanonicalUrl], [addImageUri], [addIconUri] - URL fields
/// * [addPublishedAt], [addModifiedAt] - Date fields
/// * [addKeyword], [addAuthor] - Content metadata
/// * [setKind], [setStructuredData] - Content type and structured data
class HtmlExtractContext {
  /// Creates an [HtmlExtractContext].
  HtmlExtractContext({
    required this.document,
    required this.baseUrl,
    required this.extractOptions,
    required this.urlResolver,
  });

  /// The parsed HTML document.
  final Document document;

  /// The base URL for resolving relative links.
  final Uri baseUrl;

  /// Extraction configuration options.
  final ExtractOptions extractOptions;

  /// Utility for resolving relative URLs.
  final UrlResolver urlResolver;

  // Internal candidate buckets written by stages and read by the pipeline merger.
  final List<Candidate<String>> _title = <Candidate<String>>[];
  final List<Candidate<String>> _description = <Candidate<String>>[];
  final List<Candidate<String>> _siteName = <Candidate<String>>[];
  final List<Candidate<String>> _locale = <Candidate<String>>[];

  final List<Candidate<Uri>> _canonicalUrl = <Candidate<Uri>>[];

  final List<Candidate<String>> _keywords = <Candidate<String>>[];
  final List<Candidate<String>> _author = <Candidate<String>>[];

  final List<Candidate<DateTime>> _publishedAt = <Candidate<DateTime>>[];
  final List<Candidate<DateTime>> _modifiedAt = <Candidate<DateTime>>[];

  final List<Candidate<ImageCandidate>> _images = <Candidate<ImageCandidate>>[];
  final List<Candidate<IconCandidate>> _icons = <Candidate<IconCandidate>>[];
  final List<Candidate<Uri>> _videos = <Candidate<Uri>>[];
  final List<Candidate<Uri>> _audios = <Candidate<Uri>>[];

  final List<Candidate<OEmbedEndpoint>> _oembedEndpoints =
      <Candidate<OEmbedEndpoint>>[];
  final List<Candidate<Uri>> _manifestUrls = <Candidate<Uri>>[];

  final List<Candidate<LinkKind>> _kinds = <Candidate<LinkKind>>[];

  Candidate<StructuredDataGraph>? _structuredData;

  // Public stage API for adding scored candidates and provenance hints.

  void addTitle(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _title.add(
        Candidate(value: v, source: source, score: score, evidence: evidence));
  }

  void addDescription(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _description.add(
        Candidate(value: v, source: source, score: score, evidence: evidence));
  }

  void addSiteName(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _siteName.add(
        Candidate(value: v, source: source, score: score, evidence: evidence));
  }

  void addLocale(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _locale.add(
        Candidate(value: v, source: source, score: score, evidence: evidence));
  }

  void addCanonicalUrl(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    _canonicalUrl.add(
        Candidate(value: u, source: source, score: score, evidence: evidence));
  }

  void addKeyword(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _keywords.add(
        Candidate(value: v, source: source, score: score, evidence: evidence));
  }

  void addAuthor(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _author.add(
        Candidate(value: v, source: source, score: score, evidence: evidence));
  }

  void addPublishedAt(
    DateTime value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _publishedAt.add(Candidate(
        value: value.toUtc(),
        source: source,
        score: score,
        evidence: evidence));
  }

  void addModifiedAt(
    DateTime value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _modifiedAt.add(Candidate(
        value: value.toUtc(),
        source: source,
        score: score,
        evidence: evidence));
  }

  void addImageUri(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    _images.add(
      Candidate(
        value: ImageCandidate(url: u),
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  void addImageCandidate(
    ImageCandidate value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value.url);
    if (u == null) return;
    final img = ImageCandidate(
      url: u,
      width: value.width,
      height: value.height,
      mimeType: value.mimeType,
      alt: value.alt,
      byteSize: value.byteSize,
    );
    _images.add(
      Candidate(
        value: img,
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  void addIconUri(
    Uri value, {
    String? rel,
    String? sizes,
    String? type,
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    final icon = IconCandidate(url: u, rel: rel, sizes: sizes, type: type);
    _icons.add(Candidate(
        value: icon, source: source, score: score, evidence: evidence));
  }

  void addVideoUri(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    _videos.add(
        Candidate(value: u, source: source, score: score, evidence: evidence));
  }

  void addAudioUri(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    _audios.add(
        Candidate(value: u, source: source, score: score, evidence: evidence));
  }

  void addOEmbedEndpoint(
    OEmbedEndpoint endpoint, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(endpoint.url);
    if (u == null) return;
    _oembedEndpoints.add(
      Candidate(
        value: OEmbedEndpoint(url: u, format: endpoint.format),
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  void addManifestUrl(
    Uri manifestUrl, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(manifestUrl);
    if (u == null) return;
    _manifestUrls.add(
        Candidate(value: u, source: source, score: score, evidence: evidence));
  }

  void setKind(
    LinkKind kind, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _kinds.add(Candidate(
        value: kind, source: source, score: score, evidence: evidence));
  }

  void setStructuredData(
    StructuredDataGraph graph, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final candidate = Candidate(
        value: graph, source: source, score: score, evidence: evidence);
    final current = _structuredData;
    if (current == null || candidate.score > current.score) {
      _structuredData = candidate;
    }
  }

  // Helpers to normalize inputs before scoring to keep candidates consistent.

  String? _normText(String input) {
    final v =
        input.replaceAll('\u0000', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (v.isEmpty) return null;
    return v;
  }

  Uri? _absHttpUri(Uri input) {
    try {
      final abs = input.hasScheme ? input : baseUrl.resolveUri(input);
      final scheme = abs.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return null;
      // Remove fragments so asset URLs dedupe consistently across sources.
      return UrlNormalizer.removeFragment(abs);
    } catch (_) {
      return null;
    }
  }
}

/// The output of running the extraction pipeline.
///
/// [PipelineOutput] contains the extracted metadata, provenance information
/// for each field, and any warnings or errors encountered during extraction.
class PipelineOutput {
  /// Creates a [PipelineOutput].
  const PipelineOutput({
    required this.metadata,
    required this.fieldProvenance,
    this.raw,
    this.warnings = const [],
    this.errors = const [],
  });

  /// The extracted metadata.
  final LinkMetadata metadata;

  /// Maps each [MetaField] to its [FieldProvenance], showing which source won.
  final Map<MetaField, FieldProvenance> fieldProvenance;

  /// Raw HTML metadata, if [ExtractOptions.includeRawMetadata] was enabled.
  final RawMetadata? raw;

  /// Non-fatal issues encountered during extraction.
  final List<MetaLinkWarning> warnings;

  /// Fatal errors that prevented extraction.
  final List<MetaLinkError> errors;
}

/// The core metadata extraction pipeline.
///
/// [ExtractPipeline] orchestrates the extraction process by running a series
/// of [HtmlMetadataExtractorStage] implementations against the parsed HTML.
/// Each stage adds scored candidates, and the pipeline selects the best
/// candidate for each metadata field.
///
/// ### Pipeline Flow
/// 1. Parse HTML into a DOM
/// 2. Detect base URL from `<base href>`
/// 3. Run all extractor stages
/// 4. Merge candidates by selecting highest scores
/// 5. Optionally enrich with oEmbed and manifest data
/// 6. Return [PipelineOutput] with metadata and provenance
///
/// ### Error Handling
/// Individual stage failures do not abort the pipeline. Errors are captured
/// in [PipelineOutput.warnings] so extraction continues with partial data.
class ExtractPipeline {
  /// Creates an [ExtractPipeline] with the given extractor stages.
  ///
  /// ### Parameters
  /// * [stages] - The list of extractor stages to run (in order).
  /// * [urlResolver] - Utility for resolving relative URLs.
  /// * [logSink] - Optional callback for internal logging.
  ExtractPipeline({
    required List<HtmlMetadataExtractorStage> stages,
    UrlResolver urlResolver = const UrlResolver(),
    MetaLinkLogSink? logSink,
  })  : _stages = List<HtmlMetadataExtractorStage>.unmodifiable(stages),
        _urlResolver = urlResolver,
        _logSink = logSink;

  final List<HtmlMetadataExtractorStage> _stages;
  final UrlResolver _urlResolver;
  final MetaLinkLogSink? _logSink;

  Future<PipelineOutput> run({
    required HtmlFetchResult page,
    required Fetcher fetcher,
    required FetchOptions fetchOptions,
    required ExtractOptions extractOptions,
  }) async {
    final warnings = <MetaLinkWarning>[];
    final errors = <MetaLinkError>[];
    final fieldProv = <MetaField, FieldProvenance>{};

    // Decode body bytes if text was not provided so parsing can still proceed.
    String? html = page.bodyText;
    if (html == null) {
      try {
        html = utf8.decode(page.bodyBytes, allowMalformed: true);
      } catch (e, st) {
        errors.add(
          MetaLinkError(
            code: MetaLinkErrorCode.decode,
            message: 'Failed to decode HTML body.',
            uri: page.finalUrl,
            cause: e,
            stackTrace: st,
          ),
        );
        return PipelineOutput(
          metadata: _emptyMetadata(page),
          fieldProvenance: fieldProv,
          raw: null,
          warnings: warnings,
          errors: errors,
        );
      }
    }

    // Parse HTML into a DOM; parsing failures end the pipeline for this page.
    Document document;
    try {
      document = html_parser.parse(html);
    } catch (e, st) {
      errors.add(
        MetaLinkError(
          code: MetaLinkErrorCode.parse,
          message: 'Failed to parse HTML.',
          uri: page.finalUrl,
          cause: e,
          stackTrace: st,
        ),
      );
      return PipelineOutput(
        metadata: _emptyMetadata(page),
        fieldProvenance: fieldProv,
        raw: null,
        warnings: warnings,
        errors: errors,
      );
    }

    // Resolve base URL using <base href> so relative links resolve correctly.
    final baseUrl = _detectBaseUrl(document, page.finalUrl);

    // Capture raw tags only when requested to avoid unnecessary memory use.
    final RawMetadata? raw = extractOptions.includeRawMetadata
        ? RawMetadata.fromDocument(document)
        : null;

    final ctx = HtmlExtractContext(
      document: document,
      baseUrl: baseUrl,
      extractOptions: extractOptions,
      urlResolver: _urlResolver,
    );

    // Run stages with error isolation so one extractor cannot abort the pipeline.
    for (final stage in _stages) {
      try {
        stage.extract(ctx);
      } catch (e, st) {
        warnings.add(
          MetaLinkWarning(
            code: MetaLinkWarningCode.partialParse,
            message: 'Extractor stage failed: ${stage.runtimeType}',
            uri: baseUrl,
            cause: e,
          ),
        );
        _log(
          MetaLinkLogLevel.warning,
          'Extractor stage threw an exception: ${stage.runtimeType}',
          error: e,
          stackTrace: st,
          context: <String, Object?>{'url': baseUrl.toString()},
        );
      }
    }

    // Merge candidates into final fields and record provenance for each winner.
    final canonical = _best(ctx._canonicalUrl);
    if (canonical != null) {
      fieldProv[MetaField.canonicalUrl] = _prov(canonical);
    }

    String? title = _best(ctx._title)?.value;
    final bestTitle = _best(ctx._title);
    if (bestTitle != null) {
      title = bestTitle.value;
      fieldProv[MetaField.title] = _prov(bestTitle);
    }

    String? description = _best(ctx._description)?.value;
    final bestDesc = _best(ctx._description);
    if (bestDesc != null) {
      description = bestDesc.value;
      fieldProv[MetaField.description] = _prov(bestDesc);
    }

    String? siteName = _best(ctx._siteName)?.value;
    final bestSite = _best(ctx._siteName);
    if (bestSite != null) {
      siteName = bestSite.value;
      fieldProv[MetaField.siteName] = _prov(bestSite);
    }

    String? locale = _best(ctx._locale)?.value;
    final bestLocale = _best(ctx._locale);
    if (bestLocale != null) {
      locale = bestLocale.value;
      fieldProv[MetaField.locale] = _prov(bestLocale);
    }

    String? author = _best(ctx._author)?.value;
    final bestAuthor = _best(ctx._author);
    if (bestAuthor != null) {
      author = bestAuthor.value;
      fieldProv[MetaField.author] = _prov(bestAuthor);
    }

    DateTime? publishedAt = _best(ctx._publishedAt)?.value;
    final bestPub = _best(ctx._publishedAt);
    if (bestPub != null) {
      publishedAt = bestPub.value;
      fieldProv[MetaField.publishedAt] = _prov(bestPub);
    }

    DateTime? modifiedAt = _best(ctx._modifiedAt)?.value;
    final bestMod = _best(ctx._modifiedAt);
    if (bestMod != null) {
      modifiedAt = bestMod.value;
      fieldProv[MetaField.modifiedAt] = _prov(bestMod);
    }

    final keywords = _collectKeywords(ctx._keywords);
    final bestKw = _best(ctx._keywords);
    if (keywords.isNotEmpty && bestKw != null) {
      fieldProv[MetaField.keywords] = _prov(bestKw);
    }

    final kindCandidate = _best(ctx._kinds);
    final kind = kindCandidate?.value ?? LinkKind.unknown;
    if (kindCandidate != null && kindCandidate.value != LinkKind.unknown) {
      fieldProv[MetaField.kind] = _prov(kindCandidate);
    }

    final images = _collectTopUniqueImages(
      ctx._images,
      max: extractOptions.maxImages,
    );
    final bestImg = _best(ctx._images);
    if (images.isNotEmpty && bestImg != null) {
      fieldProv[MetaField.images] = _prov(bestImg);
    }

    final videos = _collectTopUniqueUris(
      ctx._videos,
      max: extractOptions.maxVideos,
    ).map((c) => VideoCandidate(url: c.value)).toList(growable: false);
    final bestVid = _best(ctx._videos);
    if (videos.isNotEmpty && bestVid != null) {
      fieldProv[MetaField.videos] = _prov(bestVid);
    }

    final audios = _collectTopUniqueUris(
      ctx._audios,
      max: extractOptions.maxAudios,
    ).map((c) => AudioCandidate(url: c.value)).toList(growable: false);
    final bestAud = _best(ctx._audios);
    if (audios.isNotEmpty && bestAud != null) {
      fieldProv[MetaField.audios] = _prov(bestAud);
    }

    StructuredDataGraph? structuredData = ctx._structuredData?.value;
    if (ctx._structuredData != null) {
      fieldProv[MetaField.structuredData] = _prov(ctx._structuredData!);
    }

    // Optionally enrich with remote oEmbed or manifest data after local extraction.
    OEmbedData? oembed;
    if (extractOptions.enableOEmbed) {
      final endpointCandidate = _best(ctx._oembedEndpoints);
      if (endpointCandidate != null) {
        try {
          oembed = await const OEmbedEnricher().fetchAndParse(
            fetcher: fetcher,
            fetchOptions: fetchOptions,
            endpoint: endpointCandidate.value,
          );
          if (oembed != null) {
            fieldProv[MetaField.oembed] = const FieldProvenance(
              source: CandidateSource.oEmbed,
              score: _scoreOembedProvenance,
              evidence: 'oEmbed fetch succeeded',
            );

            // Fill missing fields from oEmbed without overwriting stronger sources.
            if ((title == null || title.trim().isEmpty) &&
                oembed.title != null &&
                oembed.title!.trim().isNotEmpty) {
              title = oembed.title!.trim();
              fieldProv[MetaField.title] = const FieldProvenance(
                source: CandidateSource.oEmbed,
                score: _scoreOembedTitle,
                evidence: 'Filled from oEmbed.title',
              );
            }
            if ((author == null || author.trim().isEmpty) &&
                oembed.authorName != null &&
                oembed.authorName!.trim().isNotEmpty) {
              author = oembed.authorName!.trim();
              fieldProv[MetaField.author] = const FieldProvenance(
                source: CandidateSource.oEmbed,
                score: _scoreOembedAuthor,
                evidence: 'Filled from oEmbed.author_name',
              );
            }
            if ((siteName == null || siteName.trim().isEmpty) &&
                oembed.providerName != null &&
                oembed.providerName!.trim().isNotEmpty) {
              siteName = oembed.providerName!.trim();
              fieldProv[MetaField.siteName] = const FieldProvenance(
                source: CandidateSource.oEmbed,
                score: _scoreOembedSiteName,
                evidence: 'Filled from oEmbed.provider_name',
              );
            }
          } else {
            warnings.add(
              MetaLinkWarning(
                code: MetaLinkWarningCode.oembedFailed,
                message: 'oEmbed endpoint did not return usable data.',
                uri: endpointCandidate.value.url,
              ),
            );
          }
        } catch (e, st) {
          warnings.add(
            MetaLinkWarning(
              code: MetaLinkWarningCode.oembedFailed,
              message: 'Failed to fetch/parse oEmbed data.',
              uri: endpointCandidate.value.url,
              cause: e,
            ),
          );
          _log(
            MetaLinkLogLevel.warning,
            'oEmbed enrichment failed.',
            error: e,
            stackTrace: st,
            context: <String, Object?>{
              'endpoint': endpointCandidate.value.url.toString()
            },
          );
        }
      }
    }

    WebAppManifestData? manifest;
    if (extractOptions.enableManifest) {
      final manifestCandidate = _best(ctx._manifestUrls);
      if (manifestCandidate != null) {
        try {
          manifest = await const ManifestEnricher().fetchAndParse(
            fetcher: fetcher,
            fetchOptions: fetchOptions,
            manifestUrl: manifestCandidate.value,
          );
          if (manifest != null) {
            fieldProv[MetaField.manifest] = const FieldProvenance(
              source: CandidateSource.manifest,
              score: _scoreManifestProvenance,
              evidence: 'Manifest fetch succeeded',
            );

            // Fill missing siteName or title from manifest without overwriting.
            if ((siteName == null || siteName.trim().isEmpty) &&
                manifest.name != null &&
                manifest.name!.trim().isNotEmpty) {
              siteName = manifest.name!.trim();
              fieldProv[MetaField.siteName] = const FieldProvenance(
                source: CandidateSource.manifest,
                score: _scoreManifestSiteName,
                evidence: 'Filled from manifest.name',
              );
            }
            if ((title == null || title.trim().isEmpty) &&
                manifest.shortName != null &&
                manifest.shortName!.trim().isNotEmpty) {
              title = manifest.shortName!.trim();
              fieldProv[MetaField.title] = const FieldProvenance(
                source: CandidateSource.manifest,
                score: _scoreManifestTitle,
                evidence: 'Filled from manifest.short_name',
              );
            }
          } else {
            warnings.add(
              MetaLinkWarning(
                code: MetaLinkWarningCode.manifestFailed,
                message: 'Manifest URL did not return usable data.',
                uri: manifestCandidate.value,
              ),
            );
          }
        } catch (e, st) {
          warnings.add(
            MetaLinkWarning(
              code: MetaLinkWarningCode.manifestFailed,
              message: 'Failed to fetch/parse web app manifest.',
              uri: manifestCandidate.value,
              cause: e,
            ),
          );
          _log(
            MetaLinkLogLevel.warning,
            'Manifest enrichment failed.',
            error: e,
            stackTrace: st,
            context: <String, Object?>{
              'manifestUrl': manifestCandidate.value.toString()
            },
          );
        }
      }
    }

    if (manifest != null && manifest.icons.isNotEmpty) {
      for (final icon in manifest.icons) {
        final scheme = icon.src.scheme.toLowerCase();
        if (scheme != 'http' && scheme != 'https') continue;
        ctx._icons.add(
          Candidate(
            value: IconCandidate(
              url: icon.src,
              sizes: icon.sizes,
              type: icon.type,
              rel: 'manifest',
            ),
            source: CandidateSource.manifest,
            score: _scoreManifestIconCandidate,
            evidence: 'manifest.icons',
          ),
        );
      }
    }

    final icons = _collectTopUniqueIcons(
      ctx._icons,
      max: extractOptions.maxIcons,
    ).map((c) => c.value).toList(growable: false);
    final bestIcon = _best(ctx._icons);
    if (icons.isNotEmpty && bestIcon != null) {
      fieldProv[MetaField.icons] = _prov(bestIcon);
    }

    // Adjust final image list to include oEmbed thumbnails when missing.
    final imagesFinal = _finalizeImagesWithOEmbedThumbnail(
      images,
      oembed,
      max: extractOptions.maxImages,
    );

    // Build the normalized metadata object from the selected candidates.
    final metadata = LinkMetadata(
      originalUrl: page.originalUrl,
      resolvedUrl: page.finalUrl,
      canonicalUrl: canonical?.value,
      title: title,
      description: description,
      siteName: siteName,
      locale: locale,
      kind: kind,
      images: imagesFinal,
      icons: icons,
      videos: videos,
      audios: audios,
      publishedAt: publishedAt,
      modifiedAt: modifiedAt,
      author: author,
      keywords: keywords,
      oembed: oembed,
      manifest: manifest,
      structuredData: structuredData,
    );

    return PipelineOutput(
      metadata: metadata,
      fieldProvenance: fieldProv,
      raw: raw,
      warnings: warnings,
      errors: errors,
    );
  }

  // Private helpers for selection, normalization, and logging.

  LinkMetadata _emptyMetadata(HtmlFetchResult page) {
    return LinkMetadata(
      originalUrl: page.originalUrl,
      resolvedUrl: page.finalUrl,
      kind: LinkKind.unknown,
      images: const [],
      icons: const [],
      videos: const [],
      audios: const [],
      keywords: const [],
    );
  }

  void _log(
    MetaLinkLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) {
    final sink = _logSink;
    if (sink == null) return;
    try {
      sink(
        MetaLinkLogRecord(
          level: level,
          message: message,
          timestamp: DateTime.now().toUtc(),
          error: error,
          stackTrace: stackTrace,
          context: context,
        ),
      );
    } catch (_) {
      // Logging must never throw so extraction can continue safely.
    }
  }

  Uri _detectBaseUrl(Document doc, Uri fallback) {
    try {
      final baseEl = doc.querySelector('base[href]');
      final href = baseEl?.attributes['href']?.trim();
      if (href == null || href.isEmpty) return fallback;
      final u = Uri.tryParse(href);
      if (u == null) return fallback;
      final resolved = u.hasScheme ? u : fallback.resolveUri(u);
      final scheme = resolved.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return fallback;
      return resolved;
    } catch (_) {
      return fallback;
    }
  }

  FieldProvenance _prov<T>(Candidate<T> c) {
    return FieldProvenance(
        source: c.source, score: c.score, evidence: c.evidence);
  }

  Candidate<T>? _best<T>(List<Candidate<T>> candidates) {
    Candidate<T>? best;
    for (final c in candidates) {
      if (best == null || c.score > best.score) {
        best = c;
      }
    }
    return best;
  }

  List<Candidate<Uri>> _collectTopUniqueUris(
    List<Candidate<Uri>> candidates, {
    required int max,
  }) {
    if (candidates.isEmpty || max <= 0) return const [];

    final indexed = <_IndexedCandidate<Uri>>[];
    for (var i = 0; i < candidates.length; i++) {
      indexed.add(_IndexedCandidate(index: i, candidate: candidates[i]));
    }
    indexed.sort((a, b) {
      final s = b.candidate.score.compareTo(a.candidate.score);
      if (s != 0) return s;
      return a.index.compareTo(b.index);
    });

    final seen = <String>{};
    final out = <Candidate<Uri>>[];
    for (final item in indexed) {
      if (out.length >= max) break;
      final uri = UrlNormalizer.removeFragment(item.candidate.value);
      final key = uri.toString();
      if (seen.add(key)) {
        out.add(
          Candidate(
            value: uri,
            source: item.candidate.source,
            score: item.candidate.score,
            evidence: item.candidate.evidence,
          ),
        );
      }
    }
    return out;
  }

  List<ImageCandidate> _collectTopUniqueImages(
    List<Candidate<ImageCandidate>> candidates, {
    required int max,
  }) {
    if (candidates.isEmpty || max <= 0) return const [];

    final indexed = <_IndexedCandidate<ImageCandidate>>[];
    for (var i = 0; i < candidates.length; i++) {
      indexed.add(_IndexedCandidate(index: i, candidate: candidates[i]));
    }
    indexed.sort((a, b) {
      final s = b.candidate.score.compareTo(a.candidate.score);
      if (s != 0) return s;
      return a.index.compareTo(b.index);
    });

    final seen = <String>{};
    final out = <ImageCandidate>[];
    for (final item in indexed) {
      if (out.length >= max) break;
      final img = item.candidate.value;
      // Dedupe by URL string so repeated candidates do not dominate the list.
      final key = img.url.toString();
      if (seen.add(key)) {
        out.add(img);
      }
    }
    return out;
  }

  List<Candidate<IconCandidate>> _collectTopUniqueIcons(
    List<Candidate<IconCandidate>> candidates, {
    required int max,
  }) {
    if (candidates.isEmpty || max <= 0) return const [];

    final indexed = <_IndexedCandidate<IconCandidate>>[];
    for (var i = 0; i < candidates.length; i++) {
      indexed.add(_IndexedCandidate(index: i, candidate: candidates[i]));
    }
    indexed.sort((a, b) {
      final s = b.candidate.score.compareTo(a.candidate.score);
      if (s != 0) return s;
      return a.index.compareTo(b.index);
    });

    final seen = <String>{};
    final out = <Candidate<IconCandidate>>[];
    for (final item in indexed) {
      if (out.length >= max) break;
      final icon = item.candidate.value;
      final key = icon.url.toString();
      if (seen.add(key)) {
        out.add(item.candidate);
      }
    }
    return out;
  }

  List<String> _collectKeywords(List<Candidate<String>> candidates) {
    if (candidates.isEmpty) return const [];
    final indexed = <_IndexedCandidate<String>>[];
    for (var i = 0; i < candidates.length; i++) {
      indexed.add(_IndexedCandidate(index: i, candidate: candidates[i]));
    }
    indexed.sort((a, b) {
      final s = b.candidate.score.compareTo(a.candidate.score);
      if (s != 0) return s;
      return a.index.compareTo(b.index);
    });

    const maxKeywords = _maxKeywords;
    final seen = <String>{};
    final out = <String>[];

    for (final item in indexed) {
      if (out.length >= maxKeywords) break;
      final k = item.candidate.value.trim();
      if (k.isEmpty) continue;
      final key = k.toLowerCase();
      if (seen.add(key)) out.add(k);
    }
    return out;
  }

  List<ImageCandidate> _finalizeImagesWithOEmbedThumbnail(
    List<ImageCandidate> baseImages,
    OEmbedData? oembed, {
    required int max,
  }) {
    if (max <= 0) return const [];
    if (oembed?.thumbnailUrl == null) {
      return baseImages.length <= max
          ? baseImages
          : baseImages.take(max).toList(growable: false);
    }

    final thumb = oembed!.thumbnailUrl!;
    final seen = <String>{};
    final out = <ImageCandidate>[];

    // Prefer the oEmbed thumbnail first to improve preview selection.
    final thumbKey = thumb.toString();
    if (seen.add(thumbKey)) {
      out.add(ImageCandidate(
        url: thumb,
        width: oembed.thumbnailWidth,
        height: oembed.thumbnailHeight,
      ));
    }

    for (final img in baseImages) {
      if (out.length >= max) break;
      final key = img.url.toString();
      if (seen.add(key)) out.add(img);
    }

    return out;
  }
}

class _IndexedCandidate<T> {
  _IndexedCandidate({
    required this.index,
    required this.candidate,
  });

  final int index;
  final Candidate<T> candidate;
}

const int _maxKeywords = 25;

const double _scoreOembedProvenance = 0.8;
const double _scoreOembedTitle = 0.7;
const double _scoreOembedAuthor = 0.7;
const double _scoreOembedSiteName = 0.65;

const double _scoreManifestProvenance = 0.75;
const double _scoreManifestSiteName = 0.6;
const double _scoreManifestTitle = 0.55;
const double _scoreManifestIconCandidate = 0.72;
