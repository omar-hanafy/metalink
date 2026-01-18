import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/extract/pipeline.dart';

class TwitterCardExtractor implements HtmlMetadataExtractorStage {
  const TwitterCardExtractor();

  @override
  void extract(HtmlExtractContext context) {
    if (!context.extractOptions.extractTwitterCard) return;

    final doc = context.document;

    String? metaByName(String name) {
      // Twitter tags are usually in "name", but some pages use "property", so check both.
      final byName =
          doc.querySelector('meta[name="$name"]')?.attributes['content'] ??
              doc.querySelector('meta[name="$name"]')?.attributes['value'];
      if (byName != null && byName.trim().isNotEmpty) return byName.trim();

      final byProp =
          doc.querySelector('meta[property="$name"]')?.attributes['content'] ??
              doc.querySelector('meta[property="$name"]')?.attributes['value'];
      if (byProp != null && byProp.trim().isNotEmpty) return byProp.trim();

      return null;
    }

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

    final image =
        metaByName('twitter:image') ?? metaByName('twitter:image:src');
    final imageUri = context.urlResolver.resolve(context.baseUrl, image);
    if (imageUri != null) {
      context.addImageUri(
        imageUri,
        source: CandidateSource.twitterCard,
        score: _scoreImage,
        evidence: 'twitter:image',
      );
    }

    // Player cards may expose an embeddable URL used for rich previews.
    final player = metaByName('twitter:player');
    final playerUri = context.urlResolver.resolve(context.baseUrl, player);
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

const double _scoreTitle = 0.85;
const double _scoreDescription = 0.80;
const double _scoreAuthor = 0.45;
const double _scoreImage = 0.75;
const double _scorePlayer = 0.55;
