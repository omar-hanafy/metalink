import 'package:html/dom.dart';

import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/structured_data.dart';
import 'package:metalink/src/util/json_utils.dart';
import 'package:metalink/src/extract/pipeline.dart';

/// Extracts JSON-LD (`<script type="application/ld+json">`) to enrich page metadata.
///
/// - Stores the full [StructuredDataGraph] for downstream inspection.
/// - Derives high-confidence page fields when possible (title, description, dates, author, images, kind).
///
/// This stage is best-effort and must not throw; malformed JSON-LD is ignored.
class JsonLdExtractor implements HtmlMetadataExtractorStage {
  const JsonLdExtractor({this.limits = const JsonLdTraversalLimits()});

  final JsonLdTraversalLimits limits;

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractJsonLd) return;
    // Extractor stages must not throw so one bad document cannot abort the pipeline.
    try {
      final collection = _collectJsonLdNodes(context.document, limits: limits);
      final nodes = collection.nodes;
      if (collection.malformedScripts > 0) {
        context.addWarning(
          MetaLinkWarning(
            code: MetaLinkWarningCode.partialParse,
            message:
                'Ignored ${collection.malformedScripts} malformed JSON-LD script(s).',
            uri: context.documentUrl,
          ),
        );
      }
      if (collection.limitReached) {
        context.addWarning(
          MetaLinkWarning(
            code: MetaLinkWarningCode.partialParse,
            message:
                'JSON-LD traversal stopped at its configured node, visit, or depth limit, or JSON size limit.',
            uri: context.documentUrl,
          ),
        );
      }
      if (nodes.isEmpty) return;

      // 1) Always provide the full graph (best-effort) so callers can inspect it directly.
      //    Score is high enough to beat heuristics but not higher than Open Graph.
      context.setStructuredData(
        StructuredDataGraph(nodes: nodes),
        source: CandidateSource.jsonLd,
        score: _JsonLdScores.structuredData,
        evidence: 'script[type*=ld+json]',
      );

      // 2) Derive page-level fields from the most relevant nodes.
      final scored = <_ScoredNode>[];
      final relevanceBudget = _JsonLdValueBudget(
        maxVisitedValues: limits.maxDerivedValues,
        maxDepth: limits.maxDepth,
      );
      for (var index = 0; index < nodes.length; index++) {
        final node = nodes[index];
        scored.add(
          _ScoredNode(
            node,
            _pageRelevanceScore(node, context.documentUrl, relevanceBudget),
            index,
          ),
        );
      }
      scored.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0
            ? byScore
            : a.originalIndex.compareTo(b.originalIndex);
      });

      // Apply extraction to a small set of top nodes and allow lower-ranked nodes to contribute.
      final int limit = scored.length < 12 ? scored.length : 12;
      final extractionBudget = _JsonLdValueBudget(
        maxVisitedValues: limits.maxDerivedValues,
        maxDepth: limits.maxDepth,
      );
      for (var i = 0; i < limit; i++) {
        final sn = scored[i];
        final strength = i == 0
            ? _NodeStrength.primary
            : (i < 4 ? _NodeStrength.secondary : _NodeStrength.tertiary);
        _applyNodeToContext(
          context: context,
          node: sn.node,
          strength: strength,
          budget: extractionBudget,
        );
      }
      if (relevanceBudget.limitReached || extractionBudget.limitReached) {
        context.addWarning(
          MetaLinkWarning(
            code: MetaLinkWarningCode.partialParse,
            message:
                'JSON-LD derived-field traversal stopped at its configured visit or depth limit.',
            uri: context.documentUrl,
          ),
        );
      }
    } catch (error) {
      context.addWarning(
        MetaLinkWarning(
          code: MetaLinkWarningCode.partialParse,
          message: 'JSON-LD extraction failed safely.',
          uri: context.documentUrl,
          cause: error,
        ),
      );
      return;
    }
  }

  double _pageRelevanceScore(
    Map<String, dynamic> node,
    Uri baseUrl,
    _JsonLdValueBudget budget,
  ) {
    // Higher score means the node is more likely to describe the page itself.
    double score = 0.0;

    final normalizedBase = _normalizeUriForCompare(baseUrl);

    // URL signals, weighted toward exact matches with the final page URL.
    final urls = <Uri>[
      ..._extractUris(node['url'], baseUrl: baseUrl, budget: budget),
      ..._extractUris(node['@id'], baseUrl: baseUrl, budget: budget),
      ..._extractUris(
        node['mainEntityOfPage'],
        baseUrl: baseUrl,
        budget: budget,
      ),
    ];

    for (final u in urls) {
      final nu = _normalizeUriForCompare(u);
      if (nu == null || normalizedBase == null) continue;
      if (nu.toString() == normalizedBase.toString()) {
        score += _JsonLdScores.urlExactMatch;
      } else if (nu.host == normalizedBase.host &&
          nu.path == normalizedBase.path) {
        score += _JsonLdScores.urlPathMatch;
      } else if (nu.host == normalizedBase.host) {
        score += _JsonLdScores.urlHostMatch;
      }
    }

    final types = _types(node);
    if (types.isNotEmpty) {
      // Prefer page-like or primary content types for the page-level candidate.
      if (_hasType(types, const [
        'WebPage',
        'Article',
        'NewsArticle',
        'BlogPosting',
        'VideoObject',
        'Product',
        'Event',
      ])) {
        score += _JsonLdScores.typePrimary;
      } else if (_hasType(types, const ['WebSite', 'Organization', 'Person'])) {
        score += _JsonLdScores.typeSecondary;
      } else {
        score += _JsonLdScores.typeOther;
      }
    }

    // Presence of page fields indicates relevance to the rendered page.
    if (_asString(node['headline']) != null ||
        _asString(node['name']) != null) {
      score += _JsonLdScores.hasHeadline;
    }
    if (_asString(node['description']) != null) {
      score += _JsonLdScores.hasDescription;
    }
    if (node.containsKey('datePublished') || node.containsKey('uploadDate')) {
      score += _JsonLdScores.hasDate;
    }
    if (node.containsKey('image') || node.containsKey('thumbnailUrl')) {
      score += _JsonLdScores.hasImage;
    }

    return score;
  }

  Uri? _normalizeUriForCompare(Uri uri) {
    // Remove fragments and normalize casing to compare URLs consistently.
    Uri u = uri.removeFragment();
    // Normalize scheme case for consistent comparisons.
    final scheme = u.scheme.toLowerCase();
    if (scheme.isNotEmpty && scheme != u.scheme) {
      u = u.replace(scheme: scheme);
    }
    // Normalize host case for consistent comparisons.
    final host = u.host.toLowerCase();
    if (host.isNotEmpty && host != u.host) {
      u = u.replace(host: host);
    }
    return u;
  }

  void _applyNodeToContext({
    required HtmlExtractContext context,
    required Map<String, dynamic> node,
    required _NodeStrength strength,
    required _JsonLdValueBudget budget,
  }) {
    // Never throw from this so a single node cannot break extraction.
    try {
      final types = _types(node);
      final evidence = _evidenceFor(node, types);

      // 1) Kind: map schema types into `LinkKind` for classification.
      final kind = _kindFromTypes(types);
      if (kind != null) {
        context.setKind(
          kind,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.kindPrimary,
            secondary: _JsonLdScores.kindSecondary,
            tertiary: _JsonLdScores.kindTertiary,
          ),
          evidence: evidence,
        );
      }

      // 2) Canonical URL: pick the best URL-like field as a stable reference.
      final canonical = _firstUriFrom(
        candidates: [node['mainEntityOfPage'], node['url'], node['@id']],
        baseUrl: context.baseUrl,
        budget: budget,
      );
      if (canonical != null) {
        context.addCanonicalUrl(
          canonical,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.canonicalPrimary,
            secondary: _JsonLdScores.canonicalSecondary,
            tertiary: _JsonLdScores.canonicalTertiary,
          ),
          evidence: evidence,
        );
      }

      // 3) Title: prefer explicit headline or name fields when present.
      final title = _bestTitle(node);
      if (title != null) {
        context.addTitle(
          title,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.titlePrimary,
            secondary: _JsonLdScores.titleSecondary,
            tertiary: _JsonLdScores.titleTertiary,
          ),
          evidence: evidence,
        );
      }

      // 4) Description: use JSON-LD descriptions as a fallback summary.
      final description = _asString(node['description']);
      if (description != null) {
        context.addDescription(
          description,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.descriptionPrimary,
            secondary: _JsonLdScores.descriptionSecondary,
            tertiary: _JsonLdScores.descriptionTertiary,
          ),
          evidence: evidence,
        );
      }

      // 5) Locale: capture explicit language hints when provided.
      final locale =
          _asString(node['inLanguage']) ?? _asString(node['@language']);
      if (locale != null) {
        context.addLocale(
          locale,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.localePrimary,
            secondary: _JsonLdScores.localeSecondary,
            tertiary: _JsonLdScores.localeTertiary,
          ),
          evidence: evidence,
        );
      }

      // 6) Site name: prefer publisher or WebSite metadata for branding.
      final siteName =
          _publisherName(node) ?? _siteNameFromWebSiteNode(node, types);
      if (siteName != null) {
        context.addSiteName(
          siteName,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.siteNamePrimary,
            secondary: _JsonLdScores.siteNameSecondary,
            tertiary: _JsonLdScores.siteNameTertiary,
          ),
          evidence: evidence,
        );
      }

      // 7) Author: collect explicit author fields for attribution.
      for (final author in _authors(node, budget)) {
        if (author.isEmpty) continue;
        context.addAuthor(
          author,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.authorPrimary,
            secondary: _JsonLdScores.authorSecondary,
            tertiary: _JsonLdScores.authorTertiary,
          ),
          evidence: evidence,
        );
      }

      // 8) Dates: parse published and modified timestamps for timelines.
      final publishedAt =
          _tryParseDateTime(node['datePublished']) ??
          _tryParseDateTime(node['uploadDate']) ??
          _tryParseDateTime(node['startDate']);
      if (publishedAt != null) {
        context.addPublishedAt(
          publishedAt,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.publishedPrimary,
            secondary: _JsonLdScores.publishedSecondary,
            tertiary: _JsonLdScores.publishedTertiary,
          ),
          evidence: evidence,
        );
      }

      final modifiedAt = _tryParseDateTime(node['dateModified']);
      if (modifiedAt != null) {
        context.addModifiedAt(
          modifiedAt,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.modifiedPrimary,
            secondary: _JsonLdScores.modifiedSecondary,
            tertiary: _JsonLdScores.modifiedTertiary,
          ),
          evidence: evidence,
        );
      }

      // 9) Keywords: split tags to enable search and filtering.
      for (final kw in _keywords(node['keywords'], budget)) {
        if (kw.isEmpty) continue;
        context.addKeyword(
          kw,
          source: CandidateSource.jsonLd,
          score: _scoreFor(
            strength,
            primary: _JsonLdScores.keywordPrimary,
            secondary: _JsonLdScores.keywordSecondary,
            tertiary: _JsonLdScores.keywordTertiary,
          ),
          evidence: evidence,
        );
      }

      // 10) Images: collect image-like fields for previews and cards.
      final imageValues = <dynamic>[
        node['image'],
        node['thumbnailUrl'],
        node['logo'],
      ];
      for (final v in imageValues) {
        for (final uri in _extractUris(
          v,
          baseUrl: context.baseUrl,
          budget: budget,
        )) {
          context.addImageUri(
            uri,
            source: CandidateSource.jsonLd,
            score: _scoreFor(
              strength,
              primary: _JsonLdScores.imagePrimary,
              secondary: _JsonLdScores.imageSecondary,
              tertiary: _JsonLdScores.imageTertiary,
            ),
            evidence: evidence,
          );
        }
      }

      // 11) Videos or Audios: extract media URLs for rich previews.
      if (_hasType(types, const ['VideoObject'])) {
        for (final uri in _extractUris(
          node['contentUrl'],
          baseUrl: context.baseUrl,
          budget: budget,
        )) {
          context.addVideoUri(
            uri,
            source: CandidateSource.jsonLd,
            score: _scoreFor(
              strength,
              primary: _JsonLdScores.videoPrimary,
              secondary: _JsonLdScores.videoSecondary,
              tertiary: _JsonLdScores.videoTertiary,
            ),
            evidence: evidence,
          );
        }
        for (final uri in _extractUris(
          node['embedUrl'],
          baseUrl: context.baseUrl,
          budget: budget,
        )) {
          context.addVideoUri(
            uri,
            source: CandidateSource.jsonLd,
            score: _scoreFor(
              strength,
              primary: _JsonLdScores.videoEmbedPrimary,
              secondary: _JsonLdScores.videoEmbedSecondary,
              tertiary: _JsonLdScores.videoEmbedTertiary,
            ),
            evidence: evidence,
          );
        }
      }

      if (_hasType(types, const ['AudioObject'])) {
        for (final uri in _extractUris(
          node['contentUrl'],
          baseUrl: context.baseUrl,
          budget: budget,
        )) {
          context.addAudioUri(
            uri,
            source: CandidateSource.jsonLd,
            score: _scoreFor(
              strength,
              primary: _JsonLdScores.audioPrimary,
              secondary: _JsonLdScores.audioSecondary,
              tertiary: _JsonLdScores.audioTertiary,
            ),
            evidence: evidence,
          );
        }
      }
    } catch (_) {
      // Do nothing; extraction must remain safe even if a node is malformed.
      return;
    }
  }

  String? _bestTitle(Map<String, dynamic> node) {
    // Common fields for display titles.
    // - Article or BlogPosting: headline
    // - Product or VideoObject: name
    return _asString(node['headline']) ??
        _asString(node['name']) ??
        _asString(node['title']);
  }

  String? _publisherName(Map<String, dynamic> node) {
    final publisher = node['publisher'];
    if (publisher is Map) {
      final p = _stringKeyedMap(publisher);
      if (p == null) return null;
      return _asString(p['name']);
    }
    if (publisher is String) {
      return publisher.trim().isEmpty ? null : publisher.trim();
    }
    return null;
  }

  String? _siteNameFromWebSiteNode(
    Map<String, dynamic> node,
    List<String> types,
  ) {
    // For WebSite nodes, name typically represents the site name.
    if (_hasType(types, const ['WebSite'])) {
      return _asString(node['name']) ?? _asString(node['headline']);
    }
    return null;
  }

  List<String> _authors(Map<String, dynamic> node, _JsonLdValueBudget budget) {
    final author = node['author'];
    return author == null
        ? const <String>[]
        : _authorsFromValue(author, budget);
  }

  List<String> _authorsFromValue(dynamic root, _JsonLdValueBudget budget) {
    final out = <String>[];
    final stack = <_TraversalEntry>[_TraversalEntry(root, 0)];
    while (stack.isNotEmpty) {
      final entry = stack.removeLast();
      if (!budget.visit(entry.depth)) continue;
      final value = entry.value;
      if (value is String) {
        final candidate = value.trim();
        if (candidate.isNotEmpty) out.add(candidate);
      } else if (value is Map) {
        final map = _stringKeyedMap(value);
        final name = map == null ? null : _asString(map['name']);
        if (name != null) out.add(name);
      } else if (value is List) {
        for (final child in value.reversed) {
          if (budget.canEnqueue(entry.depth + 1, stack.length)) {
            stack.add(_TraversalEntry(child, entry.depth + 1));
          }
        }
      }
    }
    return out;
  }

  List<String> _keywords(dynamic value, _JsonLdValueBudget budget) {
    if (value == null || !budget.visit(0)) return const <String>[];
    final out = <String>[];

    if (value is String) {
      final s = value.trim();
      if (s.isEmpty) return out;

      // Split comma-separated keyword strings to preserve individual tags.
      if (s.contains(',')) {
        for (final part in s.split(',')) {
          if (!budget.visit(1)) break;
          final kw = part.trim();
          if (kw.isNotEmpty) out.add(kw);
        }
      } else {
        out.add(s);
      }
      return out;
    }

    if (value is List) {
      for (final v in value) {
        if (!budget.visit(1)) break;
        if (v is String) {
          final kw = v.trim();
          if (kw.isNotEmpty) out.add(kw);
        }
      }
    }
    return out;
  }

  DateTime? _tryParseDateTime(dynamic value) {
    if (value == null) return null;

    if (value is String) {
      final s = value.trim();
      if (s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    if (value is int) {
      // Heuristic: treat large ints as milliseconds or seconds since epoch.
      if (value >= 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      }
      if (value >= 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
      }
    }

    return null;
  }

  Uri? _firstUriFrom({
    required List<dynamic> candidates,
    required Uri baseUrl,
    required _JsonLdValueBudget budget,
  }) {
    for (final c in candidates) {
      final uris = _extractUris(c, baseUrl: baseUrl, budget: budget);
      if (uris.isNotEmpty) return uris.first;
    }
    return null;
  }

  List<Uri> _extractUris(
    dynamic value, {
    required Uri baseUrl,
    required _JsonLdValueBudget budget,
  }) {
    final urls = <String>[];
    _collectUrlStrings(value, urls, budget);

    final out = <Uri>[];
    for (final raw in urls) {
      final uri = _resolveUri(baseUrl, raw);
      if (uri == null) continue;
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') continue;
      if (!uri.hasAuthority || uri.host.isEmpty) continue;
      out.add(uri);
    }
    return out;
  }

  void _collectUrlStrings(
    dynamic root,
    List<String> out,
    _JsonLdValueBudget budget,
  ) {
    final stack = <_TraversalEntry>[_TraversalEntry(root, 0)];
    const directKeys = <String>[
      'url',
      '@id',
      'contentUrl',
      'embedUrl',
      'thumbnailUrl',
      'logo',
      'sameAs',
    ];

    while (stack.isNotEmpty) {
      final entry = stack.removeLast();
      if (!budget.visit(entry.depth)) continue;
      final value = entry.value;
      if (value is String) {
        final candidate = value.trim();
        if (candidate.isNotEmpty) out.add(candidate);
        continue;
      }
      if (value is List) {
        for (final child in value.reversed) {
          if (budget.canEnqueue(entry.depth + 1, stack.length)) {
            stack.add(_TraversalEntry(child, entry.depth + 1));
          }
        }
        continue;
      }
      if (value is Map) {
        final map = _stringKeyedMap(value);
        if (map == null) continue;
        final children = <dynamic>[
          for (final key in directKeys)
            if (map[key] is String || map[key] is List || map[key] is Map)
              map[key],
          if (map['mainEntityOfPage'] is String ||
              map['mainEntityOfPage'] is List ||
              map['mainEntityOfPage'] is Map)
            map['mainEntityOfPage'],
        ];
        for (final child in children.reversed) {
          if (budget.canEnqueue(entry.depth + 1, stack.length)) {
            stack.add(_TraversalEntry(child, entry.depth + 1));
          }
        }
      }
    }
  }

  Uri? _resolveUri(Uri baseUrl, String raw) {
    // Prefer UrlResolver from context, but this helper is static and must resolve locally.
    // Resolve conservatively: accept absolute URLs and resolve relative URLs against baseUrl.
    try {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;

      // Avoid obvious non-URL values that should not be fetched.
      if (trimmed.startsWith('javascript:')) return null;

      // If it looks absolute, parse directly without baseUrl.
      final parsed = Uri.tryParse(trimmed);
      if (parsed == null) return null;

      if (parsed.hasScheme) {
        return parsed;
      }

      // Protocol-relative URLs inherit the page scheme.
      if (trimmed.startsWith('//')) {
        return Uri.parse('${baseUrl.scheme}:$trimmed');
      }

      // Relative URLs resolve against the page base URL.
      return baseUrl.resolveUri(parsed);
    } catch (_) {
      return null;
    }
  }

  List<String> _types(Map<String, dynamic> node) {
    final t = node['@type'];
    if (t is String) return [_normalizeType(t)];
    if (t is List) {
      final out = <String>[];
      for (final item in t) {
        if (item is String) out.add(_normalizeType(item));
      }
      return out;
    }
    return const [];
  }

  String _normalizeType(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;

    // Normalize prefixed types like schema:Article to Article for matching.
    final colon = s.lastIndexOf(':');
    if (colon >= 0 && colon < s.length - 1) {
      s = s.substring(colon + 1);
    }

    // Normalize schema.org URLs to the last path segment for matching.
    final slash = s.lastIndexOf('/');
    if (slash >= 0 && slash < s.length - 1) {
      s = s.substring(slash + 1);
    }

    return s;
  }

  bool _hasType(List<String> types, List<String> wanted) {
    if (types.isEmpty) return false;
    for (final t in types) {
      for (final w in wanted) {
        if (t == w) return true;
      }
    }
    return false;
  }

  LinkKind? _kindFromTypes(List<String> types) {
    if (types.isEmpty) return null;

    if (_hasType(types, const [
      'Article',
      'NewsArticle',
      'BlogPosting',
      'Report',
      'ScholarlyArticle',
    ])) {
      return LinkKind.article;
    }
    if (_hasType(types, const [
      'Product',
      'AggregateOffer',
      'Offer',
      'Brand',
    ])) {
      return LinkKind.product;
    }
    if (_hasType(types, const ['VideoObject', 'Clip', 'Movie', 'TVEpisode'])) {
      return LinkKind.video;
    }
    if (_hasType(types, const [
      'AudioObject',
      'MusicRecording',
      'PodcastEpisode',
    ])) {
      return LinkKind.audio;
    }
    if (_hasType(types, const ['ProfilePage'])) {
      return LinkKind.profile;
    }
    if (_hasType(types, const ['WebSite'])) {
      return LinkKind.homepage;
    }
    if (_hasType(types, const ['SearchAction'])) {
      return LinkKind.search;
    }
    if (_hasType(types, const ['CollectionPage', 'ImageGallery'])) {
      return LinkKind.gallery;
    }
    if (_hasType(types, const ['Event'])) {
      return LinkKind.event;
    }

    // Some sites overuse WebPage; treat it as a generic fallback type.
    if (_hasType(types, const ['WebPage'])) {
      return LinkKind.other;
    }

    return null;
  }

  String _evidenceFor(Map<String, dynamic> node, List<String> types) {
    final id = _asString(node['@id']);
    final typeStr = types.isEmpty ? null : types.join('|');
    if (id != null && typeStr != null) return '@type=$typeStr @id=$id';
    if (id != null) return '@id=$id';
    if (typeStr != null) return '@type=$typeStr';
    return 'json-ld';
  }

  double _scoreFor(
    _NodeStrength strength, {
    required double primary,
    required double secondary,
    required double tertiary,
  }) {
    switch (strength) {
      case _NodeStrength.primary:
        return primary;
      case _NodeStrength.secondary:
        return secondary;
      case _NodeStrength.tertiary:
        return tertiary;
    }
  }
}

/// Resource limits applied while traversing decoded JSON-LD values.
class JsonLdTraversalLimits {
  const JsonLdTraversalLimits({
    this.maxNodes = 250,
    this.maxVisitedValues = 4000,
    this.maxDepth = 64,
    this.maxJsonCharacters = 512 * 1024,
    this.maxDerivedValues = 4000,
  }) : assert(maxNodes > 0),
       assert(maxVisitedValues > 0),
       assert(maxDepth >= 0),
       assert(maxJsonCharacters > 0),
       assert(maxDerivedValues > 0);

  final int maxNodes;
  final int maxVisitedValues;
  final int maxDepth;

  /// Maximum aggregate JSON-LD script characters decoded from one document.
  final int maxJsonCharacters;

  /// Maximum nested values inspected while deriving fields from retained nodes.
  final int maxDerivedValues;
}

_JsonLdCollection _collectJsonLdNodes(
  Document document, {
  required JsonLdTraversalLimits limits,
}) {
  final scripts = document.querySelectorAll('script');
  final out = <Map<String, dynamic>>[];
  final seenIds = <String>{};
  var visitedValues = 0;
  var malformedScripts = 0;
  var limitReached = false;
  var decodedCharacters = 0;

  for (final el in scripts) {
    final typeAttr = (el.attributes['type'] ?? '').toLowerCase().trim();

    if (!(typeAttr.contains('ld+json') || typeAttr.contains('json+ld'))) {
      continue;
    }

    final raw = el.text;
    if (raw.trim().isEmpty) continue;
    if (raw.length > limits.maxJsonCharacters - decodedCharacters) {
      limitReached = true;
      break;
    }
    decodedCharacters += raw.length;

    final decoded = JsonUtils.tryDecodeAny(raw);
    if (decoded == null) {
      malformedScripts++;
      continue;
    }

    final traversal = _deepCollectNodes(
      decoded,
      maxNodes: limits.maxNodes - out.length,
      maxVisitedValues: limits.maxVisitedValues - visitedValues,
      maxDepth: limits.maxDepth,
      seenIds: seenIds,
    );
    out.addAll(traversal.nodes);
    visitedValues += traversal.visitedValues;
    limitReached = limitReached || traversal.limitReached;

    if (out.length >= limits.maxNodes ||
        visitedValues >= limits.maxVisitedValues) {
      if (scripts.last != el) limitReached = true;
      break;
    }
  }

  return _JsonLdCollection(
    nodes: List<Map<String, dynamic>>.unmodifiable(out),
    malformedScripts: malformedScripts,
    limitReached: limitReached,
  );
}

_JsonLdTraversal _deepCollectNodes(
  dynamic root, {
  required int maxNodes,
  required int maxVisitedValues,
  required int maxDepth,
  required Set<String> seenIds,
}) {
  final nodes = <Map<String, dynamic>>[];
  if (maxNodes <= 0 || maxVisitedValues <= 0) {
    return const _JsonLdTraversal(
      nodes: [],
      visitedValues: 0,
      limitReached: true,
    );
  }

  final stack = <_TraversalEntry>[_TraversalEntry(root, 0)];
  var visitedValues = 0;
  var limitReached = false;

  void enqueueAll(Iterable<dynamic> values, int depth) {
    if (depth > maxDepth) {
      limitReached = true;
      return;
    }
    final remaining = maxVisitedValues - visitedValues - stack.length;
    if (remaining <= 0) {
      limitReached = true;
      return;
    }

    final accepted = <dynamic>[];
    for (final value in values) {
      if (accepted.length >= remaining) {
        limitReached = true;
        break;
      }
      accepted.add(value);
    }
    for (final value in accepted.reversed) {
      stack.add(_TraversalEntry(value, depth));
    }
  }

  while (stack.isNotEmpty && nodes.length < maxNodes) {
    if (visitedValues >= maxVisitedValues) {
      limitReached = true;
      break;
    }

    final entry = stack.removeLast();
    visitedValues++;
    if (entry.depth > maxDepth) {
      limitReached = true;
      continue;
    }
    final current = entry.value;

    if (current is List) {
      enqueueAll(current, entry.depth + 1);
      continue;
    }

    if (current is Map) {
      final map = _stringKeyedMap(current);
      if (map == null) continue;

      if (_looksLikeNode(map)) {
        final id = _asString(map['@id']);
        if (id == null || id.isEmpty || seenIds.add(id)) {
          nodes.add(map);
          if (nodes.length >= maxNodes) {
            if (stack.isNotEmpty ||
                map.values.any((value) => value is Map || value is List)) {
              limitReached = true;
            }
            break;
          }
        }
      }

      // Traverse every child exactly once. `@graph` is a normal map value and
      // must not be pushed separately, otherwise graph nodes are duplicated.
      enqueueAll(
        map.values.where((value) => value is Map || value is List),
        entry.depth + 1,
      );
    }
  }

  if (stack.isNotEmpty) limitReached = true;
  return _JsonLdTraversal(
    nodes: List<Map<String, dynamic>>.unmodifiable(nodes),
    visitedValues: visitedValues,
    limitReached: limitReached,
  );
}

class _JsonLdCollection {
  const _JsonLdCollection({
    required this.nodes,
    required this.malformedScripts,
    required this.limitReached,
  });

  final List<Map<String, dynamic>> nodes;
  final int malformedScripts;
  final bool limitReached;
}

class _JsonLdTraversal {
  const _JsonLdTraversal({
    required this.nodes,
    required this.visitedValues,
    required this.limitReached,
  });

  final List<Map<String, dynamic>> nodes;
  final int visitedValues;
  final bool limitReached;
}

class _TraversalEntry {
  const _TraversalEntry(this.value, this.depth);

  final dynamic value;
  final int depth;
}

class _JsonLdValueBudget {
  _JsonLdValueBudget({required this.maxVisitedValues, required this.maxDepth});

  final int maxVisitedValues;
  final int maxDepth;

  var visitedValues = 0;
  var limitReached = false;

  bool visit(int depth) {
    if (depth > maxDepth || visitedValues >= maxVisitedValues) {
      limitReached = true;
      return false;
    }
    visitedValues++;
    return true;
  }

  bool canEnqueue(int depth, int pendingValues) {
    if (depth > maxDepth || visitedValues + pendingValues >= maxVisitedValues) {
      limitReached = true;
      return false;
    }
    return true;
  }
}

Map<String, dynamic>? _stringKeyedMap(Map<dynamic, dynamic> raw) {
  final out = <String, dynamic>{};
  for (final entry in raw.entries) {
    final k = entry.key;
    if (k is String) {
      out[k] = entry.value;
    }
  }
  return out.isEmpty ? null : out;
}

String? _asString(dynamic value) {
  if (value is String) {
    final s = value.trim();
    return s.isEmpty ? null : s;
  }
  return null;
}

bool _looksLikeNode(Map<String, dynamic> map) {
  if (map.containsKey('@type') || map.containsKey('@id')) {
    return true;
  }
  if (map.containsKey('headline') || map.containsKey('name')) {
    return true;
  }
  if (map.containsKey('description') || map.containsKey('url')) {
    return true;
  }
  if (map.containsKey('image') || map.containsKey('thumbnailUrl')) {
    return true;
  }
  return false;
}

class _JsonLdScores {
  static const double structuredData = 0.85;

  static const double urlExactMatch = 6.0;
  static const double urlPathMatch = 3.0;
  static const double urlHostMatch = 1.0;

  static const double typePrimary = 3.0;
  static const double typeSecondary = 1.5;
  static const double typeOther = 0.5;

  static const double hasHeadline = 0.75;
  static const double hasDescription = 0.5;
  static const double hasDate = 0.5;
  static const double hasImage = 0.35;

  static const double kindPrimary = 0.92;
  static const double kindSecondary = 0.80;
  static const double kindTertiary = 0.68;

  static const double canonicalPrimary = 0.90;
  static const double canonicalSecondary = 0.78;
  static const double canonicalTertiary = 0.65;

  static const double titlePrimary = 0.86;
  static const double titleSecondary = 0.74;
  static const double titleTertiary = 0.62;

  static const double descriptionPrimary = 0.82;
  static const double descriptionSecondary = 0.70;
  static const double descriptionTertiary = 0.58;

  static const double localePrimary = 0.78;
  static const double localeSecondary = 0.66;
  static const double localeTertiary = 0.54;

  static const double siteNamePrimary = 0.74;
  static const double siteNameSecondary = 0.62;
  static const double siteNameTertiary = 0.50;

  static const double authorPrimary = 0.90;
  static const double authorSecondary = 0.78;
  static const double authorTertiary = 0.66;

  static const double publishedPrimary = 0.92;
  static const double publishedSecondary = 0.80;
  static const double publishedTertiary = 0.68;

  static const double modifiedPrimary = 0.88;
  static const double modifiedSecondary = 0.76;
  static const double modifiedTertiary = 0.64;

  static const double keywordPrimary = 0.72;
  static const double keywordSecondary = 0.60;
  static const double keywordTertiary = 0.48;

  static const double imagePrimary = 0.80;
  static const double imageSecondary = 0.68;
  static const double imageTertiary = 0.56;

  static const double videoPrimary = 0.86;
  static const double videoSecondary = 0.74;
  static const double videoTertiary = 0.62;

  static const double videoEmbedPrimary = 0.84;
  static const double videoEmbedSecondary = 0.72;
  static const double videoEmbedTertiary = 0.60;

  static const double audioPrimary = 0.86;
  static const double audioSecondary = 0.74;
  static const double audioTertiary = 0.62;
}

enum _NodeStrength { primary, secondary, tertiary }

class _ScoredNode {
  _ScoredNode(this.node, this.score, this.originalIndex);

  final Map<String, dynamic> node;
  final double score;
  final int originalIndex;
}
