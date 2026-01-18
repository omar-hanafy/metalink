import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/extract/pipeline.dart';

class LinkRelExtractor implements HtmlMetadataExtractorStage {
  const LinkRelExtractor();

  @override
  void extract(HtmlExtractContext context) {
    final extractLinkRels = context.extractOptions.extractLinkRels;
    final enableOembed = context.extractOptions.enableOEmbed;
    final enableManifest = context.extractOptions.enableManifest;
    final shouldScan = extractLinkRels || enableOembed || enableManifest;
    if (!shouldScan) return;

    final doc = context.document;

    final seenIconUrls = <String>{};
    final seenOembed = <String>{};

    for (final el in doc.querySelectorAll('link')) {
      final relRaw = (el.attributes['rel'] ?? el.attributes['REL'])?.trim();
      final hrefRaw = (el.attributes['href'] ?? el.attributes['HREF'])?.trim();
      if (relRaw == null || relRaw.isEmpty) continue;
      if (hrefRaw == null || hrefRaw.isEmpty) continue;

      final relLower = relRaw.toLowerCase();
      final tokens =
          relLower.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toSet();

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
      final isOembed = enableOembed &&
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

      // Collect icon candidates and dedupe by URL to keep the icon list stable.
      if (extractLinkRels && _isIconRel(tokens)) {
        final uri = context.urlResolver.resolve(context.baseUrl, hrefRaw);
        if (uri == null) continue;

        final key = uri.toString();
        if (!seenIconUrls.add(key)) continue;

        final sizes =
            (el.attributes['sizes'] ?? el.attributes['SIZES'])?.trim();
        final type = (el.attributes['type'] ?? el.attributes['TYPE'])?.trim();

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
