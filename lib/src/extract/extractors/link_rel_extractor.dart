import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/oembed.dart';

/// An extractor stage that reads `<link>` elements for the canonical URL,
/// icons, oEmbed discovery endpoints, and the web app manifest.
///
/// `rel` values are matched as case-insensitive, whitespace-separated tokens,
/// and each element contributes to at most one category, checked in the order
/// canonical, manifest, oEmbed, icon. Canonical URLs and icons require
/// `ExtractOptions.extractLinkRels`, `rel="alternate"` links whose `type`
/// contains `oembed` require `ExtractOptions.enableOEmbed`, and manifest links
/// require `ExtractOptions.enableManifest`; the stage does nothing when all
/// three are disabled. Hrefs that do not resolve to absolute HTTP(S) URLs are
/// skipped.
///
/// Every icon occurrence is emitted, including repeated URLs, so the
/// pipeline's collection merge can keep the highest-scoring occurrence and
/// fill its missing `sizes` and `type` from the others. Apple touch icons
/// score above plain `icon` links, which score above `mask-icon`. Blank
/// `sizes` and `type` attributes are reported as `null`.
class LinkRelExtractor implements HtmlMetadataExtractorStage {
  /// Creates the stateless link-rel extractor stage.
  const LinkRelExtractor();

  @override
  void extract(HtmlExtractContext context) {
    final extractLinkRels = context.extractOptions.extractLinkRels;
    final enableOembed = context.extractOptions.enableOEmbed;
    final enableManifest = context.extractOptions.enableManifest;
    final shouldScan = extractLinkRels || enableOembed || enableManifest;
    if (!shouldScan) return;

    final doc = context.document;

    final seenOembed = <String>{};

    for (final el in doc.querySelectorAll('link')) {
      final relRaw = (el.attributes['rel'] ?? el.attributes['REL'])?.trim();
      final hrefRaw = (el.attributes['href'] ?? el.attributes['HREF'])?.trim();
      if (relRaw == null || relRaw.isEmpty) continue;
      if (hrefRaw == null || hrefRaw.isEmpty) continue;

      final relLower = relRaw.toLowerCase();
      final tokens = relLower
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toSet();

      // Prefer rel=canonical to stabilize the final URL when pages publish alternates.
      if (extractLinkRels && tokens.contains('canonical')) {
        final uri = context.urlResolver.resolve(context.baseUrl, hrefRaw);
        if (uri != null) {
          context.addCanonicalUrl(
            uri,
            source: CandidateSource.linkRel,
            score: _scoreCanonical,
            evidence: 'link rel=canonical',
          );
        }
        continue;
      }

      // Capture manifest links for optional enrichment when enabled.
      if (enableManifest && tokens.contains('manifest')) {
        final uri = context.urlResolver.resolve(context.baseUrl, hrefRaw);
        if (uri != null) {
          context.addManifestUrl(
            uri,
            source: CandidateSource.linkRel,
            score: _scoreManifest,
            evidence: 'link rel=manifest',
          );
        }
        continue;
      }

      // Discover oEmbed endpoints so enrichment can fetch provider data later.
      final typeAttr = (el.attributes['type'] ?? el.attributes['TYPE'])?.trim();
      final typeLower = typeAttr?.toLowerCase();
      final isOembed =
          enableOembed &&
          tokens.contains('alternate') &&
          typeLower != null &&
          typeLower.contains('oembed');

      if (isOembed) {
        final uri = context.urlResolver.resolve(context.baseUrl, hrefRaw);
        if (uri != null) {
          final format = _inferOembedFormat(typeLower);
          final endpoint = OEmbedEndpoint(url: uri, format: format);

          final key = '${endpoint.format}:${endpoint.url}';
          if (seenOembed.add(key)) {
            context.addOEmbedEndpoint(
              endpoint,
              source: CandidateSource.linkRel,
              score: _scoreOembed,
              evidence: 'link rel=$relRaw type=$typeAttr',
            );
          }
        }
        continue;
      }

      // Emit every icon occurrence. Deduplicating here would keep only the
      // first occurrence of a URL and discard a later, higher-scoring or richer
      // duplicate (for example an apple-touch-icon with sizes) before the
      // pipeline's per-URL merge could use it.
      if (extractLinkRels && _isIconRel(tokens)) {
        final uri = context.urlResolver.resolve(context.baseUrl, hrefRaw);
        if (uri == null) continue;

        final sizes = _nonBlank(
          el.attributes['sizes'] ?? el.attributes['SIZES'],
        );
        final type = _nonBlank(typeAttr);

        context.addIconUri(
          uri,
          rel: relRaw,
          sizes: sizes,
          type: type,
          source: CandidateSource.linkRel,
          score: _iconScore(tokens),
          evidence: 'link rel=$relRaw',
        );
      }
    }
  }

  // Treats blank attributes as absent so they cannot block a later fill.
  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static bool _isIconRel(Set<String> tokens) {
    if (tokens.isEmpty) return false;

    // Fast path for rel values that explicitly include the icon token.
    if (tokens.contains('icon')) return true;

    // Accept legacy "shortcut icon" tokens used by older sites.
    if (tokens.contains('shortcut') && tokens.contains('icon')) return true;

    // Support platform-specific icon rels that still map to usable icons.
    if (tokens.contains('apple-touch-icon')) return true;
    if (tokens.contains('apple-touch-icon-precomposed')) return true;
    if (tokens.contains('mask-icon')) return true;
    if (tokens.contains('fluid-icon')) return true;

    // Some sites use combined rel values; keep a permissive fallback to avoid missing icons.
    for (final t in tokens) {
      if (t.contains('icon')) return true;
    }

    return false;
  }

  static double _iconScore(Set<String> tokens) {
    if (tokens.contains('apple-touch-icon') ||
        tokens.contains('apple-touch-icon-precomposed')) {
      return _scoreIconApple;
    }
    if (tokens.contains('mask-icon')) return _scoreIconMask;
    if (tokens.contains('icon')) return _scoreIconDefault;
    return _scoreIconFallback;
  }

  static OEmbedFormat _inferOembedFormat(String typeLower) {
    if (typeLower.contains('json')) return OEmbedFormat.json;
    if (typeLower.contains('xml')) return OEmbedFormat.xml;
    // Default to JSON since most providers serve JSON and the parser expects it.
    return OEmbedFormat.json;
  }
}

const double _scoreCanonical = 0.95;
const double _scoreManifest = 0.90;
const double _scoreOembed = 0.85;
const double _scoreIconApple = 0.80;
const double _scoreIconMask = 0.70;
const double _scoreIconDefault = 0.75;
const double _scoreIconFallback = 0.65;
