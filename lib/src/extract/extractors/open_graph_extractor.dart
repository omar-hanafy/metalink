import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/util/date_utils.dart';

/// An extractor stage that reads Open Graph (`og:*`) and related article
/// meta tags.
///
/// Keys are read from either the `property` or the `name` attribute and match
/// ASCII case-insensitively. For single-valued fields the first non-empty tag
/// in document order wins, and `og:url` uses the first value that resolves to
/// an absolute HTTP(S) URL.
///
/// `og:image`, `og:video`, and `og:audio` are structured: each root tag (or
/// its `:url` alias) starts a new item, and the `:secure_url`, `:type`,
/// `:width`, `:height`, and (for images) `:alt` tags that follow describe that
/// item until the next root. A `:secure_url` replaces the root URL while
/// keeping the collected properties. A root whose value is empty or cannot be
/// resolved, such as a `data:` URL, is dropped together with the properties
/// that follow it. A usable `:secure_url` after such a root names the same
/// resource, so it starts the item, and the properties after it describe that
/// item. Dimensions that are not positive integers are ignored.
///
/// Also emits `og:type` as a [LinkKind], `article:published_time` (or
/// `og:published_time`) and `article:modified_time` (or `og:updated_time`) as
/// dates, and `article:tag`, `book:tag`, and `video:tag` as keywords. Each
/// date uses the first value in document order that parses as a timestamp.
/// Does nothing when `ExtractOptions.extractOpenGraph` is `false`.
class OpenGraphExtractor implements HtmlMetadataExtractorStage {
  /// Creates the stateless Open Graph extractor stage.
  const OpenGraphExtractor();

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractOpenGraph) return;

    final meta = context.metaTags;

    _addString(
      meta.firstText(const ['og:title']),
      (v) => context.addTitle(
        v,
        source: CandidateSource.openGraph,
        score: _scoreTitle,
        evidence: 'og:title',
      ),
    );

    _addString(
      meta.firstText(const ['og:description']),
      (v) => context.addDescription(
        v,
        source: CandidateSource.openGraph,
        score: _scoreDescription,
        evidence: 'og:description',
      ),
    );

    _addString(
      meta.firstText(const ['og:site_name']),
      (v) => context.addSiteName(
        v,
        source: CandidateSource.openGraph,
        score: _scoreSiteName,
        evidence: 'og:site_name',
      ),
    );

    _addString(
      meta.firstText(const ['og:locale']),
      (v) => context.addLocale(
        v,
        source: CandidateSource.openGraph,
        score: _scoreLocale,
        evidence: 'og:locale',
      ),
    );

    // Skip unusable og:url duplicates so a later valid value still counts.
    // Read the raw value: collapsing whitespace would turn a wrapped line into
    // an encoded space instead of letting the resolver remove the newline.
    final ogUrl = context.urlResolver
        .resolveAll(
          context.baseUrl,
          meta.find(const ['og:url']).map((tag) => tag.content),
        )
        .firstOrNull;
    if (ogUrl != null) {
      context.addCanonicalUrl(
        ogUrl,
        source: CandidateSource.openGraph,
        score: _scoreCanonical,
        evidence: 'og:url',
      );
    }

    final ogType = meta.firstText(const ['og:type']);
    final kind = _mapOgTypeToKind(ogType, context.documentUrl);
    if (kind != null) {
      context.setKind(
        kind,
        source: CandidateSource.openGraph,
        score: _scoreKind,
        evidence: ogType == null ? 'og:type' : 'og:type=$ogType',
      );
    }

    _collectStructured<ImageCandidate>(
      context,
      root: 'og:image',
      create: (url) => ImageCandidate(url: url),
      withUrl: (image, url) => _copyImage(image, url: url),
      apply: (image, property, value) => switch (property) {
        'width' => _copyImage(image, width: _parseDimension(value)),
        'height' => _copyImage(image, height: _parseDimension(value)),
        'type' => _copyImage(image, mimeType: value),
        'alt' => _copyImage(image, alt: value),
        _ => image,
      },
      emit: (image) => context.addImageCandidate(
        image,
        source: CandidateSource.openGraph,
        score: _scoreImage,
        evidence: 'og:image',
      ),
    );

    _collectStructured<VideoCandidate>(
      context,
      root: 'og:video',
      create: (url) => VideoCandidate(url: url),
      withUrl: (video, url) => _copyVideo(video, url: url),
      apply: (video, property, value) => switch (property) {
        'width' => _copyVideo(video, width: _parseDimension(value)),
        'height' => _copyVideo(video, height: _parseDimension(value)),
        'type' => _copyVideo(video, mimeType: value),
        _ => video,
      },
      emit: (video) => context.addVideoCandidate(
        video,
        source: CandidateSource.openGraph,
        score: _scoreVideo,
        evidence: 'og:video',
      ),
    );

    _collectStructured<AudioCandidate>(
      context,
      root: 'og:audio',
      create: (url) => AudioCandidate(url: url),
      withUrl: (audio, url) =>
          AudioCandidate(url: url, mimeType: audio.mimeType),
      apply: (audio, property, value) => switch (property) {
        'type' => AudioCandidate(url: audio.url, mimeType: value),
        _ => audio,
      },
      emit: (audio) => context.addAudioCandidate(
        audio,
        source: CandidateSource.openGraph,
        score: _scoreAudio,
        evidence: 'og:audio',
      ),
    );

    // Capture article timestamps; many sites publish these in the Open Graph namespace.
    final publishedAt = _firstDate(
      meta.texts(const ['article:published_time', 'og:published_time']),
    );
    if (publishedAt != null) {
      context.addPublishedAt(
        publishedAt,
        source: CandidateSource.openGraph,
        score: _scorePublishedAt,
        evidence: 'article:published_time',
      );
    }

    final modifiedAt = _firstDate(
      meta.texts(const ['article:modified_time', 'og:updated_time']),
    );
    if (modifiedAt != null) {
      context.addModifiedAt(
        modifiedAt,
        source: CandidateSource.openGraph,
        score: _scoreModifiedAt,
        evidence: 'article:modified_time',
      );
    }

    // Map Open Graph tags to keywords to support search and filtering use cases.
    final tags = meta.texts(const ['article:tag', 'book:tag', 'video:tag']);
    for (final tag in tags) {
      context.addKeyword(
        tag,
        source: CandidateSource.openGraph,
        score: _scoreKeyword,
        evidence: 'og:tag',
      );
    }
  }

  /// Groups a structured Open Graph property family such as `og:image` into
  /// items and passes each completed item to [emit] in document order.
  ///
  /// A `root` or `root:url` tag commits the current item and starts a new one.
  /// When that root is empty or unresolvable the current item becomes `null`,
  /// so the rejected root's structured properties are dropped instead of
  /// overwriting the previous item. A `root:secure_url` replaces the current
  /// item's URL, or starts an item when there is none, because it names the
  /// same resource as its root.
  static void _collectStructured<T>(
    HtmlExtractContext context, {
    required String root,
    required T Function(Uri url) create,
    required T Function(T item, Uri url) withUrl,
    required T Function(T item, String property, String value) apply,
    required void Function(T item) emit,
  }) {
    final rootUrl = '$root:url';
    final prefix = '$root:';
    T? current;

    void commit() {
      final item = current;
      if (item != null) emit(item);
      current = null;
    }

    for (final tag in context.metaTags.tags) {
      final key = tag.property ?? tag.name;
      if (key == null) continue;

      if (key == root || key == rootUrl) {
        commit();
        final uri = context.urlResolver.resolve(context.baseUrl, tag.content);
        if (uri != null) current = create(uri);
        continue;
      }

      if (!key.startsWith(prefix)) continue;
      final value = tag.content;
      if (value == null) continue;
      final property = key.substring(prefix.length);
      final item = current;

      if (property == 'secure_url') {
        final uri = context.urlResolver.resolve(context.baseUrl, value);
        if (uri == null) continue;
        current = item == null ? create(uri) : withUrl(item, uri);
      } else if (item != null) {
        current = apply(item, property, value);
      }
    }
    commit();
  }

  /// A positive pixel dimension parsed from [value], or `null` when [value]
  /// is not an integer greater than zero.
  static int? _parseDimension(String value) {
    final parsed = int.tryParse(value);
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static void _addString(String? value, void Function(String v) emit) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return;
    emit(v);
  }

  static ImageCandidate _copyImage(
    ImageCandidate input, {
    Uri? url,
    int? width,
    int? height,
    String? mimeType,
    String? alt,
  }) {
    return ImageCandidate(
      url: url ?? input.url,
      width: width ?? input.width,
      height: height ?? input.height,
      mimeType: mimeType ?? input.mimeType,
      alt: alt ?? input.alt,
      byteSize: input.byteSize,
    );
  }

  static VideoCandidate _copyVideo(
    VideoCandidate input, {
    Uri? url,
    int? width,
    int? height,
    String? mimeType,
  }) {
    return VideoCandidate(
      url: url ?? input.url,
      width: width ?? input.width,
      height: height ?? input.height,
      mimeType: mimeType ?? input.mimeType,
    );
  }

  static LinkKind? _mapOgTypeToKind(String? ogType, Uri baseUrl) {
    final t = ogType?.trim().toLowerCase();
    if (t == null || t.isEmpty) return null;

    switch (t) {
      case 'article':
        return LinkKind.article;
      case 'product':
        return LinkKind.product;
      case 'profile':
        return LinkKind.profile;
      case 'website':
        // Treat root-ish pages as homepage to avoid classifying a site root as a generic page.
        if (baseUrl.path.isEmpty || baseUrl.path == '/' || baseUrl.path == '') {
          return LinkKind.homepage;
        }
        return LinkKind.other;
      default:
        if (t.startsWith('video')) return LinkKind.video;
        if (t.startsWith('music')) return LinkKind.audio;
        return null;
    }
  }

  // The first value in document order that parses as a date. An unparseable
  // placeholder such as `TBD` must not hide a later valid timestamp.
  static DateTime? _firstDate(Iterable<String> raws) {
    for (final raw in raws) {
      final parsed = DateUtils.parseString(raw);
      if (parsed != null) return parsed;
    }
    return null;
  }
}

const double _scoreTitle = 0.95;
const double _scoreDescription = 0.90;
const double _scoreSiteName = 0.85;
const double _scoreLocale = 0.70;
const double _scoreCanonical = 0.75;
const double _scoreKind = 0.70;
const double _scoreImage = 0.85;
const double _scoreVideo = 0.70;
const double _scoreAudio = 0.70;
const double _scorePublishedAt = 0.80;
const double _scoreModifiedAt = 0.75;
const double _scoreKeyword = 0.60;
