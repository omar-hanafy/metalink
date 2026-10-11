import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:metalink/src/extract/candidate.dart';
import 'package:metalink/src/extract/extractors/manifest_enricher.dart';
import 'package:metalink/src/extract/extractors/oembed_enricher.dart';
import 'package:metalink/src/extract/ranking.dart';
import 'package:metalink/src/extract/url_resolver.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/icon.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/model/raw_metadata.dart';
import 'package:metalink/src/model/structured_data.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/html_utils.dart';
import 'package:metalink/src/util/url_normalizer.dart';

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
    required this.documentUrl,
    required this.baseUrl,
    required this.extractOptions,
    required this.urlResolver,
  });

  /// The parsed HTML document.
  final Document document;

  /// The final response URL identifying the document itself.
  ///
  /// This remains distinct from [baseUrl], which may be changed by an HTML
  /// `<base href>` element and is used only for resolving relative URLs.
  final Uri documentUrl;

  /// The base URL for resolving relative links.
  final Uri baseUrl;

  /// Extraction configuration options.
  final ExtractOptions extractOptions;

  /// Utility for resolving relative URLs.
  final UrlResolver urlResolver;

  /// The `<meta>` elements of [document], indexed once and shared by every
  /// stage.
  ///
  /// Stages should read meta tags through this index rather than CSS
  /// selectors so that `name`, `property`, and `http-equiv` keys match ASCII
  /// case-insensitively and blank duplicates are skipped consistently. The
  /// index is built on first access.
  late final MetaTagIndex metaTags = MetaTagIndex.fromDocument(document);

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
  final List<Candidate<VideoCandidate>> _videos = <Candidate<VideoCandidate>>[];
  final List<Candidate<AudioCandidate>> _audios = <Candidate<AudioCandidate>>[];

  final List<Candidate<OEmbedEndpoint>> _oembedEndpoints =
      <Candidate<OEmbedEndpoint>>[];
  final List<Candidate<Uri>> _manifestUrls = <Candidate<Uri>>[];

  final List<Candidate<LinkKind>> _kinds = <Candidate<LinkKind>>[];

  final List<Candidate<StructuredDataGraph>> _structuredData =
      <Candidate<StructuredDataGraph>>[];
  final List<MetaLinkWarning> _warnings = <MetaLinkWarning>[];

  // Public stage API for adding scored candidates and provenance hints.

  /// Adds a title candidate.
  ///
  /// NUL characters are removed and whitespace runs are collapsed before the
  /// value is stored; a value that is blank afterwards is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addTitle(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _title.add(
      Candidate(value: v, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a description candidate.
  ///
  /// NUL characters are removed and whitespace runs are collapsed before the
  /// value is stored; a value that is blank afterwards is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addDescription(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _description.add(
      Candidate(value: v, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a site or publisher name candidate.
  ///
  /// NUL characters are removed and whitespace runs are collapsed before the
  /// value is stored; a value that is blank afterwards is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addSiteName(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _siteName.add(
      Candidate(value: v, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a locale or language candidate, such as `en_US` or `fr`.
  ///
  /// The value is not validated as a language tag. NUL characters are removed
  /// and whitespace runs are collapsed before the value is stored; a value
  /// that is blank afterwards is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addLocale(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _locale.add(
      Candidate(value: v, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a canonical URL candidate.
  ///
  /// A relative [value] resolves against [baseUrl]. The value is ignored unless
  /// it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addCanonicalUrl(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    _canonicalUrl.add(
      Candidate(value: u, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds one keyword candidate.
  ///
  /// Call once per keyword. The pipeline keeps the highest-ranked spelling of
  /// each keyword, compared case-insensitively, up to 25 keywords.
  ///
  /// NUL characters are removed and whitespace runs are collapsed before the
  /// value is stored; a value that is blank afterwards is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addKeyword(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _keywords.add(
      Candidate(value: v, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds an author candidate.
  ///
  /// NUL characters are removed and whitespace runs are collapsed before the
  /// value is stored; a value that is blank afterwards is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addAuthor(
    String value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final v = _normText(value);
    if (v == null) return;
    _author.add(
      Candidate(value: v, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a publication time candidate, stored in UTC.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addPublishedAt(
    DateTime value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _publishedAt.add(
      Candidate(
        value: value.toUtc(),
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  /// Adds a last-modified time candidate, stored in UTC.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addModifiedAt(
    DateTime value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _modifiedAt.add(
      Candidate(
        value: value.toUtc(),
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  /// Adds an image candidate that has only a URL.
  ///
  /// Use [addImageCandidate] when dimensions, MIME type, or alt text are
  /// known.
  ///
  /// A relative [value] resolves against [baseUrl]. The value is ignored unless
  /// it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
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

  /// Adds an image candidate with its declared attributes.
  ///
  /// The URL of [value] is resolved against [baseUrl]; the candidate is ignored
  /// unless it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed. Other attributes are kept as given.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
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
      Candidate(value: img, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds an icon candidate with its optional `rel`, `sizes`, and `type`
  /// hints.
  ///
  /// A relative [value] resolves against [baseUrl]. The value is ignored unless
  /// it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
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
    _icons.add(
      Candidate(value: icon, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a video candidate that has only a URL.
  ///
  /// Use [addVideoCandidate] when dimensions or a MIME type are known.
  ///
  /// A relative [value] resolves against [baseUrl]. The value is ignored unless
  /// it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addVideoUri(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    addVideoCandidate(
      VideoCandidate(url: u),
      source: source,
      score: score,
      evidence: evidence,
    );
  }

  /// Adds a video candidate with its declared dimensions and MIME type.
  ///
  /// The URL of [value] is resolved against [baseUrl]; the candidate is ignored
  /// unless it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addVideoCandidate(
    VideoCandidate value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value.url);
    if (u == null) return;
    _videos.add(
      Candidate(
        value: VideoCandidate(
          url: u,
          width: value.width,
          height: value.height,
          mimeType: value.mimeType,
        ),
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  /// Adds an audio candidate that has only a URL.
  ///
  /// Use [addAudioCandidate] when a MIME type is known.
  ///
  /// A relative [value] resolves against [baseUrl]. The value is ignored unless
  /// it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addAudioUri(
    Uri value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value);
    if (u == null) return;
    addAudioCandidate(
      AudioCandidate(url: u),
      source: source,
      score: score,
      evidence: evidence,
    );
  }

  /// Adds an audio candidate with its declared MIME type.
  ///
  /// The URL of [value] is resolved against [baseUrl]; the candidate is ignored
  /// unless it becomes an absolute HTTP(S) URL with a host, and any fragment is
  /// removed.
  ///
  /// Items with the same URL are merged after ranking: the highest-ranked
  /// occurrence is kept and its missing attributes are filled from the others.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addAudioCandidate(
    AudioCandidate value, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(value.url);
    if (u == null) return;
    _audios.add(
      Candidate(
        value: AudioCandidate(url: u, mimeType: value.mimeType),
        source: source,
        score: score,
        evidence: evidence,
      ),
    );
  }

  /// Records a non-fatal extractor diagnostic without aborting other stages.
  void addWarning(MetaLinkWarning warning) => _warnings.add(warning);

  /// Adds a discovered oEmbed endpoint candidate.
  ///
  /// When [ExtractOptions.enableOEmbed] is set, [ExtractPipeline.run] fetches
  /// only the highest-ranked endpoint after all stages finish and feeds its
  /// title, author, provider, and thumbnail back as candidates.
  /// [ExtractPipeline.runLocal] never fetches it. The endpoint URL must be an
  /// absolute HTTP(S) URL with a host, or the candidate is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
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

  /// Adds a web app manifest URL candidate.
  ///
  /// When [ExtractOptions.enableManifest] is set, [ExtractPipeline.run]
  /// fetches only the highest-ranked manifest after all stages finish and
  /// feeds its name, short name, and icons back as candidates.
  /// [ExtractPipeline.runLocal] never fetches it. The URL must be an absolute
  /// HTTP(S) URL with a host, or the candidate is ignored.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void addManifestUrl(
    Uri manifestUrl, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    final u = _absHttpUri(manifestUrl);
    if (u == null) return;
    _manifestUrls.add(
      Candidate(value: u, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a [LinkKind] candidate.
  ///
  /// Despite its name this does not overwrite earlier calls; every call adds a
  /// competing candidate. A winning [LinkKind.unknown] is reported without
  /// field provenance.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void setKind(
    LinkKind kind, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _kinds.add(
      Candidate(value: kind, source: source, score: score, evidence: evidence),
    );
  }

  /// Adds a structured data graph candidate.
  ///
  /// Like [setKind], every call adds a competing candidate; only the
  /// highest-ranked graph is returned.
  ///
  /// [score] is ranked by the pipeline's [RankingPolicy]; with
  /// [DefaultRankingPolicy] the highest score wins and ties keep the order in
  /// which candidates were added. [evidence] is reported in provenance and
  /// candidate decisions.
  void setStructuredData(
    StructuredDataGraph graph, {
    required CandidateSource source,
    double score = 0.5,
    String? evidence,
  }) {
    _structuredData.add(
      Candidate(value: graph, source: source, score: score, evidence: evidence),
    );
  }

  // Helpers to normalize inputs before scoring to keep candidates consistent.

  String? _normText(String input) {
    final v = input
        .replaceAll('\u0000', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (v.isEmpty) return null;
    return v;
  }

  Uri? _absHttpUri(Uri input) {
    try {
      final abs = input.hasScheme ? input : baseUrl.resolveUri(input);
      final scheme = abs.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return null;
      if (!abs.hasAuthority || abs.host.isEmpty) return null;
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
    this.itemProvenance = const <MetaField, List<ItemProvenance>>{},
    this.candidateDecisions = const <MetaField, List<CandidateDecision>>{},
    this.raw,
    this.warnings = const [],
    this.errors = const [],
  });

  /// The extracted metadata.
  final LinkMetadata metadata;

  /// Maps each [MetaField] to its [FieldProvenance], showing which source won.
  final Map<MetaField, FieldProvenance> fieldProvenance;

  /// Provenance attached to each retained collection item.
  final Map<MetaField, List<ItemProvenance>> itemProvenance;

  /// Candidate ordering decisions made by the ranking policy.
  final Map<MetaField, List<CandidateDecision>> candidateDecisions;

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
  /// * `urlResolver` - Utility for resolving relative URLs.
  /// * `logSink` - Optional callback for internal logging.
  ExtractPipeline({
    required List<HtmlMetadataExtractorStage> stages,
    this._urlResolver = const UrlResolver(),
    this._rankingPolicy = const DefaultRankingPolicy(),
    this._logSink,
  }) : _stages = List<HtmlMetadataExtractorStage>.unmodifiable(stages);

  final List<HtmlMetadataExtractorStage> _stages;
  final UrlResolver _urlResolver;
  final RankingPolicy _rankingPolicy;
  final MetaLinkLogSink? _logSink;

  /// Parses [page], runs every stage, optionally enriches the result over the
  /// network, and ranks all candidates into a [PipelineOutput].
  ///
  /// Remote oEmbed and manifest enrichment run only when enabled in
  /// [extractOptions] and a stage discovered an endpoint. Those requests use
  /// [fetcher] with [fetchOptions] and share [requestContext] for deadlines and
  /// cancellation. Use [runLocal] to guarantee that no request is made.
  ///
  /// The returned future does not complete with an error for extraction
  /// problems. A body that cannot be decoded or parsed yields empty metadata
  /// and an entry in [PipelineOutput.errors]. A stage that throws, or an
  /// enrichment that fails, adds an entry to [PipelineOutput.warnings] while
  /// the other stages still contribute.
  Future<PipelineOutput> run({
    required HtmlFetchResult page,
    required Fetcher fetcher,
    required FetchOptions fetchOptions,
    required ExtractOptions extractOptions,
    RequestContext? requestContext,
  }) {
    return _run(
      page: page,
      fetcher: fetcher,
      fetchOptions: fetchOptions,
      extractOptions: extractOptions,
      requestContext: requestContext,
      allowRemoteEnrichment: true,
    );
  }

  /// Runs parsing and local extraction without performing network enrichment.
  Future<PipelineOutput> runLocal({
    required HtmlFetchResult page,
    required ExtractOptions extractOptions,
  }) {
    return _run(
      page: page,
      extractOptions: extractOptions,
      allowRemoteEnrichment: false,
    );
  }

  Future<PipelineOutput> _run({
    required HtmlFetchResult page,
    required ExtractOptions extractOptions,
    required bool allowRemoteEnrichment,
    Fetcher? fetcher,
    FetchOptions? fetchOptions,
    RequestContext? requestContext,
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
      documentUrl: page.finalUrl,
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
    warnings.addAll(ctx._warnings);

    // Optionally enrich with remote oEmbed or manifest data after local extraction.
    OEmbedData? oembed;
    if (allowRemoteEnrichment && extractOptions.enableOEmbed) {
      final endpointCandidate = _best(
        MetaField.oembed,
        ctx._oembedEndpoints,
        page.finalUrl,
      );
      if (endpointCandidate != null) {
        try {
          oembed = await const OEmbedEnricher().fetchAndParse(
            fetcher: fetcher!,
            fetchOptions: fetchOptions!,
            endpoint: endpointCandidate.value,
            requestContext: requestContext,
          );
          if (oembed != null) {
            fieldProv[MetaField.oembed] = const FieldProvenance(
              source: CandidateSource.oEmbed,
              score: _scoreOembedProvenance,
              evidence: 'oEmbed fetch succeeded',
            );

            final oembedTitle = oembed.title;
            if (oembedTitle != null) {
              ctx.addTitle(
                oembedTitle,
                source: CandidateSource.oEmbed,
                score: _scoreOembedTitle,
                evidence: 'oEmbed.title',
              );
            }
            final oembedAuthor = oembed.authorName;
            if (oembedAuthor != null) {
              ctx.addAuthor(
                oembedAuthor,
                source: CandidateSource.oEmbed,
                score: _scoreOembedAuthor,
                evidence: 'oEmbed.author_name',
              );
            }
            final oembedProvider = oembed.providerName;
            if (oembedProvider != null) {
              ctx.addSiteName(
                oembedProvider,
                source: CandidateSource.oEmbed,
                score: _scoreOembedSiteName,
                evidence: 'oEmbed.provider_name',
              );
            }
            final thumbnailUrl = oembed.thumbnailUrl;
            if (thumbnailUrl != null) {
              ctx.addImageCandidate(
                ImageCandidate(
                  url: thumbnailUrl,
                  width: oembed.thumbnailWidth,
                  height: oembed.thumbnailHeight,
                ),
                source: CandidateSource.oEmbed,
                score: _scoreOembedImage,
                evidence: 'oEmbed.thumbnail_url',
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
              'endpoint': endpointCandidate.value.url.toString(),
            },
          );
        }
      }
    }

    WebAppManifestData? manifest;
    if (allowRemoteEnrichment && extractOptions.enableManifest) {
      final manifestCandidate = _best(
        MetaField.manifest,
        ctx._manifestUrls,
        page.finalUrl,
      );
      if (manifestCandidate != null) {
        try {
          manifest = await const ManifestEnricher().fetchAndParse(
            fetcher: fetcher!,
            fetchOptions: fetchOptions!,
            manifestUrl: manifestCandidate.value,
            requestContext: requestContext,
          );
          if (manifest != null) {
            fieldProv[MetaField.manifest] = const FieldProvenance(
              source: CandidateSource.manifest,
              score: _scoreManifestProvenance,
              evidence: 'Manifest fetch succeeded',
            );

            final manifestName = manifest.name;
            if (manifestName != null) {
              ctx.addSiteName(
                manifestName,
                source: CandidateSource.manifest,
                score: _scoreManifestSiteName,
                evidence: 'manifest.name',
              );
            }
            final manifestTitle = manifest.shortName;
            if (manifestTitle != null) {
              ctx.addTitle(
                manifestTitle,
                source: CandidateSource.manifest,
                score: _scoreManifestTitle,
                evidence: 'manifest.short_name',
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
              'manifestUrl': manifestCandidate.value.toString(),
            },
          );
        }
      }
    }

    if (manifest != null && manifest.icons.isNotEmpty) {
      for (final icon in manifest.icons) {
        ctx.addIconUri(
          icon.src,
          sizes: icon.sizes,
          type: icon.type,
          rel: 'manifest',
          source: CandidateSource.manifest,
          score: _scoreManifestIconCandidate,
          evidence: 'manifest.icons',
        );
      }
    }

    // Rank all local and remote candidates through one deterministic policy.
    final canonical = _best(
      MetaField.canonicalUrl,
      ctx._canonicalUrl,
      page.finalUrl,
    );
    final bestTitle = _best(MetaField.title, ctx._title, page.finalUrl);
    final bestDesc = _best(
      MetaField.description,
      ctx._description,
      page.finalUrl,
    );
    final bestSite = _best(MetaField.siteName, ctx._siteName, page.finalUrl);
    final bestLocale = _best(MetaField.locale, ctx._locale, page.finalUrl);
    final bestAuthor = _best(MetaField.author, ctx._author, page.finalUrl);
    final bestPub = _best(
      MetaField.publishedAt,
      ctx._publishedAt,
      page.finalUrl,
    );
    final bestMod = _best(MetaField.modifiedAt, ctx._modifiedAt, page.finalUrl);
    final kindCandidate = _best(MetaField.kind, ctx._kinds, page.finalUrl);
    final structuredDataCandidate = _best(
      MetaField.structuredData,
      ctx._structuredData,
      page.finalUrl,
    );

    final keywordSelection = _collectKeywords(
      ctx._keywords,
      documentUrl: page.finalUrl,
    );
    final imageSelection = _collectTopUnique<ImageCandidate>(
      MetaField.images,
      ctx._images,
      documentUrl: page.finalUrl,
      max: extractOptions.maxImages,
      keyOf: (value) => value.url.toString(),
      merge: _mergeImages,
      contributes: _imageContributes,
    );
    final iconSelection = _collectTopUnique<IconCandidate>(
      MetaField.icons,
      ctx._icons,
      documentUrl: page.finalUrl,
      max: extractOptions.maxIcons,
      keyOf: (value) => value.url.toString(),
      merge: _mergeIcons,
      contributes: _iconContributes,
    );
    final videoSelection = _collectTopUnique<VideoCandidate>(
      MetaField.videos,
      ctx._videos,
      documentUrl: page.finalUrl,
      max: extractOptions.maxVideos,
      keyOf: (value) => value.url.toString(),
      merge: _mergeVideos,
      contributes: _videoContributes,
    );
    final audioSelection = _collectTopUnique<AudioCandidate>(
      MetaField.audios,
      ctx._audios,
      documentUrl: page.finalUrl,
      max: extractOptions.maxAudios,
      keyOf: (value) => value.url.toString(),
      merge: _mergeAudios,
      contributes: _audioContributes,
    );
    final keywordCandidates = keywordSelection.candidates;
    final imageCandidates = imageSelection.candidates;
    final iconCandidates = iconSelection.candidates;
    final videoCandidates = videoSelection.candidates;
    final audioCandidates = audioSelection.candidates;

    final scalarWinners = <MetaField, Candidate<dynamic>?>{
      MetaField.canonicalUrl: canonical,
      MetaField.title: bestTitle,
      MetaField.description: bestDesc,
      MetaField.siteName: bestSite,
      MetaField.locale: bestLocale,
      MetaField.author: bestAuthor,
      MetaField.publishedAt: bestPub,
      MetaField.modifiedAt: bestMod,
      MetaField.kind: kindCandidate?.value == LinkKind.unknown
          ? null
          : kindCandidate,
      MetaField.structuredData: structuredDataCandidate,
    };
    for (final entry in scalarWinners.entries) {
      final candidate = entry.value;
      if (candidate != null) fieldProv[entry.key] = _prov(candidate);
    }
    if (keywordCandidates.isNotEmpty) {
      fieldProv[MetaField.keywords] = _prov(keywordCandidates.first);
    }
    if (imageCandidates.isNotEmpty) {
      fieldProv[MetaField.images] = _prov(imageCandidates.first);
    }
    if (iconCandidates.isNotEmpty) {
      fieldProv[MetaField.icons] = _prov(iconCandidates.first);
    }
    if (videoCandidates.isNotEmpty) {
      fieldProv[MetaField.videos] = _prov(videoCandidates.first);
    }
    if (audioCandidates.isNotEmpty) {
      fieldProv[MetaField.audios] = _prov(audioCandidates.first);
    }

    final itemProvenance = <MetaField, List<ItemProvenance>>{
      if (keywordCandidates.isNotEmpty)
        MetaField.keywords: _itemProvenance(
          keywordSelection,
          (value) => value.trim().toLowerCase(),
        ),
      if (imageCandidates.isNotEmpty)
        MetaField.images: _itemProvenance(
          imageSelection,
          (value) => value.url.toString(),
        ),
      if (iconCandidates.isNotEmpty)
        MetaField.icons: _itemProvenance(
          iconSelection,
          (value) => value.url.toString(),
        ),
      if (videoCandidates.isNotEmpty)
        MetaField.videos: _itemProvenance(
          videoSelection,
          (value) => value.url.toString(),
        ),
      if (audioCandidates.isNotEmpty)
        MetaField.audios: _itemProvenance(
          audioSelection,
          (value) => value.url.toString(),
        ),
    };

    final candidateDecisions = _buildCandidateDecisions(
      ctx,
      documentUrl: page.finalUrl,
      scalarWinners: scalarWinners,
      keywordSelection: keywordSelection,
      imageSelection: imageSelection,
      iconSelection: iconSelection,
      videoSelection: videoSelection,
      audioSelection: audioSelection,
    );

    // Build the normalized metadata object from the selected candidates.
    final metadata = LinkMetadata(
      originalUrl: page.originalUrl,
      resolvedUrl: page.finalUrl,
      canonicalUrl: canonical?.value,
      title: bestTitle?.value,
      description: bestDesc?.value,
      siteName: bestSite?.value,
      locale: bestLocale?.value,
      kind: kindCandidate?.value ?? LinkKind.unknown,
      images: imageCandidates.map((candidate) => candidate.value).toList(),
      icons: iconCandidates.map((candidate) => candidate.value).toList(),
      videos: videoCandidates.map((candidate) => candidate.value).toList(),
      audios: audioCandidates.map((candidate) => candidate.value).toList(),
      publishedAt: bestPub?.value,
      modifiedAt: bestMod?.value,
      author: bestAuthor?.value,
      keywords: keywordCandidates.map((candidate) => candidate.value).toList(),
      oembed: oembed,
      manifest: manifest,
      structuredData: structuredDataCandidate?.value,
    );

    return PipelineOutput(
      metadata: metadata,
      fieldProvenance: fieldProv,
      itemProvenance: itemProvenance,
      candidateDecisions: candidateDecisions,
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

  // Uses the first `<base href>` only when it yields an absolute HTTP(S) URL
  // with a host. A hostless base such as `https:` or `https:///` would make
  // every relative asset resolve hostless and be dropped, so it falls back to
  // the document URL as browsers do for an unusable base. The URL resolver
  // applies the same WHATWG tab, newline, and control-character cleanup used
  // for every other URL field.
  Uri _detectBaseUrl(Document doc, Uri fallback) {
    try {
      final href = doc.querySelector('base[href]')?.attributes['href'];
      return _urlResolver.resolve(fallback, href) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  FieldProvenance _prov<T>(Candidate<T> c) {
    return FieldProvenance(
      source: c.source,
      score: c.score,
      evidence: c.evidence,
    );
  }

  Candidate<T>? _best<T>(
    MetaField field,
    List<Candidate<T>> candidates,
    Uri documentUrl,
  ) {
    return _rankingPolicy
        .rank<T>(field: field, candidates: candidates, documentUrl: documentUrl)
        .winner
        ?.candidate;
  }

  _CollectionSelection<T> _collectTopUnique<T>(
    MetaField field,
    List<Candidate<T>> candidates, {
    required Uri documentUrl,
    required int max,
    required String Function(T value) keyOf,
    required T Function(T preferred, T additional) merge,
    required bool Function(T preferred, T additional) contributes,
  }) {
    if (candidates.isEmpty || max <= 0) {
      return _CollectionSelection<T>.empty();
    }

    final ranked = _rankingPolicy.rank<T>(
      field: field,
      candidates: candidates,
      documentUrl: documentUrl,
    );
    final byKey = <String, Candidate<T>>{};
    final order = <String>[];
    final contributors = <String, List<Candidate<T>>>{};

    for (final rankedCandidate in ranked.ranked) {
      final candidate = rankedCandidate.candidate;
      final key = keyOf(candidate.value);
      final existing = byKey[key];
      if (existing == null) {
        if (order.length >= max) continue;
        order.add(key);
        byKey[key] = candidate;
        contributors[key] = <Candidate<T>>[candidate];
        continue;
      }

      if (contributes(existing.value, candidate.value)) {
        contributors[key]!.add(candidate);
      }
      byKey[key] = Candidate<T>(
        value: merge(existing.value, candidate.value),
        source: existing.source,
        score: existing.score,
        evidence: existing.evidence,
      );
    }

    return _CollectionSelection<T>(
      candidates: List<Candidate<T>>.unmodifiable(
        order.map((key) => byKey[key]!),
      ),
      contributors: <String, List<Candidate<T>>>{
        for (final key in order)
          key: List<Candidate<T>>.unmodifiable(contributors[key]!),
      },
    );
  }

  _CollectionSelection<String> _collectKeywords(
    List<Candidate<String>> candidates, {
    required Uri documentUrl,
  }) {
    return _collectTopUnique<String>(
      MetaField.keywords,
      candidates,
      documentUrl: documentUrl,
      max: _maxKeywords,
      keyOf: (value) => value.trim().toLowerCase(),
      merge: (preferred, _) => preferred.trim(),
      contributes: (_, _) => false,
    );
  }

  ImageCandidate _mergeImages(
    ImageCandidate preferred,
    ImageCandidate additional,
  ) {
    return ImageCandidate(
      url: preferred.url,
      width: preferred.width ?? additional.width,
      height: preferred.height ?? additional.height,
      mimeType: preferred.mimeType ?? additional.mimeType,
      alt: preferred.alt ?? additional.alt,
      byteSize: preferred.byteSize ?? additional.byteSize,
    );
  }

  bool _imageContributes(ImageCandidate preferred, ImageCandidate additional) {
    return (preferred.width == null && additional.width != null) ||
        (preferred.height == null && additional.height != null) ||
        (preferred.mimeType == null && additional.mimeType != null) ||
        (preferred.alt == null && additional.alt != null) ||
        (preferred.byteSize == null && additional.byteSize != null);
  }

  IconCandidate _mergeIcons(IconCandidate preferred, IconCandidate additional) {
    return IconCandidate(
      url: preferred.url,
      rel: preferred.rel ?? additional.rel,
      sizes: preferred.sizes ?? additional.sizes,
      type: preferred.type ?? additional.type,
    );
  }

  bool _iconContributes(IconCandidate preferred, IconCandidate additional) {
    return (preferred.rel == null && additional.rel != null) ||
        (preferred.sizes == null && additional.sizes != null) ||
        (preferred.type == null && additional.type != null);
  }

  VideoCandidate _mergeVideos(
    VideoCandidate preferred,
    VideoCandidate additional,
  ) {
    return VideoCandidate(
      url: preferred.url,
      width: preferred.width ?? additional.width,
      height: preferred.height ?? additional.height,
      mimeType: preferred.mimeType ?? additional.mimeType,
    );
  }

  bool _videoContributes(VideoCandidate preferred, VideoCandidate additional) {
    return (preferred.width == null && additional.width != null) ||
        (preferred.height == null && additional.height != null) ||
        (preferred.mimeType == null && additional.mimeType != null);
  }

  AudioCandidate _mergeAudios(
    AudioCandidate preferred,
    AudioCandidate additional,
  ) {
    return AudioCandidate(
      url: preferred.url,
      mimeType: preferred.mimeType ?? additional.mimeType,
    );
  }

  bool _audioContributes(AudioCandidate preferred, AudioCandidate additional) {
    return preferred.mimeType == null && additional.mimeType != null;
  }

  List<ItemProvenance> _itemProvenance<T>(
    _CollectionSelection<T> selection,
    String Function(T value) keyOf,
  ) {
    return selection.candidates
        .map((candidate) {
          final key = keyOf(candidate.value);
          final contributors = selection.contributors[key] ?? const [];
          return ItemProvenance(
            itemKey: key,
            provenance: _prov(candidate),
            contributors: contributors.map(_prov).toList(growable: false),
          );
        })
        .toList(growable: false);
  }

  List<CandidateDecision> _candidateDecisions<T>(
    MetaField field,
    List<Candidate<T>> candidates,
    Uri documentUrl, {
    Set<Candidate<T>>? selectedCandidates,
    required String Function(T value) keyOf,
  }) {
    final ranked = _rankingPolicy.rank<T>(
      field: field,
      candidates: candidates,
      documentUrl: documentUrl,
    );
    return ranked.ranked
        .map((rankedCandidate) {
          final candidate = rankedCandidate.candidate;
          final key = keyOf(candidate.value);
          return CandidateDecision(
            valueKey: key,
            source: candidate.source,
            score: candidate.score,
            effectiveScore: rankedCandidate.effectiveScore,
            selected: selectedCandidates?.contains(candidate) ?? false,
            evidence: candidate.evidence,
          );
        })
        .toList(growable: false);
  }

  Map<MetaField, List<CandidateDecision>> _buildCandidateDecisions(
    HtmlExtractContext context, {
    required Uri documentUrl,
    required Map<MetaField, Candidate<dynamic>?> scalarWinners,
    required _CollectionSelection<String> keywordSelection,
    required _CollectionSelection<ImageCandidate> imageSelection,
    required _CollectionSelection<IconCandidate> iconSelection,
    required _CollectionSelection<VideoCandidate> videoSelection,
    required _CollectionSelection<AudioCandidate> audioSelection,
  }) {
    final decisions = <MetaField, List<CandidateDecision>>{};

    void addScalar<T>(
      MetaField field,
      List<Candidate<T>> candidates,
      Candidate<T>? winner,
      String Function(T value) keyOf,
    ) {
      if (candidates.isEmpty) return;
      decisions[field] = _candidateDecisions<T>(
        field,
        candidates,
        documentUrl,
        selectedCandidates: winner == null ? <Candidate<T>>{} : {winner},
        keyOf: keyOf,
      );
    }

    addScalar<Uri>(
      MetaField.canonicalUrl,
      context._canonicalUrl,
      scalarWinners[MetaField.canonicalUrl] as Candidate<Uri>?,
      (value) => value.toString(),
    );
    addScalar<String>(
      MetaField.title,
      context._title,
      scalarWinners[MetaField.title] as Candidate<String>?,
      (value) => value,
    );
    addScalar<String>(
      MetaField.description,
      context._description,
      scalarWinners[MetaField.description] as Candidate<String>?,
      (value) => value,
    );
    addScalar<String>(
      MetaField.siteName,
      context._siteName,
      scalarWinners[MetaField.siteName] as Candidate<String>?,
      (value) => value,
    );
    addScalar<String>(
      MetaField.locale,
      context._locale,
      scalarWinners[MetaField.locale] as Candidate<String>?,
      (value) => value,
    );
    addScalar<String>(
      MetaField.author,
      context._author,
      scalarWinners[MetaField.author] as Candidate<String>?,
      (value) => value,
    );
    addScalar<DateTime>(
      MetaField.publishedAt,
      context._publishedAt,
      scalarWinners[MetaField.publishedAt] as Candidate<DateTime>?,
      (value) => value.toIso8601String(),
    );
    addScalar<DateTime>(
      MetaField.modifiedAt,
      context._modifiedAt,
      scalarWinners[MetaField.modifiedAt] as Candidate<DateTime>?,
      (value) => value.toIso8601String(),
    );
    addScalar<LinkKind>(
      MetaField.kind,
      context._kinds,
      scalarWinners[MetaField.kind] as Candidate<LinkKind>?,
      (value) => value.name,
    );
    addScalar<StructuredDataGraph>(
      MetaField.structuredData,
      context._structuredData,
      scalarWinners[MetaField.structuredData]
          as Candidate<StructuredDataGraph>?,
      _structuredDataKey,
    );

    if (keywordSelection.candidates.isNotEmpty ||
        context._keywords.isNotEmpty) {
      decisions[MetaField.keywords] = _candidateDecisions<String>(
        MetaField.keywords,
        context._keywords,
        documentUrl,
        selectedCandidates: keywordSelection.contributingCandidates,
        keyOf: (value) => value.toLowerCase(),
      );
    }
    if (imageSelection.candidates.isNotEmpty || context._images.isNotEmpty) {
      decisions[MetaField.images] = _candidateDecisions<ImageCandidate>(
        MetaField.images,
        context._images,
        documentUrl,
        selectedCandidates: imageSelection.contributingCandidates,
        keyOf: (value) => value.url.toString(),
      );
    }
    if (iconSelection.candidates.isNotEmpty || context._icons.isNotEmpty) {
      decisions[MetaField.icons] = _candidateDecisions<IconCandidate>(
        MetaField.icons,
        context._icons,
        documentUrl,
        selectedCandidates: iconSelection.contributingCandidates,
        keyOf: (value) => value.url.toString(),
      );
    }
    if (videoSelection.candidates.isNotEmpty || context._videos.isNotEmpty) {
      decisions[MetaField.videos] = _candidateDecisions<VideoCandidate>(
        MetaField.videos,
        context._videos,
        documentUrl,
        selectedCandidates: videoSelection.contributingCandidates,
        keyOf: (value) => value.url.toString(),
      );
    }
    if (audioSelection.candidates.isNotEmpty || context._audios.isNotEmpty) {
      decisions[MetaField.audios] = _candidateDecisions<AudioCandidate>(
        MetaField.audios,
        context._audios,
        documentUrl,
        selectedCandidates: audioSelection.contributingCandidates,
        keyOf: (value) => value.url.toString(),
      );
    }

    return decisions;
  }

  String _structuredDataKey(StructuredDataGraph graph) {
    final identities = graph.nodes
        .map((node) {
          final id = node['@id'];
          if (id != null) return id.toString();
          final type = node['@type'];
          if (type is List) return type.join(',');
          return type?.toString() ?? 'node';
        })
        .join('|');
    return 'nodes=${graph.nodes.length}:$identities';
  }
}

class _CollectionSelection<T> {
  const _CollectionSelection({
    required this.candidates,
    required this.contributors,
  });

  factory _CollectionSelection.empty() {
    return _CollectionSelection<T>(
      candidates: List<Candidate<T>>.empty(growable: false),
      contributors: Map<String, List<Candidate<T>>>.unmodifiable(
        <String, List<Candidate<T>>>{},
      ),
    );
  }

  final List<Candidate<T>> candidates;
  final Map<String, List<Candidate<T>>> contributors;

  Set<Candidate<T>> get contributingCandidates => <Candidate<T>>{
    for (final values in contributors.values) ...values,
  };
}

const int _maxKeywords = 25;

const double _scoreOembedProvenance = 0.8;
const double _scoreOembedTitle = 0.7;
const double _scoreOembedAuthor = 0.7;
const double _scoreOembedSiteName = 0.65;
const double _scoreOembedImage = 0.8;

const double _scoreManifestProvenance = 0.75;
const double _scoreManifestSiteName = 0.6;
const double _scoreManifestTitle = 0.55;
const double _scoreManifestIconCandidate = 0.72;
