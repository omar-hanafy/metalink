import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/util/html_utils.dart';

/// An extractor stage that reads Twitter (X) card meta tags.
///
/// Emits `twitter:title`, `twitter:description`, `twitter:creator` (as the
/// author), `twitter:image` with `twitter:image:src` as its fallback, and
/// `twitter:player` as a video candidate. Scores rank below Open Graph so
/// Twitter tags act as a fallback when both are present.
///
/// Keys match ASCII case-insensitively. The `name` attribute is preferred,
/// with `property` used only when no `name` tag has a usable value. Text fields
/// use the first non-empty value; URL fields use the first value that resolves
/// to an absolute HTTP(S) URL, so an unusable `twitter:image` such as a
/// `data:` URL falls back to `twitter:image:src`. Does nothing when
/// `ExtractOptions.extractTwitterCard` is `false`.
class TwitterCardExtractor implements HtmlMetadataExtractorStage {
  /// Creates the stateless Twitter card extractor stage.
  const TwitterCardExtractor();

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractTwitterCard) return;

    final meta = context.metaTags;

    // Twitter tags are usually in "name", but some pages use "property", so
    // values are ordered by key, then by attribute, then by document order.
    List<String> valuesFor(List<String> keys) => <String>[
      for (final key in keys)
        for (final attribute in _attributePriority)
          for (final tag in meta.find([key], attributes: {attribute}))
            ?tag.content,
    ];

    String? metaByName(String name) => valuesFor([name]).firstOrNull;

    Uri? urlFor(List<String> keys) => context.urlResolver
        .resolveAll(context.baseUrl, valuesFor(keys))
        .firstOrNull;

    final title = metaByName('twitter:title');
    if (title != null) {
      context.addTitle(
        title,
        source: CandidateSource.twitterCard,
        score: _scoreTitle,
        evidence: 'twitter:title',
      );
    }

    final description = metaByName('twitter:description');
    if (description != null) {
      context.addDescription(
        description,
        source: CandidateSource.twitterCard,
        score: _scoreDescription,
        evidence: 'twitter:description',
      );
    }

    final creator = metaByName('twitter:creator');
    if (creator != null) {
      context.addAuthor(
        creator,
        source: CandidateSource.twitterCard,
        score: _scoreAuthor,
        evidence: 'twitter:creator',
      );
    }

    final imageUri = urlFor(const ['twitter:image', 'twitter:image:src']);
    if (imageUri != null) {
      context.addImageUri(
        imageUri,
        source: CandidateSource.twitterCard,
        score: _scoreImage,
        evidence: 'twitter:image',
      );
    }

    // Player cards may expose an embeddable URL used for rich previews.
    final playerUri = urlFor(const ['twitter:player']);
    if (playerUri != null) {
      context.addVideoUri(
        playerUri,
        source: CandidateSource.twitterCard,
        score: _scorePlayer,
        evidence: 'twitter:player',
      );
    }
  }
}

const List<MetaKeyAttribute> _attributePriority = <MetaKeyAttribute>[
  MetaKeyAttribute.name,
  MetaKeyAttribute.property,
];

const double _scoreTitle = 0.85;
const double _scoreDescription = 0.80;
const double _scoreAuthor = 0.45;
const double _scoreImage = 0.75;
const double _scorePlayer = 0.55;
