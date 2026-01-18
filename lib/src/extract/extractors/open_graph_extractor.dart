import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/util/html_utils.dart';
import 'package:metalink/src/extract/pipeline.dart';

class OpenGraphExtractor implements HtmlMetadataExtractorStage {
  const OpenGraphExtractor();

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractOpenGraph) return;

    final doc = context.document;

    final title = HtmlUtils.metaContent(
      doc,
      'meta[property="og:title"], meta[name="og:title"]',
    );
    _addString(
      title,
      (v) => context.addTitle(
        v,
        source: CandidateSource.openGraph,
        score: _scoreTitle,
        evidence: 'og:title',
      ),
    );

    final description = HtmlUtils.metaContent(
      doc,
      'meta[property="og:description"], meta[name="og:description"]',
    );
    _addString(
      description,
      (v) => context.addDescription(
        v,
        source: CandidateSource.openGraph,
        score: _scoreDescription,
        evidence: 'og:description',
      ),
    );

    final siteName = HtmlUtils.metaContent(
      doc,
      'meta[property="og:site_name"], meta[name="og:site_name"]',
    );
    _addString(
      siteName,
      (v) => context.addSiteName(
        v,
        source: CandidateSource.openGraph,
        score: _scoreSiteName,
        evidence: 'og:site_name',
      ),
    );

    final locale = HtmlUtils.metaContent(
      doc,
      'meta[property="og:locale"], meta[name="og:locale"]',
    );
    _addString(
      locale,
      (v) => context.addLocale(
        v,
        source: CandidateSource.openGraph,
        score: _scoreLocale,
        evidence: 'og:locale',
      ),
    );

    final ogUrlRaw = HtmlUtils.metaContent(
      doc,
      'meta[property="og:url"], meta[name="og:url"]',
    );
    final ogUrl = context.urlResolver.resolve(context.baseUrl, ogUrlRaw);
    if (ogUrl != null) {
      context.addCanonicalUrl(
        ogUrl,
        source: CandidateSource.openGraph,
        score: _scoreCanonical,
        evidence: 'og:url',
      );
    }

    final ogType = HtmlUtils.metaContent(
      doc,
      'meta[property="og:type"], meta[name="og:type"]',
    );
    final kind = _mapOgTypeToKind(ogType, context.baseUrl);
    if (kind != null) {
      context.setKind(
        kind,
        source: CandidateSource.openGraph,
        score: _scoreKind,
        evidence: ogType == null ? 'og:type' : 'og:type=$ogType',
      );
    }

    // Group og:image variants so width, height, and type stay attached to the right image URL.
    final allMeta = doc.getElementsByTagName('meta');
    ImageCandidate? currentImage;

    void commitImage() {
      if (currentImage != null) {
        context.addImageCandidate(
          currentImage!,
          source: CandidateSource.openGraph,
          score: _scoreImage,
          evidence: 'og:image',
        );
        currentImage = null;
      }
    }

    for (final el in allMeta) {
      final propRaw = el.attributes['property'] ?? el.attributes['name'];
      if (propRaw == null) continue;
      final prop = propRaw.trim().toLowerCase();
      if (!prop.startsWith('og:image')) continue;

      final content = el.attributes['content'] ?? el.attributes['value'];
      final value = content?.trim();
      if (value == null || value.isEmpty) continue;

      if (prop == 'og:image' ||
          prop == 'og:image:url' ||
          prop == 'og:image:secure_url') {
        final uri = context.urlResolver.resolve(context.baseUrl, value);
        if (uri == null) continue;

        commitImage();
        currentImage = ImageCandidate(url: uri);
      } else if (currentImage != null) {
        if (prop == 'og:image:width') {
          final w = int.tryParse(value);
          if (w != null) {
            currentImage = _copyImage(currentImage!, width: w);
          }
        } else if (prop == 'og:image:height') {
          final h = int.tryParse(value);
          if (h != null) {
            currentImage = _copyImage(currentImage!, height: h);
          }
        } else if (prop == 'og:image:type') {
          currentImage = _copyImage(currentImage!, mimeType: value);
        } else if (prop == 'og:image:alt') {
          currentImage = _copyImage(currentImage!, alt: value);
        }
      }
    }
    commitImage();

    // Collect og:video candidates and dedupe by URL to keep the list stable.
    final videoRaws = HtmlUtils.metaContents(
      doc,
      'meta[property="og:video"], meta[name="og:video"], '
      'meta[property="og:video:url"], meta[name="og:video:url"], '
      'meta[property="og:video:secure_url"], meta[name="og:video:secure_url"]',
    );
    final seenVideos = <String>{};
    for (final raw in videoRaws) {
      final uri = context.urlResolver.resolve(context.baseUrl, raw);
      if (uri == null) continue;
      if (!seenVideos.add(uri.toString())) continue;

      context.addVideoUri(
        uri,
        source: CandidateSource.openGraph,
        score: _scoreVideo,
        evidence: 'og:video',
      );
    }

    // Collect og:audio candidates and dedupe by URL to avoid repeat entries.
    final audioRaws = HtmlUtils.metaContents(
      doc,
      'meta[property="og:audio"], meta[name="og:audio"], '
      'meta[property="og:audio:url"], meta[name="og:audio:url"], '
      'meta[property="og:audio:secure_url"], meta[name="og:audio:secure_url"]',
    );
    final seenAudios = <String>{};
    for (final raw in audioRaws) {
      final uri = context.urlResolver.resolve(context.baseUrl, raw);
      if (uri == null) continue;
      if (!seenAudios.add(uri.toString())) continue;

      context.addAudioUri(
        uri,
        source: CandidateSource.openGraph,
        score: _scoreAudio,
        evidence: 'og:audio',
      );
    }

    // Capture article timestamps; many sites publish these in the Open Graph namespace.
    final publishedRaw = HtmlUtils.metaContent(
      doc,
      'meta[property="article:published_time"], meta[name="article:published_time"], '
      'meta[property="og:published_time"], meta[name="og:published_time"]',
    );
    final publishedAt = _parseDateTime(publishedRaw);
    if (publishedAt != null) {
      context.addPublishedAt(
        publishedAt,
        source: CandidateSource.openGraph,
        score: _scorePublishedAt,
        evidence: 'article:published_time',
      );
    }

    final modifiedRaw = HtmlUtils.metaContent(
      doc,
      'meta[property="article:modified_time"], meta[name="article:modified_time"], '
      'meta[property="og:updated_time"], meta[name="og:updated_time"]',
    );
    final modifiedAt = _parseDateTime(modifiedRaw);
    if (modifiedAt != null) {
      context.addModifiedAt(
        modifiedAt,
        source: CandidateSource.openGraph,
        score: _scoreModifiedAt,
        evidence: 'article:modified_time',
      );
    }

    // Map Open Graph tags to keywords to support search and filtering use cases.
    final tags = HtmlUtils.metaContents(
      doc,
      'meta[property="article:tag"], meta[name="article:tag"], '
      'meta[property="book:tag"], meta[name="book:tag"], '
      'meta[property="video:tag"], meta[name="video:tag"]',
    );
    for (final tag in tags) {
      context.addKeyword(
        tag,
        source: CandidateSource.openGraph,
        score: _scoreKeyword,
        evidence: 'og:tag',
      );
    }
  }

  static void _addString(String? value, void Function(String v) emit) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return;
    emit(v);
  }

  static ImageCandidate _copyImage(
    ImageCandidate input, {
    int? width,
    int? height,
    String? mimeType,
    String? alt,
  }) {
    return ImageCandidate(
      url: input.url,
      width: width ?? input.width,
      height: height ?? input.height,
      mimeType: mimeType ?? input.mimeType,
      alt: alt ?? input.alt,
      byteSize: input.byteSize,
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

  static DateTime? _parseDateTime(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;

    // Handle numeric timestamps (seconds or millis) before generic parsing.
    final digitsOnly = RegExp(r'^\d+$');
    if (digitsOnly.hasMatch(s)) {
      final n = int.tryParse(s);
      if (n == null) return null;

      if (s.length >= 13) {
        return DateTime.fromMillisecondsSinceEpoch(n, isUtc: true);
      }
      if (s.length == 10) {
        return DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true);
      }
    }

    // Accept ISO8601 style strings supported by DateTime.parse.
    final dt = DateTime.tryParse(s);
    if (dt != null) return dt;

    // Normalize "YYYY-MM-DD HH:MM:SS" to ISO8601 by adding a T separator.
    final withT =
        s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s;
    return DateTime.tryParse(withT);
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
