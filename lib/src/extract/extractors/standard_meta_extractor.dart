import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/util/date_utils.dart';
import 'package:metalink/src/util/html_utils.dart';

/// An extractor stage that reads generic HTML metadata: the document
/// `<title>`, the first `<h1>`, `html[lang]`, and standard `<meta>` tags.
///
/// Emits low-confidence fallbacks for the title, description, site name
/// (`application-name` or `apple-mobile-web-app-title`), locale
/// (`content-language` or `language`), keywords, author, and publish and
/// modify dates, so richer sources such as Open Graph win when present. Only
/// a `<title>` in the HTML namespace counts, so an inline SVG `<title>` is
/// ignored.
///
/// `name`, `property`, and `http-equiv` keys match ASCII case-insensitively,
/// and for each key the first non-empty tag in document order is used. Dates
/// instead use the first value, in key priority and then document order, that
/// parses as a timestamp, so a placeholder such as `TBD` does not hide a
/// later valid date. The `keywords` value is split on commas and semicolons
/// and deduplicated case-insensitively. Does nothing when
/// `ExtractOptions.extractStandardMeta` is `false`.
class StandardMetaExtractor implements HtmlMetadataExtractorStage {
  /// Creates the stateless standard-meta extractor stage.
  const StandardMetaExtractor();

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractStandardMeta) return;

    final doc = context.document;
    final meta = context.metaTags;

    // Use <title> as a baseline title when richer metadata is missing. Like
    // the HTML document title, only a title element in the HTML namespace
    // counts, so an inline SVG <title> tooltip is ignored.
    final titleEl = doc
        .getElementsByTagName('title')
        .where((element) => element.namespaceUri == _htmlNamespace)
        .firstOrNull;
    final title = _cleanText(titleEl?.text);
    if (title != null) {
      context.addTitle(
        title,
        source: CandidateSource.standardMeta,
        score: _scoreTitle,
        evidence: '<title>',
      );
    }

    // Use the first <h1> as a low-confidence fallback title.
    final h1 = _cleanText(doc.querySelector('h1')?.text);
    if (h1 != null) {
      context.addTitle(
        h1,
        source: CandidateSource.standardMeta,
        score: _scoreHeadingTitle,
        evidence: '<h1>',
      );
    }

    // Use standard meta description as a summary fallback.
    final desc =
        _metaContent(meta, name: 'description') ??
        _metaContent(meta, property: 'description');
    if (desc != null) {
      context.addDescription(
        desc,
        source: CandidateSource.standardMeta,
        score: _scoreDescription,
        evidence: 'meta description',
      );
    }

    // Use application-name tags as site name hints when present.
    final appName =
        _metaContent(meta, name: 'application-name') ??
        _metaContent(meta, name: 'apple-mobile-web-app-title');
    if (appName != null) {
      context.addSiteName(
        appName,
        source: CandidateSource.standardMeta,
        score: _scoreSiteName,
        evidence: 'application-name',
      );
    }

    // Use language hints from html[lang] and meta tags to set locale.
    final htmlLang = _cleanText(doc.documentElement?.attributes['lang']);
    if (htmlLang != null) {
      context.addLocale(
        htmlLang,
        source: CandidateSource.standardMeta,
        score: _scoreLocale,
        evidence: 'html[lang]',
      );
    }

    final contentLanguage =
        _metaContent(meta, httpEquiv: 'content-language') ??
        _metaContent(meta, name: 'language');
    if (contentLanguage != null) {
      context.addLocale(
        contentLanguage,
        source: CandidateSource.standardMeta,
        score: _scoreLocaleAlt,
        evidence: 'content-language',
      );
    }

    // Split keywords into individual tags for downstream filtering.
    final keywordsRaw = _metaContent(meta, name: 'keywords');
    if (keywordsRaw != null) {
      final parts = keywordsRaw
          .split(RegExp(r'[;,]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final seen = <String>{};
      for (final k in parts) {
        final key = k.toLowerCase();
        if (!seen.add(key)) continue;
        context.addKeyword(
          k,
          source: CandidateSource.standardMeta,
          score: _scoreKeyword,
          evidence: 'meta keywords',
        );
      }
    }

    // Use author meta tags for attribution when other sources are absent.
    final author =
        _metaContent(meta, name: 'author') ??
        _metaContent(meta, property: 'author');
    if (author != null) {
      context.addAuthor(
        author,
        source: CandidateSource.standardMeta,
        score: _scoreAuthor,
        evidence: 'meta author',
      );
    }

    // Parse common publish and modify tags to populate timeline fields.
    final publishedAt = _firstDate(meta, const [
      ('pubdate', MetaKeyAttribute.name),
      ('publish-date', MetaKeyAttribute.name),
      ('publication_date', MetaKeyAttribute.name),
      ('date', MetaKeyAttribute.name),
      ('datePublished', MetaKeyAttribute.name),
      ('datePublished', MetaKeyAttribute.itemProp),
      ('article:published_time', MetaKeyAttribute.property),
    ]);
    if (publishedAt != null) {
      context.addPublishedAt(
        publishedAt,
        source: CandidateSource.standardMeta,
        score: _scorePublishedAt,
        evidence: 'published date meta',
      );
    }

    final modifiedAt = _firstDate(meta, const [
      ('last-modified', MetaKeyAttribute.name),
      ('modified', MetaKeyAttribute.name),
      ('dateModified', MetaKeyAttribute.name),
      ('dateModified', MetaKeyAttribute.itemProp),
      ('article:modified_time', MetaKeyAttribute.property),
    ]);
    if (modifiedAt != null) {
      context.addModifiedAt(
        modifiedAt,
        source: CandidateSource.standardMeta,
        score: _scoreModifiedAt,
        evidence: 'modified date meta',
      );
    }
  }

  // Checks each key attribute in priority order (name, property, http-equiv,
  // itemprop) and returns the first non-empty value for the first attribute
  // that has one.
  static String? _metaContent(
    MetaTagIndex meta, {
    String? name,
    String? property,
    String? httpEquiv,
    String? itemProp,
  }) {
    final lookups = <(String?, MetaKeyAttribute)>[
      (name, MetaKeyAttribute.name),
      (property, MetaKeyAttribute.property),
      (httpEquiv, MetaKeyAttribute.httpEquiv),
      (itemProp, MetaKeyAttribute.itemProp),
    ];
    for (final (key, attribute) in lookups) {
      if (key == null) continue;
      final value = meta.firstText([key], attributes: {attribute});
      if (value != null) return value;
    }
    return null;
  }

  static String? _cleanText(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }

  // Walks [lookups] in priority order and, within each, tags in document
  // order, returning the first value that parses as a date. An unparseable
  // placeholder such as `Monday` must not hide a later valid timestamp.
  static DateTime? _firstDate(
    MetaTagIndex meta,
    List<(String, MetaKeyAttribute)> lookups,
  ) {
    for (final (key, attribute) in lookups) {
      for (final raw in meta.texts([key], attributes: {attribute})) {
        final parsed = DateUtils.parseString(raw);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }
}

const String _htmlNamespace = 'http://www.w3.org/1999/xhtml';

const double _scoreTitle = 0.65;
const double _scoreHeadingTitle = 0.35;
const double _scoreDescription = 0.60;
const double _scoreSiteName = 0.40;
const double _scoreLocale = 0.45;
const double _scoreLocaleAlt = 0.35;
const double _scoreKeyword = 0.40;
const double _scoreAuthor = 0.45;
const double _scorePublishedAt = 0.45;
const double _scoreModifiedAt = 0.40;
