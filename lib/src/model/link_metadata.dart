import 'package:convert_object/convert_object.dart';
import 'package:metalink/src/model/icon.dart';
import 'package:metalink/src/model/json_uri.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/model/structured_data.dart';

List<T> _safeListFromJson<T>(
  dynamic value,
  T Function(Map<String, dynamic>) fromJson,
) {
  final list = Convert.tryToList<dynamic>(value);
  if (list == null) return [];
  return list
      .map((e) {
        final map = Convert.tryToMap<String, dynamic>(e);
        if (map == null) return null;
        try {
          return fromJson(map);
        } catch (_) {
          return null;
        }
      })
      .whereType<T>()
      .toList();
}

/// Converts each non-null element of [value] to a string, skipping `null`
/// entries so one malformed keyword cannot discard the whole list.
List<String> _safeStringListFromJson(Object? value) {
  final list = Convert.tryToList<dynamic>(value);
  if (list == null) return <String>[];
  return list.map(Convert.tryToString).whereType<String>().toList();
}

/// The semantic category of a linked page.
///
/// Extraction derives the kind from the Open Graph `og:type` value or the
/// JSON-LD `@type` of the page. See [LinkMetadata.kind].
enum LinkKind {
  /// The kind could not be determined or mapped.
  unknown,

  /// An article or post, such as `og:type` `article` or a JSON-LD `Article`,
  /// `NewsArticle`, or `BlogPosting`.
  article,

  /// A product or offer, such as `og:type` `product` or a JSON-LD `Product` or
  /// `Offer`.
  product,

  /// A video, such as an `og:type` starting with `video` or a JSON-LD
  /// `VideoObject` or `Movie`.
  video,

  /// Audio content, such as an `og:type` starting with `music` or a JSON-LD
  /// `AudioObject`, `MusicRecording`, or `PodcastEpisode`.
  audio,

  /// A person or account profile, such as `og:type` `profile` or a JSON-LD
  /// `ProfilePage`.
  profile,

  /// A site's home page, such as `og:type` `website` on a root URL or a
  /// JSON-LD `WebSite`.
  homepage,

  /// A search page, declared with a JSON-LD `SearchAction`.
  search,

  /// A collection or gallery page, such as a JSON-LD `CollectionPage` or
  /// `ImageGallery`.
  gallery,

  /// An event page, declared with a JSON-LD `Event`.
  event,

  /// A recognized but generic page, such as `og:type` `website` on a non-root
  /// URL or a JSON-LD `WebPage`.
  other,
}

/// The normalized output of a metadata extraction process.
///
/// [LinkMetadata] aggregates and normalizes data from multiple sources (Open Graph, Twitter Cards,
/// JSON-LD, standard HTML tags).
///
/// ### Nullability
/// * Fields are `nullable` because no specific metadata field is guaranteed to exist on a webpage.
/// * `null` indicates the data was missing, empty, or invalid.
/// * Lists (like [images], [keywords]) are never null; they default to empty lists.
class LinkMetadata {
  /// Creates a [LinkMetadata].
  ///
  /// Only [originalUrl] and [resolvedUrl] are required. [kind] defaults to
  /// [LinkKind.unknown], and every list defaults to empty.
  const LinkMetadata({
    required this.originalUrl,
    required this.resolvedUrl,
    this.canonicalUrl,
    this.title,
    this.description,
    this.siteName,
    this.locale,
    this.kind = LinkKind.unknown,
    this.images = const [],
    this.icons = const [],
    this.videos = const [],
    this.audios = const [],
    this.publishedAt,
    this.modifiedAt,
    this.author,
    this.keywords = const [],
    this.oembed,
    this.manifest,
    this.structuredData,
  });

  /// The URL the caller asked to extract, as parsed from the input string.
  ///
  /// This is `about:blank`, as is [resolvedUrl], on failure results when the
  /// input could not be parsed as a URL, when the client was already closed,
  /// and when a batch item was rejected or failed unexpectedly.
  final Uri originalUrl;

  /// The final URL after following all HTTP redirects.
  ///
  /// If no redirects occurred, this is equal to [originalUrl] (normalized).
  final Uri resolvedUrl;

  /// The canonical URL defined by the page, if present.
  ///
  /// Sources: `<link rel="canonical">`, `og:url`.
  final Uri? canonicalUrl;

  /// The title of the content.
  ///
  /// Sources: `og:title`, `twitter:title`, `<title>`, `<h1>`.
  final String? title;

  /// A brief description or summary of the content.
  ///
  /// Sources: `og:description`, `twitter:description`, `<meta name="description">`.
  final String? description;

  /// The name of the site or application hosting the content.
  ///
  /// Sources: `og:site_name`, `application-name`.
  final String? siteName;

  /// The locale (language/region) of the content (e.g., `en_US`).
  ///
  /// Sources: `og:locale`, `<html lang="...">`.
  final String? locale;

  /// The semantic kind of the content (e.g., article, video, product).
  ///
  /// Derived from `og:type` or JSON-LD `@type`. Defaults to [LinkKind.unknown] if
  /// the type could not be determined or mapped.
  final LinkKind kind;

  /// A list of image candidates found on the page.
  ///
  /// Ordered by relevance/score. Includes `og:image`, `twitter:image`, JSON-LD images,
  /// and oEmbed thumbnails.
  final List<ImageCandidate> images;

  /// A list of icon/favicon candidates.
  ///
  /// Includes standard favicons, Apple touch icons, and manifest icons.
  final List<IconCandidate> icons;

  /// A list of video candidates.
  ///
  /// Sources: `og:video`, `twitter:player`, JSON-LD.
  final List<VideoCandidate> videos;

  /// A list of audio candidates.
  ///
  /// Sources: `og:audio`, JSON-LD.
  final List<AudioCandidate> audios;

  /// The date the content was first published.
  ///
  /// Sources: `article:published_time`, `og:published_time`, JSON-LD `datePublished`.
  final DateTime? publishedAt;

  /// The date the content was last modified.
  ///
  /// Sources: `article:modified_time`, JSON-LD `dateModified`.
  final DateTime? modifiedAt;

  /// The name of the author or creator.
  ///
  /// Sources: `author` meta tag, `twitter:creator`, JSON-LD `author`.
  final String? author;

  /// A list of keywords or tags associated with the content.
  ///
  /// Sources: `<meta name="keywords">`, `article:tag`.
  final List<String> keywords;

  /// The oEmbed data, if oEmbed enrichment was enabled and successful.
  final OEmbedData? oembed;

  /// The Web App Manifest data, if manifest enrichment was enabled and successful.
  final WebAppManifestData? manifest;

  /// The raw structured data graph (JSON-LD), if available.
  final StructuredDataGraph? structuredData;

  /// A JSON-compatible map of this metadata.
  ///
  /// URLs are written as strings, dates as ISO 8601 strings, [kind] as its
  /// enum name, and nested models with their own `toJson` methods. Absent
  /// values are written as `null`. The client stores this map in cache entries,
  /// and [LinkMetadata.fromJson] reads it back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'originalUrl': originalUrl.toString(),
      'resolvedUrl': resolvedUrl.toString(),
      'canonicalUrl': canonicalUrl?.toString(),
      'title': title,
      'description': description,
      'siteName': siteName,
      'locale': locale,
      'kind': kind.name,
      'images': images.map((e) => e.toJson()).toList(growable: false),
      'icons': icons.map((e) => e.toJson()).toList(growable: false),
      'videos': videos.map((e) => e.toJson()).toList(growable: false),
      'audios': audios.map((e) => e.toJson()).toList(growable: false),
      'publishedAt': publishedAt?.toIso8601String(),
      'modifiedAt': modifiedAt?.toIso8601String(),
      'author': author,
      'keywords': keywords,
      'oembed': oembed?.toJson(),
      'manifest': manifest?.toJson(),
      'structuredData': structuredData?.toJson(),
    };
  }

  /// Creates a [LinkMetadata] from a map produced by [toJson].
  ///
  /// Throws a `ConversionException` from `package:convert_object` when
  /// `originalUrl` or `resolvedUrl` is missing or is not a valid URI. It also
  /// throws when a present `oembed` or `manifest` map lacks a valid `endpoint`
  /// or `manifestUrl`.
  ///
  /// Other values are lenient. Missing or malformed optional values become
  /// `null`, and an unknown `kind` falls back to [LinkKind.unknown]. In
  /// `images`, `icons`, `videos`, and `audios`, entries that are not maps or
  /// that fail to decode are skipped. In `keywords`, `null` entries are
  /// skipped and other values are converted with `toString()`. A
  /// `structuredData` value that is not a map becomes `null`.
  factory LinkMetadata.fromJson(Map<String, dynamic> json) {
    return LinkMetadata(
      originalUrl: readJsonUri(json, 'originalUrl'),
      resolvedUrl: readJsonUri(json, 'resolvedUrl'),
      canonicalUrl: tryReadJsonUri(json, 'canonicalUrl'),
      title: json.tryGetString('title'),
      description: json.tryGetString('description'),
      siteName: json.tryGetString('siteName'),
      locale: json.tryGetString('locale'),
      kind: json.getEnum(
        'kind',
        parser: EnumParsers.byName(LinkKind.values),
        defaultValue: LinkKind.unknown,
      ),
      images: _safeListFromJson(json['images'], ImageCandidate.fromJson),
      icons: _safeListFromJson(json['icons'], IconCandidate.fromJson),
      videos: _safeListFromJson(json['videos'], VideoCandidate.fromJson),
      audios: _safeListFromJson(json['audios'], AudioCandidate.fromJson),
      publishedAt: json.tryGetDateTime('publishedAt'),
      modifiedAt: json.tryGetDateTime('modifiedAt'),
      author: json.tryGetString('author'),
      keywords: _safeStringListFromJson(json['keywords']),
      oembed: json.tryParse('oembed', OEmbedData.fromJson),
      manifest: json.tryParse('manifest', WebAppManifestData.fromJson),
      structuredData: json.tryParse(
        'structuredData',
        StructuredDataGraph.fromJson,
      ),
    );
  }

  /// Whether no metadata beyond the two request URLs was extracted.
  ///
  /// [originalUrl] and [resolvedUrl] are ignored. Every other field must be
  /// `null`, empty, or [LinkKind.unknown]. Failed extractions return metadata
  /// for which this is `true`.
  bool get isEmpty {
    return canonicalUrl == null &&
        title == null &&
        description == null &&
        siteName == null &&
        locale == null &&
        kind == LinkKind.unknown &&
        images.isEmpty &&
        icons.isEmpty &&
        videos.isEmpty &&
        audios.isEmpty &&
        publishedAt == null &&
        modifiedAt == null &&
        author == null &&
        keywords.isEmpty &&
        oembed == null &&
        manifest == null &&
        structuredData == null;
  }
}
