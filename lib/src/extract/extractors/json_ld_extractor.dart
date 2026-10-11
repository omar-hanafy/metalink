import 'package:html/dom.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/structured_data.dart';
import 'package:metalink/src/util/date_utils.dart';
import 'package:metalink/src/util/json_utils.dart';

/// Extracts JSON-LD (`<script type="application/ld+json">`) to enrich page metadata.
///
/// - Stores the collected nodes as a [StructuredDataGraph] for downstream
///   inspection. A bare `{"@id": ...}` reference is not a node, and repeated
///   definitions of one `@id` are merged into the first definition, except
///   that a typed definition wins conflicting properties over an untyped one.
///   Stored values are pruned at [JsonLdTraversalLimits.maxDepth], so the
///   graph always serializes.
/// - Derives page fields (title, description, canonical URL, images, kind,
///   and locale) only from nodes that describe the page. A node describes
///   the page when it has an `@type`, is neither structural nor nested (see
///   below), and either its `url`, `@id`, or `mainEntityOfPage` identifies
///   the document, or it has a page-like `@type` and neither its `url` nor
///   its `mainEntityOfPage` names another document. Page-like types are
///   `WebPage` and main content such as `Article`, `Product`, `Event`,
///   `Recipe`, or `CreativeWork`, each including its schema.org subtypes,
///   so `OpinionNewsArticle` counts as an article.
/// - Relative `url`, `@id`, and `mainEntityOfPage` values resolve against
///   the document's base URL, which honors `<base href>`.
/// - A URL identifies the document when it has the final document URL's
///   host, its path apart from one trailing slash, and its query parameters
///   in any order; the scheme is ignored. A `#fragment` in `url` or `@id`
///   names a part of a page, so it neither identifies the document nor names
///   another one; a fragment in `mainEntityOfPage` is ignored.
/// - A `url` or `mainEntityOfPage` that does not identify the document names
///   another document, unless it is a variant of the final document URL, of
///   the first canonical `<link>`, or of the first `og:url` the page
///   declares. A variant has the same host apart from a leading `www.`, the
///   same path apart from one trailing slash, and only query parameters that
///   the declared URL also has. So `/post` on a page fetched as
///   `/post?utm_source=x` names no other document, while `?t=7` on a page at
///   `?t=100` does. A declared URL never identifies the document, because
///   sites commonly declare their homepage as every page's canonical URL.
/// - Structural nodes, such as lists, breadcrumbs, navigation, images,
///   comments, and offers, never describe the page. Nested nodes never do
///   either: a node is nested when every definition of it is reached through
///   a structural node or a `review` or `reviews` property, such as a list
///   entry or a product review. Structural nodes, nested nodes, and page-like
///   nodes of other documents contribute no site name, authors, dates, or
///   keywords. Other nodes, including untyped ones and nodes such as
///   `WebSite`, `Organization`, or `Person`, still contribute site name,
///   authors, dates, and keywords.
/// - Video and audio URLs come from `VideoObject` and `AudioObject` nodes
///   that are not nested, including another document's, such as a video
///   embedded in an article.
///
/// This stage is best-effort and must not throw; malformed JSON-LD is ignored
/// and reported as a [MetaLinkWarningCode.partialParse] warning.
class JsonLdExtractor implements HtmlMetadataExtractorStage {
  /// Creates a JSON-LD stage whose decoding and traversal are bounded by
  /// [limits].
  const JsonLdExtractor({this.limits = const JsonLdTraversalLimits()});

  /// The resource limits applied to each document's JSON-LD.
  ///
  /// Reaching a limit never throws: the stage keeps what it collected and
  /// adds a [MetaLinkWarningCode.partialParse] warning.
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
            message: 'JSON-LD traversal stopped at its configured node, visit, or depth limit, or JSON size limit.',
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
      final pageVariants = _pageVariants(context);
      for (var index = 0; index < nodes.length; index++) {
        scored.add(
          _scoreNode(
            nodes[index],
            index,
            baseUrl: context.baseUrl,
            documentUrl: context.documentUrl,
            pageVariants: pageVariants,
            isNested: collection.nestedNodes.contains(nodes[index]),
            budget: relevanceBudget,
          ),
        );
      }
      scored.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0
            ? byScore
            : a.originalIndex.compareTo(b.originalIndex);
      });

      // Primary strength belongs to the best page-describing node, which is
      // not necessarily the node with the highest raw relevance. `scored` is
      // already ordered, so the first node seen in the lowest tier wins.
      _ScoredNode? primary;
      for (final candidate in scored) {
        if (!candidate.describesPage) continue;
        if (primary == null || candidate.pageTier < primary.pageTier) {
          primary = candidate;
        }
      }
      // Structural and nested nodes contribute nothing, so they take no
      // extraction slot.
      final ordered = <_ScoredNode>[
        ?primary,
        for (final candidate in scored)
          if (!identical(candidate, primary) &&
              !candidate.isStructural &&
              !candidate.isNested)
            candidate,
      ];

      // Apply extraction to a small set of top nodes and allow lower-ranked nodes to contribute.
      final int limit = ordered.length < 12 ? ordered.length : 12;
      final extractionBudget = _JsonLdValueBudget(
        maxVisitedValues: limits.maxDerivedValues,
        maxDepth: limits.maxDepth,
      );
      for (var i = 0; i < limit; i++) {
        final sn = ordered[i];
        final strength = identical(sn, primary)
            ? _NodeStrength.primary
            : (i < 4 ? _NodeStrength.secondary : _NodeStrength.tertiary);
        _applyNodeToContext(
          context: context,
          node: sn.node,
          strength: strength,
          describesPage: sn.describesPage,
          contributesContext: sn.contributesContext,
          contributesMedia: !sn.isNested,
          nodesById: collection.nodesById,
          budget: extractionBudget,
        );
      }
      if (relevanceBudget.limitReached || extractionBudget.limitReached) {
        context.addWarning(
          MetaLinkWarning(
            code: MetaLinkWarningCode.partialParse,
            message: 'JSON-LD derived-field traversal stopped at its configured visit or depth limit.',
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

  /// The URLs that name this page for the foreign-document check: the final
  /// document URL and the first canonical `<link>` and `og:url` the page
  /// declares, normalized for comparison.
  ///
  /// A declared URL only keeps a page-like node from counting as another
  /// document's, as on an AMP or mobile page whose JSON-LD names the
  /// canonical article. It never identifies a node with the page, because
  /// sites commonly declare their homepage as every page's canonical URL.
  List<Uri> _pageVariants(HtmlExtractContext context) {
    final resolver = context.urlResolver;
    final canonical = resolver.resolveAll(context.baseUrl, [
      for (final link in context.document.querySelectorAll('link'))
        if ((link.attributes['rel'] ?? '')
            .toLowerCase()
            .split(_whitespace)
            .contains('canonical'))
          link.attributes['href'],
    ]).firstOrNull;
    final ogUrl = resolver
        .resolveAll(
          context.baseUrl,
          context.metaTags.find(const ['og:url']).map((tag) => tag.content),
        )
        .firstOrNull;
    return [
      for (final uri in [context.documentUrl, ?canonical, ?ogUrl])
        _normalizeUriForCompare(uri),
    ];
  }

  /// Scores [node] and decides which fields it may supply.
  ///
  /// Relative `url`, `@id`, and `mainEntityOfPage` values resolve against
  /// [baseUrl], which honors `<base href>`, and are compared with
  /// [documentUrl], the final document URL. [pageVariants] come from
  /// [_pageVariants]. [isNested] tells whether every definition of the node
  /// sits below a structural node or a `review` or `reviews` property.
  _ScoredNode _scoreNode(
    Map<String, dynamic> node,
    int originalIndex, {
    required Uri baseUrl,
    required Uri documentUrl,
    required List<Uri> pageVariants,
    required bool isNested,
    required _JsonLdValueBudget budget,
  }) {
    // Higher score means the node is more likely to describe the page itself.
    double score = 0.0;
    var matchesPage = false;
    var namesOtherDocument = false;

    final normalizedDocument = _normalizeUriForCompare(documentUrl);

    // URL signals, weighted toward exact matches with the final page URL.
    void scoreUrls(
      dynamic value, {
      required bool referencesPage,
      required bool locatesDocument,
    }) {
      for (final u in _extractUris(value, baseUrl: baseUrl, budget: budget)) {
        final nu = _normalizeUriForCompare(u);
        final sameDocument = _isSameDocument(nu, normalizedDocument);
        if (nu.toString() == normalizedDocument.toString()) {
          score += _JsonLdScores.urlExactMatch;
        } else if (sameDocument) {
          score += _JsonLdScores.urlPathMatch;
        } else if (nu.host == normalizedDocument.host) {
          score += _JsonLdScores.urlHostMatch;
        }
        // In `url` and `@id`, a fragment such as `<page>#comment-1` or
        // `<page>#primaryimage` names a resource inside a document, so it
        // neither matches this page nor names another document; it still
        // raises relevance. `mainEntityOfPage` references a page itself, so
        // its fragment is ignored.
        if (!referencesPage && u.hasFragment) continue;
        if (sameDocument) {
          matchesPage = true;
        } else if (locatesDocument &&
            !pageVariants.any((page) => _isPageVariant(nu, page))) {
          // Only `url` and `mainEntityOfPage` locate a document. An `@id` is
          // a node identifier and is often a synthetic IRI, so a mismatch
          // there says nothing about which page the node describes.
          namesOtherDocument = true;
        }
      }
    }

    scoreUrls(node['url'], referencesPage: false, locatesDocument: true);
    scoreUrls(node['@id'], referencesPage: false, locatesDocument: false);
    scoreUrls(
      node['mainEntityOfPage'],
      referencesPage: true,
      locatesDocument: true,
    );

    final types = _types(node);
    if (types.isNotEmpty) {
      // Prefer page-like or primary content types, including their
      // schema.org subtypes, for the page-level candidate.
      if (_hasType(types, _relevantPageTypes)) {
        score += _JsonLdScores.typePrimary;
      } else if (_hasType(types, const {'WebSite', 'Organization', 'Person'})) {
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

    final isContent = _hasType(types, _primaryContentTypes);
    final isPageLike = isContent || _hasType(types, _pageContainerTypes);
    // Page structure (navigation, breadcrumbs, images, comments, offers, ...)
    // never describes the page, even at the page URL. A page-like type wins
    // over a structural one on the same node.
    final isStructural = !isPageLike && _hasType(types, _structuralTypes);
    // A page-like node whose `url` or `mainEntityOfPage` names another
    // document, such as a story in a listing, describes that document rather
    // than this page.
    final isForeign = isPageLike && namesOtherDocument && !matchesPage;
    return _ScoredNode(
      node,
      score,
      originalIndex,
      // An untyped node, such as a breadcrumb entry `{"@id": <page>,
      // "name": ...}`, says nothing about what the page is, so it never
      // describes the page even when its `@id` matches.
      describesPage:
          _isTyped(node) &&
          !isNested &&
          !isStructural &&
          (matchesPage || (isPageLike && !isForeign)),
      contributesContext: !isNested && !isStructural && !isForeign,
      isStructural: isStructural,
      isNested: isNested,
      // Tier 0: content (Article, Product, ...) identified with this page.
      // Tier 1: anything else identified with this page, such as WebPage.
      // Tier 2: page-like by type only, with no URL naming any document.
      pageTier: matchesPage ? (isContent ? 0 : 1) : 2,
    );
  }

  Uri _normalizeUriForCompare(Uri uri) {
    // Remove fragments and normalize casing to compare URLs consistently.
    // `Uri` already omits default ports such as `:443`.
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
    // `https://example.com` and `https://example.com/` name the same page.
    if (u.hasAuthority && u.path.isEmpty) {
      u = u.replace(path: '/');
    }
    return u;
  }

  /// The path of a normalized [uri] without one trailing slash, so
  /// `/post/` and `/post` compare equal. The root path stays `/`.
  static String _pathKey(Uri uri) {
    final path = uri.path;
    return path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
  }

  /// Whether the normalized [uri] identifies the same document as the
  /// normalized [document]: the hosts are equal, the paths are equal apart
  /// from one trailing slash, and the query parameters are equal as
  /// multisets, so `?b=2&a=1` matches `?a=1&b=2` but not `?a=1`. The scheme
  /// is ignored.
  static bool _isSameDocument(Uri uri, Uri document) {
    if (uri.host != document.host || _pathKey(uri) != _pathKey(document)) {
      return false;
    }
    final params = _queryParameters(uri);
    final documentParams = _queryParameters(document);
    if (params == null || documentParams == null) {
      return uri.query == document.query;
    }
    if (params.length != documentParams.length) return false;
    for (final entry in params.entries) {
      final values = documentParams[entry.key];
      if (values == null || values.length != entry.value.length) return false;
      for (var i = 0; i < values.length; i++) {
        if (values[i] != entry.value[i]) return false;
      }
    }
    return true;
  }

  /// Whether the normalized [uri] is a variant of the normalized [page], so
  /// it does not name another document: the hosts are equal apart from a
  /// leading `www.` label, the paths are equal apart from one trailing
  /// slash, and every query parameter of [uri], key and value, is also one
  /// of [page]'s. The scheme is ignored.
  static bool _isPageVariant(Uri uri, Uri page) {
    String site(String host) =>
        host.startsWith('www.') ? host.substring(4) : host;
    if (site(uri.host) != site(page.host) || _pathKey(uri) != _pathKey(page)) {
      return false;
    }
    final params = _queryParameters(uri);
    final pageParams = _queryParameters(page);
    if (params == null || pageParams == null) {
      return uri.query.isEmpty || uri.query == page.query;
    }
    for (final entry in params.entries) {
      final pageValues = pageParams[entry.key];
      if (pageValues == null) return false;
      for (final value in entry.value) {
        if (!pageValues.contains(value)) return false;
      }
    }
    return true;
  }

  /// The decoded query parameters of [uri], each key's values sorted, or
  /// `null` when the query cannot be decoded.
  static Map<String, List<String>>? _queryParameters(Uri uri) {
    if (uri.query.isEmpty) return const {};
    try {
      return {
        for (final entry in uri.queryParametersAll.entries)
          entry.key: [...entry.value]..sort(),
      };
    } on Object {
      return null;
    }
  }

  void _applyNodeToContext({
    required HtmlExtractContext context,
    required Map<String, dynamic> node,
    required _NodeStrength strength,
    required bool describesPage,
    required bool contributesContext,
    required bool contributesMedia,
    required Map<String, Map<String, dynamic>> nodesById,
    required _JsonLdValueBudget budget,
  }) {
    // Never throw from this so a single node cannot break extraction.
    try {
      final types = _types(node);
      final evidence = _evidenceFor(node, types);

      // Kind, canonical URL, title, description, locale, and images describe
      // the page itself, so only page-describing nodes may supply them. Other
      // context nodes (WebSite, Organization, Person, ...) still supply site
      // name, authors, dates, and keywords. Structural nodes, nested nodes,
      // and page-like nodes of another document supply none of those. Every
      // node that is not nested may supply video and audio URLs.

      // 1) Kind: map schema types into `LinkKind` for classification. The
      //    generic `other` kind of a WebPage, or of a WebPage subtype without
      //    a kind of its own, uses a fallback score below every other kind
      //    signal, so `og:type` or a more specific JSON-LD type decides
      //    whenever one is present.
      final kind = describesPage ? _kindFromTypes(types) : null;
      if (kind != null) {
        context.setKind(
          kind,
          source: CandidateSource.jsonLd,
          score: kind == LinkKind.other
              ? _JsonLdScores.kindGenericFallback
              : _scoreFor(
                  strength,
                  primary: _JsonLdScores.kindPrimary,
                  secondary: _JsonLdScores.kindSecondary,
                  tertiary: _JsonLdScores.kindTertiary,
                ),
          evidence: evidence,
        );
      }

      // 2) Canonical URL: pick the best URL-like field as a stable reference.
      final canonical = describesPage
          ? _firstUriFrom(
              candidates: [node['mainEntityOfPage'], node['url'], node['@id']],
              baseUrl: context.baseUrl,
              budget: budget,
            )
          : null;
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
      final title = describesPage ? _bestTitle(node) : null;
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
      final description = describesPage ? _asString(node['description']) : null;
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
      final locale = describesPage
          ? _asString(node['inLanguage']) ?? _asString(node['@language'])
          : null;
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
      final siteName = contributesContext
          ? _publisherName(node, nodesById, budget) ??
                _siteNameFromWebSiteNode(node, types)
          : null;
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
      for (final author
          in contributesContext
              ? _entityNames(node['author'], nodesById, budget)
              : const <String>[]) {
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
      final publishedAt = contributesContext
          ? _tryParseDateTime(node['datePublished']) ??
                _tryParseDateTime(node['uploadDate']) ??
                _tryParseDateTime(node['startDate'])
          : null;
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

      final modifiedAt = contributesContext
          ? _tryParseDateTime(node['dateModified'])
          : null;
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
      for (final kw
          in contributesContext
              ? _keywords(node['keywords'], budget)
              : const <String>[]) {
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
        if (describesPage) ...[
          node['image'],
          node['thumbnailUrl'],
          node['logo'],
        ],
      ];
      for (final v in imageValues) {
        for (final uri in _extractUris(
          v,
          baseUrl: context.baseUrl,
          budget: budget,
          nodesById: nodesById,
          media: true,
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

      // 11) Videos or Audios: extract media URLs for rich previews. A video
      //     embedded in an article names its host page, so another
      //     document's media still counts; a list entry's media does not.
      if (contributesMedia && _hasType(types, const {'VideoObject'})) {
        for (final uri in _extractUris(
          node['contentUrl'],
          baseUrl: context.baseUrl,
          budget: budget,
          nodesById: nodesById,
          media: true,
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
          nodesById: nodesById,
          media: true,
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

      if (contributesMedia && _hasType(types, const {'AudioObject'})) {
        for (final uri in _extractUris(
          node['contentUrl'],
          baseUrl: context.baseUrl,
          budget: budget,
          nodesById: nodesById,
          media: true,
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

  /// The first publisher name of [node], read like an author value: a
  /// string, an object's `name`, or the `name` of an `@id`-referenced
  /// definition, including entries of a `publisher` array.
  String? _publisherName(
    Map<String, dynamic> node,
    Map<String, Map<String, dynamic>> nodesById,
    _JsonLdValueBudget budget,
  ) {
    final names = _entityNames(node['publisher'], nodesById, budget);
    return names.isEmpty ? null : names.first;
  }

  /// The string `name` of the node that [map] references by `@id`, or `null`
  /// when [map] has no `@id` or [nodesById] has no definition for it.
  String? _referencedName(
    Map<String, dynamic> map,
    Map<String, Map<String, dynamic>> nodesById,
  ) {
    final id = _asString(map['@id']);
    if (id == null) return null;
    final definition = nodesById[id];
    return definition == null ? null : _asString(definition['name']);
  }

  String? _siteNameFromWebSiteNode(
    Map<String, dynamic> node,
    List<String> types,
  ) {
    // For WebSite nodes, name typically represents the site name.
    if (_hasType(types, const {'WebSite'})) {
      return _asString(node['name']) ?? _asString(node['headline']);
    }
    return null;
  }

  /// Entity names in an `author` or `publisher` [root] value, in order.
  ///
  /// Strings are names, objects contribute their `name`, an object without a
  /// `name` contributes the `name` of the definition its `@id` references,
  /// and arrays are read entry by entry. The walk is bounded by [budget].
  List<String> _entityNames(
    dynamic root,
    Map<String, Map<String, dynamic>> nodesById,
    _JsonLdValueBudget budget,
  ) {
    if (root == null) return const <String>[];
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
        if (map == null) continue;
        final name = _asString(map['name']);
        if (name != null) {
          out.add(name);
          continue;
        }
        // A `{"@id": ...}` reference takes the name of its merged definition.
        // The name is queued one level deeper so the budget still bounds it.
        // A queued string never resolves again, so references cannot cycle,
        // and the `@id` IRI itself is never used as a name.
        final referenced = _referencedName(map, nodesById);
        if (referenced != null &&
            budget.canEnqueue(entry.depth + 1, stack.length)) {
          stack.add(_TraversalEntry(referenced, entry.depth + 1));
        }
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

  DateTime? _tryParseDateTime(dynamic value) => switch (value) {
    final String s => DateUtils.parseString(s),
    final int epoch => DateUtils.parseEpoch(epoch),
    _ => null,
  };

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

  /// URLs found in a JSON-LD [value], resolved against [baseUrl].
  ///
  /// With [media] unset, the walk reads identity fields: strings, and the
  /// `url` and `@id` of nested objects such as a `mainEntityOfPage`
  /// reference. With [media] set, it reads only media URL fields and resolves
  /// `@id` references through [nodesById]; see [_mediaUrlValues].
  List<Uri> _extractUris(
    dynamic value, {
    required Uri baseUrl,
    required _JsonLdValueBudget budget,
    Map<String, Map<String, dynamic>> nodesById = const {},
    bool media = false,
  }) {
    final urls = <String>[];
    _collectUrlStrings(value, urls, budget, nodesById: nodesById, media: media);

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
    _JsonLdValueBudget budget, {
    required Map<String, Map<String, dynamic>> nodesById,
    required bool media,
  }) {
    final stack = <_TraversalEntry>[_TraversalEntry(root, 0)];
    final resolvedIds = <String>{};
    // `sameAs`, `logo`, and media URLs of a nested object never identify a
    // page, so identity walks read only `url` and `@id`.
    const identityKeys = <String>['url', '@id'];

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
        final children = media
            ? _mediaUrlValues(map, nodesById, resolvedIds)
            : <dynamic>[
                for (final key in identityKeys)
                  if (_isUrlValue(map[key])) map[key],
              ];
        for (final child in children.reversed) {
          if (budget.canEnqueue(entry.depth + 1, stack.length)) {
            stack.add(_TraversalEntry(child, entry.depth + 1));
          }
        }
      }
    }
  }

  /// Values of [map] that can hold a media URL.
  ///
  /// `@id` and `sameAs` identify an entity rather than locate a file, so they
  /// are never read directly. When [map] has no `url` or `contentUrl`, its
  /// `@id` is resolved through [nodesById] to the merged definition's `url`
  /// and `contentUrl`. The bare `@id` is used only when nothing resolves, the
  /// map has no other media field, and the IRI has no fragment. A fragment
  /// such as `<page>#primaryimage` names a resource inside a page; read as a
  /// URL it would point at the page itself. [resolvedIds] lets each `@id`
  /// resolve once per walk, which stops reference cycles.
  List<dynamic> _mediaUrlValues(
    Map<String, dynamic> map,
    Map<String, Map<String, dynamic>> nodesById,
    Set<String> resolvedIds,
  ) {
    const mediaKeys = <String>[
      'url',
      'contentUrl',
      'embedUrl',
      'thumbnailUrl',
      'logo',
    ];
    final values = <dynamic>[
      for (final key in mediaKeys)
        if (_isUrlValue(map[key])) map[key],
    ];
    if (_isUrlValue(map['url']) || _isUrlValue(map['contentUrl'])) {
      return values;
    }

    final id = _asString(map['@id']);
    if (id == null) return values;
    final definition = nodesById[id];
    final resolved = <dynamic>[
      if (definition != null)
        for (final key in const ['url', 'contentUrl'])
          if (_isUrlValue(definition[key])) definition[key],
    ];
    if (resolved.isNotEmpty) {
      if (resolvedIds.add(id)) values.addAll(resolved);
      return values;
    }
    if (values.isEmpty && !id.contains('#') && !id.startsWith('_:')) {
      values.add(id);
    }
    return values;
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

  /// The [LinkKind] that the schema.org [types] of a page-describing node
  /// imply, or `null` when they imply none.
  ///
  /// A subtype maps like its parent family: every `Article` subtype, such as
  /// `OpinionNewsArticle` or `TechArticle`, is an article; every `Product`
  /// and `Event` subtype is a product or an event; `Clip` subtypes are
  /// videos; `Audiobook` is audio; `CollectionPage` subtypes are galleries;
  /// and any other `WebPage` subtype is the generic `other` kind.
  LinkKind? _kindFromTypes(List<String> types) {
    if (types.isEmpty) return null;

    if (_hasType(types, _articleTypes)) {
      return LinkKind.article;
    }
    if (_hasType(types, _productTypes) ||
        _hasType(types, const {'AggregateOffer', 'Offer', 'Brand'})) {
      return LinkKind.product;
    }
    if (_hasType(types, _videoTypes)) {
      return LinkKind.video;
    }
    if (_hasType(types, _audioTypes)) {
      return LinkKind.audio;
    }
    if (_hasType(types, const {'ProfilePage'})) {
      return LinkKind.profile;
    }
    if (_hasType(types, const {'WebSite'})) {
      return LinkKind.homepage;
    }
    if (_hasType(types, const {'SearchAction'})) {
      return LinkKind.search;
    }
    if (_hasType(types, _collectionPageTypes)) {
      return LinkKind.gallery;
    }
    if (_hasType(types, _eventTypes)) {
      return LinkKind.event;
    }

    // Some sites overuse WebPage; treat it and its remaining subtypes as a
    // generic fallback type. The caller scores this kind below every other
    // kind signal.
    if (_hasType(types, _pageContainerTypes)) {
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
///
/// Every limit applies to one document. When [JsonLdExtractor] reaches a
/// limit, it keeps the nodes collected so far and reports a
/// [MetaLinkWarningCode.partialParse] warning.
class JsonLdTraversalLimits {
  /// Creates JSON-LD traversal limits for [JsonLdExtractor].
  ///
  /// [maxDepth] must not be negative, and every other limit must be greater
  /// than zero. These preconditions are checked by assertions, so they are
  /// enforced only when assertions are enabled.
  const JsonLdTraversalLimits({
    this.maxNodes = 250,
    this.maxVisitedValues = 4000,
    this.maxDepth = 64,
    this.maxJsonCharacters = 512 * 1024,
    this.maxDerivedValues = 4000,
  }) : assert(maxNodes > 0, 'maxNodes must be greater than zero.'),
       assert(
         maxVisitedValues > 0,
         'maxVisitedValues must be greater than zero.',
       ),
       assert(maxDepth >= 0, 'maxDepth must not be negative.'),
       assert(
         maxJsonCharacters > 0,
         'maxJsonCharacters must be greater than zero.',
       ),
       assert(
         maxDerivedValues > 0,
         'maxDerivedValues must be greater than zero.',
       );

  /// Maximum number of distinct nodes retained across a document's scripts.
  ///
  /// A repeated definition of an `@id` merges into the existing node and does
  /// not count again. Collection stops once this many nodes are retained, and
  /// the result is reported as partial only if another node remains unread.
  final int maxNodes;

  /// Maximum number of JSON values visited while collecting nodes, summed
  /// across a document's scripts.
  ///
  /// The root value and every non-empty nested map and list count once each.
  /// Scalars and empty containers need no visit and are not counted.
  final int maxVisitedValues;

  /// Maximum nesting depth followed below a traversal root.
  ///
  /// The root is a script's decoded value while collecting nodes, or a node
  /// property while deriving fields. Deeper values are skipped, and a stored
  /// node replaces every non-empty map or list deeper than this below the
  /// script root with `null`.
  final int maxDepth;

  /// Maximum aggregate JSON-LD script characters decoded from one document.
  ///
  /// A script that would push the total past this limit is skipped without
  /// being decoded; later scripts that still fit are decoded.
  final int maxJsonCharacters;

  /// Maximum nested values inspected while deriving fields from retained nodes.
  final int maxDerivedValues;
}

_JsonLdCollection _collectJsonLdNodes(
  Document document, {
  required JsonLdTraversalLimits limits,
}) {
  final scripts = <Element>[
    for (final el in document.querySelectorAll('script'))
      if (_isJsonLdScript(el)) el,
  ];
  final out = <Map<String, dynamic>>[];
  final nodesById = <String, Map<String, dynamic>>{};
  final nestedNodes = Set<Map<String, dynamic>>.identity();
  var visitedValues = 0;
  var malformedScripts = 0;
  var limitReached = false;
  var decodedCharacters = 0;

  for (final el in scripts) {
    final raw = el.text;
    if (raw.trim().isEmpty) continue;
    if (raw.length > limits.maxJsonCharacters - decodedCharacters) {
      // Skip only this script; later, smaller scripts may still fit the
      // remaining aggregate budget.
      limitReached = true;
      continue;
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
      nodesById: nodesById,
      nestedNodes: nestedNodes,
    );
    out.addAll(traversal.nodes);
    visitedValues += traversal.visitedValues;
    limitReached = limitReached || traversal.limitReached;

    // Once a budget is used up, later scripts are only probed: an empty or
    // scalar script drops nothing, and the first one that could hold a node
    // marks the result as partial. Ordinary `<script>` elements are never
    // probed. After that, no later script can change the result.
    if (limitReached &&
        (visitedValues >= limits.maxVisitedValues ||
            out.length >= limits.maxNodes)) {
      break;
    }
  }

  return _JsonLdCollection(
    nodes: List<Map<String, dynamic>>.unmodifiable(out),
    nodesById: Map<String, Map<String, dynamic>>.unmodifiable(nodesById),
    nestedNodes: nestedNodes,
    malformedScripts: malformedScripts,
    limitReached: limitReached,
  );
}

bool _isJsonLdScript(Element element) {
  final typeAttr = (element.attributes['type'] ?? '').toLowerCase().trim();
  return typeAttr.contains('ld+json') || typeAttr.contains('json+ld');
}

/// Collects the nodes in one script's decoded [root] value.
///
/// New nodes are returned, and repeated `@id` definitions merge into
/// [nodesById]. A node is added to [nestedNodes] when its first definition
/// is reached through a map typed with one of [_structuralTypes] or through
/// a `review` or `reviews` property, and removed again when any definition
/// of it is reached without such an ancestor. A zero [maxVisitedValues]
/// still accepts an empty or scalar [root] without reporting a limit.
_JsonLdTraversal _deepCollectNodes(
  dynamic root, {
  required int maxNodes,
  required int maxVisitedValues,
  required int maxDepth,
  required Map<String, Map<String, dynamic>> nodesById,
  required Set<Map<String, dynamic>> nestedNodes,
}) {
  final nodes = <Map<String, dynamic>>[];
  if (!_mayHoldNodes(root)) {
    return const _JsonLdTraversal(
      nodes: [],
      visitedValues: 0,
      limitReached: false,
    );
  }
  if (maxVisitedValues <= 0) {
    return const _JsonLdTraversal(
      nodes: [],
      visitedValues: 0,
      limitReached: true,
    );
  }

  final copier = _NodeValueCopier(maxDepth: maxDepth);
  final stack = <_TraversalEntry>[_TraversalEntry(root, 0)];
  var visitedValues = 0;
  var limitReached = false;
  // With the node budget full, the walk continues only to learn whether
  // anything was dropped: the first node-like map it meets ends it as partial.
  var probing = maxNodes <= 0;

  // Children of one container share a depth. [pending] holds only values
  // that may hold nodes.
  void enqueueAll(List<_TraversalEntry> pending, int depth) {
    if (pending.isEmpty) return;
    if (depth > maxDepth) {
      limitReached = true;
      return;
    }
    final remaining = maxVisitedValues - visitedValues - stack.length;
    if (remaining < pending.length) limitReached = true;
    if (remaining <= 0) return;
    stack.addAll(pending.take(remaining).toList().reversed);
  }

  while (stack.isNotEmpty) {
    if (visitedValues >= maxVisitedValues) {
      limitReached = true;
      break;
    }

    final entry = stack.removeLast();
    visitedValues++;
    final current = entry.value;

    // Only non-empty maps and lists can hold nodes. Scalars and empty
    // containers stay in their stored parent, so skipping them drops nothing
    // and must not report a partial result.
    if (current is List) {
      final depth = entry.depth + 1;
      enqueueAll([
        for (final value in current)
          if (_mayHoldNodes(value))
            _TraversalEntry(value, depth, nested: entry.nested),
      ], depth);
      continue;
    }

    if (current is Map) {
      final map = _stringKeyedMap(current);
      if (map == null) continue;

      if (_looksLikeNode(map)) {
        if (probing) {
          limitReached = true;
          break;
        }
        final id = _asString(map['@id']);
        final existing = id == null ? null : nodesById[id];
        if (existing != null) {
          // Merging never adds a node, so `maxNodes` is unaffected.
          _mergeDefinition(existing, map, copier, entry.depth);
          // One definition outside lists and reviews makes the node the
          // page's own, wherever its other definitions sit.
          if (!entry.nested) nestedNodes.remove(existing);
        } else {
          final node = <String, dynamic>{
            for (final property in map.entries)
              property.key: copier.copy(property.value, entry.depth + 1),
          };
          if (id != null) nodesById[id] = node;
          if (entry.nested) nestedNodes.add(node);
          nodes.add(node);
          if (nodes.length >= maxNodes) probing = true;
        }
      }

      // Everything below a structural map, such as a list entry, an offer,
      // or an image, and everything in a `review` or `reviews` property, is
      // nested.
      final nestsChildren =
          entry.nested || _hasType(_types(map), _structuralTypes);
      final depth = entry.depth + 1;
      // Traverse every child exactly once. `@graph` is a normal map value and
      // must not be pushed separately, otherwise graph nodes are duplicated.
      enqueueAll([
        for (final property in map.entries)
          if (_mayHoldNodes(property.value))
            _TraversalEntry(
              property.value,
              depth,
              nested:
                  nestsChildren ||
                  property.key == 'review' ||
                  property.key == 'reviews',
            ),
      ], depth);
    }
  }

  if (stack.isNotEmpty) limitReached = true;
  return _JsonLdTraversal(
    nodes: List<Map<String, dynamic>>.unmodifiable(nodes),
    visitedValues: visitedValues,
    limitReached: limitReached,
  );
}

/// Merges a repeated definition of a node's `@id` into [existing].
///
/// JSON-LD flattening: the node keeps its first-seen position, and [later]
/// fills only the properties [existing] lacks. The exception is a typed
/// definition arriving after an untyped one, which wins conflicting
/// properties, so a breadcrumb item such as `{"@id": <page>, "name": "Leaf"}`
/// seen before the page's `WebPage` cannot rename it.
void _mergeDefinition(
  Map<String, dynamic> existing,
  Map<String, dynamic> later,
  _NodeValueCopier copier,
  int depth,
) {
  final laterWins = _isTyped(later) && !_isTyped(existing);
  for (final property in later.entries) {
    if (laterWins || !existing.containsKey(property.key)) {
      existing[property.key] = copier.copy(property.value, depth + 1);
    }
  }
}

/// Copies decoded JSON values for storage in a node, pruned at `maxDepth`.
///
/// Traversal limits alone leave the raw subtree of a stored node intact, so a
/// script nested thousands of levels deep would make `jsonEncode` of the
/// stored graph overflow the stack. A non-empty map or list deeper than
/// `maxDepth` below the script root becomes `null`; traversal reports that
/// as a partial result. Copies are memoized per source container, so each
/// container is copied once even when it sits inside several stored nodes,
/// and copying is iterative, so it never recurses.
class _NodeValueCopier {
  _NodeValueCopier({required this.maxDepth});

  final int maxDepth;
  final Map<Object, Object> _copies = Map<Object, Object>.identity();
  final List<(Object, Object, int)> _pending = [];

  /// A storable copy of [value], which sits [depth] levels below the root.
  dynamic copy(dynamic value, int depth) {
    final result = _shallowCopy(value, depth);
    while (_pending.isNotEmpty) {
      final (source, target, sourceDepth) = _pending.removeLast();
      if (source is Map && target is Map<String, dynamic>) {
        for (final entry in source.entries) {
          final key = entry.key;
          if (key is String) {
            target[key] = _shallowCopy(entry.value, sourceDepth + 1);
          }
        }
      } else if (source is List && target is List<dynamic>) {
        for (final element in source) {
          target.add(_shallowCopy(element, sourceDepth + 1));
        }
      }
    }
    return result;
  }

  dynamic _shallowCopy(dynamic value, int depth) {
    if (value is Map) {
      if (value.isEmpty) return <String, dynamic>{};
      if (depth > maxDepth) return null;
      final cached = _copies[value];
      if (cached != null) return cached;
      final target = <String, dynamic>{};
      _copies[value] = target;
      _pending.add((value, target, depth));
      return target;
    }
    if (value is List) {
      if (value.isEmpty) return <dynamic>[];
      if (depth > maxDepth) return null;
      final cached = _copies[value];
      if (cached != null) return cached;
      final target = <dynamic>[];
      _copies[value] = target;
      _pending.add((value, target, depth));
      return target;
    }
    return value;
  }
}

class _JsonLdCollection {
  const _JsonLdCollection({
    required this.nodes,
    required this.nodesById,
    required this.nestedNodes,
    required this.malformedScripts,
    required this.limitReached,
  });

  final List<Map<String, dynamic>> nodes;

  /// Merged node definitions keyed by `@id`, used to resolve references.
  final Map<String, Map<String, dynamic>> nodesById;

  /// The [nodes], by identity, that are nested: every definition of each
  /// sits below a structural node or in a `review` or `reviews` property.
  /// The flag is kept here so the stored graph stays unchanged.
  final Set<Map<String, dynamic>> nestedNodes;
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
  const _TraversalEntry(this.value, this.depth, {this.nested = false});

  final dynamic value;
  final int depth;

  /// Whether [value] sits below a structural node or in a `review` or
  /// `reviews` property; tracked only while collecting nodes.
  final bool nested;
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

bool _isUrlValue(dynamic value) =>
    value is String || value is List || value is Map;

/// ASCII whitespace, which separates the tokens of an HTML `rel` attribute.
final RegExp _whitespace = RegExp(r'[\t\n\f\r ]+');

bool _mayHoldNodes(dynamic value) =>
    (value is Map && value.isNotEmpty) || (value is List && value.isNotEmpty);

bool _isTyped(Map<String, dynamic> map) {
  final type = map['@type'];
  if (type is String) return type.trim().isNotEmpty;
  if (type is List) {
    return type.any((item) => item is String && item.trim().isNotEmpty);
  }
  return false;
}

String? _asString(dynamic value) {
  if (value is String) {
    final s = value.trim();
    return s.isEmpty ? null : s;
  }
  return null;
}

bool _looksLikeNode(Map<String, dynamic> map) {
  // A map holding only `@id` references a node defined elsewhere. Treating it
  // as a node would let the reference claim the id before its definition.
  if (map.length == 1 && map.containsKey('@id')) return false;
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

  /// Score of the generic `other` kind from a `WebPage`, or from a `WebPage`
  /// subtype without a kind of its own, such as `FAQPage`. It sits below
  /// [kindTertiary] and the Open Graph kind score (`0.70`), so it decides the
  /// kind only when no other source provides one.
  static const double kindGenericFallback = 0.40;

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
  _ScoredNode(
    this.node,
    this.score,
    this.originalIndex, {
    required this.describesPage,
    required this.contributesContext,
    required this.isStructural,
    required this.isNested,
    required this.pageTier,
  });

  final Map<String, dynamic> node;
  final double score;
  final int originalIndex;

  /// Whether the node may supply page-level fields: title, description,
  /// canonical URL, images, kind, and locale.
  ///
  /// True when the node has an `@type`, is neither structural nor nested,
  /// and either one of its `url`, `@id`, or `mainEntityOfPage` identifies the
  /// document, or it is page-like by type and neither its `url` nor its
  /// `mainEntityOfPage` names another document. A URL identifies the
  /// document when its host, its path apart from one trailing slash, and its
  /// query parameters in any order equal the final document URL's. A URL
  /// names another document unless it identifies the document or is a
  /// variant of the document URL, the first canonical `<link>`, or the first
  /// `og:url`. A `#fragment` in `url` or `@id` does neither.
  final bool describesPage;

  /// Whether the node may supply site name, authors, dates, and keywords.
  ///
  /// False for structural nodes, nested nodes, and page-like nodes of
  /// another document. Untyped nodes may still contribute.
  final bool contributesContext;

  /// Whether the node is typed only as page structure; see [_structuralTypes].
  final bool isStructural;

  /// Whether every definition of the node sits below a structural node or
  /// in a `review` or `reviews` property, such as a list entry or a product
  /// review. A nested node supplies no fields at all, not even media.
  final bool isNested;

  /// Preference among page-describing nodes for primary strength; lower wins.
  final int pageTier;
}

/// The schema.org `@type` values of [node], each reduced to its local name
/// so `schema:Article` and `https://schema.org/Article` read as `Article`.
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

/// Whether any of [types] is one of [wanted].
bool _hasType(List<String> types, Set<String> wanted) =>
    types.any(wanted.contains);

/// `WebPage` and its schema.org subtypes.
const Set<String> _pageContainerTypes = {
  'WebPage',
  'AboutPage',
  'CheckoutPage',
  'ContactPage',
  'FAQPage',
  'ItemPage',
  'MedicalWebPage',
  'ProfilePage',
  'QAPage',
  'RealEstateListing',
  'SearchResultsPage',
  ..._collectionPageTypes,
};

/// `CollectionPage` and its schema.org subtypes, which are galleries.
const Set<String> _collectionPageTypes = {
  'CollectionPage',
  'MediaGallery',
  'ImageGallery',
  'VideoGallery',
};

/// Types that describe parts of a page or values attached to an entity.
///
/// A node with one of these types, and no page-like type, never describes
/// the page or supplies author, date, site name, or keyword context, even
/// when its `url` matches the page: a navigation item, breadcrumb entry,
/// image, comment, or offer often links the page it sits on. Every node
/// below a map with one of these types is nested.
const Set<String> _structuralTypes = {
  // Lists and breadcrumbs.
  'BreadcrumbList',
  'ItemList',
  'ListItem',
  // WebPageElement and its subtypes.
  'WebPageElement',
  'SiteNavigationElement',
  'Table',
  'WPAdBlock',
  'WPFooter',
  'WPHeader',
  'WPSideBar',
  // Media attached to a page or entity.
  'ImageObject',
  // User contributions.
  'Comment',
  'Answer',
  // Commerce and rating values.
  'Offer',
  'AggregateOffer',
  'PriceSpecification',
  'UnitPriceSpecification',
  'Rating',
  'AggregateRating',
  // Actions and their targets.
  'SearchAction',
  'ReadAction',
  'EntryPoint',
  // Contact details.
  'ContactPoint',
  'PostalAddress',
};

/// `Article` and its schema.org subtypes.
const Set<String> _articleTypes = {
  'Article',
  'AdvertiserContentArticle',
  'NewsArticle',
  'AnalysisNewsArticle',
  'AskPublicNewsArticle',
  'BackgroundNewsArticle',
  'OpinionNewsArticle',
  'ReportageNewsArticle',
  'ReviewNewsArticle',
  'Report',
  'SatiricalArticle',
  'ScholarlyArticle',
  'MedicalScholarlyArticle',
  'SocialMediaPosting',
  'BlogPosting',
  'LiveBlogPosting',
  'DiscussionForumPosting',
  'TechArticle',
  'APIReference',
};

/// `Product` and its schema.org subtypes.
const Set<String> _productTypes = {
  'Product',
  'DietarySupplement',
  'Drug',
  'IndividualProduct',
  'ProductCollection',
  'ProductGroup',
  'ProductModel',
  'SomeProducts',
  'Vehicle',
  'BusOrCoach',
  'Car',
  'Motorcycle',
  'MotorizedBicycle',
};

/// `Event` and its schema.org subtypes.
///
/// `CourseInstance` is left out: it is an offering nested in a `Course` and
/// would take over the course page.
const Set<String> _eventTypes = {
  'Event',
  'BusinessEvent',
  'ChildrensEvent',
  'ComedyEvent',
  'DanceEvent',
  'DeliveryEvent',
  'EducationEvent',
  'EventSeries',
  'ExhibitionEvent',
  'Festival',
  'FoodEvent',
  'Hackathon',
  'LiteraryEvent',
  'MusicEvent',
  'PublicationEvent',
  'BroadcastEvent',
  'OnDemandEvent',
  'SaleEvent',
  'ScreeningEvent',
  'SocialEvent',
  'SportsEvent',
  'TheaterEvent',
  'VisualArtsEvent',
};

/// Types classified as video: `VideoObject`, `Clip` and its video
/// subtypes, `Movie`, and `TVEpisode`.
const Set<String> _videoTypes = {
  'VideoObject',
  'Clip',
  'MovieClip',
  'TVClip',
  'VideoGameClip',
  'Movie',
  'TVEpisode',
};

/// Types classified as audio: `AudioObject` and its subtype `Audiobook`,
/// `MusicRecording`, and `PodcastEpisode`.
const Set<String> _audioTypes = {
  'AudioObject',
  'Audiobook',
  'MusicRecording',
  'PodcastEpisode',
};

/// `SoftwareApplication` and its schema.org subtypes.
const Set<String> _softwareApplicationTypes = {
  'SoftwareApplication',
  'MobileApplication',
  'WebApplication',
  'VideoGame',
};

/// `Review` and its schema.org subtypes, except `ReviewNewsArticle`, which
/// is listed with the articles.
const Set<String> _reviewTypes = {
  'Review',
  'ClaimReview',
  'CriticReview',
  'EmployerReview',
  'MediaReview',
  'Recommendation',
  'UserReview',
};

/// Other `CreativeWork` types, and their subtypes, whose node is normally
/// the main content of its page.
///
/// `Question` is left out: FAQ pages list their questions as `mainEntity`, so
/// the first question would replace the page title.
const Set<String> _creativeWorkContentTypes = {
  'CreativeWork',
  'Book',
  'Course',
  'Dataset',
  'DataFeed',
  'Game',
  'Guide',
  'HowTo',
  'Recipe',
  'Legislation',
  'Map',
  'MusicComposition',
  'MusicPlaylist',
  'MusicAlbum',
  'MusicRelease',
  'MusicVideoObject',
  'Quiz',
  'SoftwareSourceCode',
  'Thesis',
  'VisualArtwork',
  'CoverArt',
  'Painting',
  'Photograph',
  'Sculpture',
  // Episodes, seasons, and series.
  'Episode',
  'RadioEpisode',
  'CreativeWorkSeason',
  'PodcastSeason',
  'RadioSeason',
  'TVSeason',
  'CreativeWorkSeries',
  'BookSeries',
  'MovieSeries',
  'Periodical',
  'PodcastSeries',
  'RadioSeries',
  'TVSeries',
  'VideoGameSeries',
};

/// Types whose node is normally the main content a page presents, each
/// family with its schema.org subtypes.
const Set<String> _primaryContentTypes = {
  ..._articleTypes,
  ..._productTypes,
  ..._eventTypes,
  ..._videoTypes,
  ..._audioTypes,
  ..._softwareApplicationTypes,
  ..._reviewTypes,
  ..._creativeWorkContentTypes,
  'JobPosting',
};

/// Types whose node earns the strongest relevance boost: `WebPage`,
/// `Article`, `Product`, and `Event`, each with its schema.org subtypes, and
/// `VideoObject`.
const Set<String> _relevantPageTypes = {
  ..._pageContainerTypes,
  ..._articleTypes,
  ..._productTypes,
  ..._eventTypes,
  'VideoObject',
};
