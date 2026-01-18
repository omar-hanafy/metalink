import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/extract/pipeline.dart';

class StandardMetaExtractor implements HtmlMetadataExtractorStage {
  const StandardMetaExtractor();

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractStandardMeta) return;

    final doc = context.document;

    // Use <title> as a baseline title when richer metadata is missing.
    final titleEl = doc.querySelector('title');
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
    final desc = _metaContent(doc, name: 'description') ??
        _metaContent(doc, property: 'description');
    if (desc != null) {
      context.addDescription(
        desc,
        source: CandidateSource.standardMeta,
        score: _scoreDescription,
        evidence: 'meta description',
      );
    }

    // Use application-name tags as site name hints when present.
    final appName = _metaContent(doc, name: 'application-name') ??
        _metaContent(doc, name: 'apple-mobile-web-app-title');
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

    final contentLanguage = _metaContent(doc, httpEquiv: 'content-language') ??
        _metaContent(doc, name: 'language');
    if (contentLanguage != null) {
      context.addLocale(
        contentLanguage,
        source: CandidateSource.standardMeta,
        score: _scoreLocaleAlt,
        evidence: 'content-language',
      );
    }

    // Split keywords into individual tags for downstream filtering.
    final keywordsRaw = _metaContent(doc, name: 'keywords');
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
    final author = _metaContent(doc, name: 'author') ??
        _metaContent(doc, property: 'author');
    if (author != null) {
      context.addAuthor(
        author,
        source: CandidateSource.standardMeta,
        score: _scoreAuthor,
        evidence: 'meta author',
      );
    }

    // Parse common publish and modify tags to populate timeline fields.
    final publishedRaw = _metaContent(doc, name: 'pubdate') ??
        _metaContent(doc, name: 'publish-date') ??
        _metaContent(doc, name: 'publication_date') ??
        _metaContent(doc, name: 'date') ??
        _metaContent(doc, name: 'datePublished') ??
        _metaContent(doc, itemProp: 'datePublished') ??
        _metaContent(doc, property: 'article:published_time');
    final publishedAt = _parseDateTime(publishedRaw);
    if (publishedAt != null) {
      context.addPublishedAt(
        publishedAt,
        source: CandidateSource.standardMeta,
        score: _scorePublishedAt,
        evidence: 'published date meta',
      );
    }

    final modifiedRaw = _metaContent(doc, name: 'last-modified') ??
        _metaContent(doc, name: 'modified') ??
        _metaContent(doc, name: 'dateModified') ??
        _metaContent(doc, itemProp: 'dateModified') ??
        _metaContent(doc, property: 'article:modified_time');
    final modifiedAt = _parseDateTime(modifiedRaw);
    if (modifiedAt != null) {
      context.addModifiedAt(
        modifiedAt,
        source: CandidateSource.standardMeta,
        score: _scoreModifiedAt,
        evidence: 'modified date meta',
      );
    }
  }

  static String? _metaContent(
    dynamic doc, {
    String? name,
    String? property,
    String? httpEquiv,
    String? itemProp,
  }) {
    String? contentFromSelector(String selector) {
      final el = doc.querySelector(selector);
      if (el == null) return null;
      final v = el.attributes['content'] ?? el.attributes['value'];
      return _cleanText(v);
    }

    if (name != null) {
      final v = contentFromSelector('meta[name="$name"]');
      if (v != null) return v;
    }
    if (property != null) {
      final v = contentFromSelector('meta[property="$property"]');
      if (v != null) return v;
    }
    if (httpEquiv != null) {
      final v = contentFromSelector('meta[http-equiv="$httpEquiv"]');
      if (v != null) return v;
    }
    if (itemProp != null) {
      final v = contentFromSelector('meta[itemprop="$itemProp"]');
      if (v != null) return v;
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

  static DateTime? _parseDateTime(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;

    final digitsOnly = RegExp(r'^\d+$');
    if (digitsOnly.hasMatch(s)) {
      final n = int.tryParse(s);
      if (n == null) {
        return null;
      }
      if (s.length >= 13) {
        return DateTime.fromMillisecondsSinceEpoch(n, isUtc: true);
      }
      if (s.length == 10) {
        return DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true);
      }
    }

    final dt = DateTime.tryParse(s);
    if (dt != null) {
      return dt;
    }

    final withT =
        s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s;
    return DateTime.tryParse(withT);
  }
}

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
