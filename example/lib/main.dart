import 'package:metalink/metalink.dart';

void main() async {
  print('🚀 MetaLink V2 Example\n');

  // 1. Simple Extraction
  print('--- Simple Extraction ---');
  final simpleResult = await MetaLink.extract('https://flutter.dev');
  _printMetadata(simpleResult);

  // 2. Advanced Client with Options
  print('\n--- Advanced Client ---');
  final client = MetaLinkClient(
    options: const MetaLinkClientOptions(
      fetch: FetchOptions(
        timeout: Duration(seconds: 10),
        userAgent: 'MetaLink-Example/2.0',
      ),
      extract: ExtractOptions(
        extractJsonLd: true,
        enableOEmbed: true, // Fetch oEmbed json/xml
        maxImages: 3,
      ),
    ),
  );

  try {
    // Extract a URL that likely has rich media (like YouTube)
    // Note: This relies on the network; replace with any valid URL.
    final url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
    final result = await client.extract(url);

    _printMetadata(result);

    // Inspect Diagnostics (Provenance)
    print('\n[Diagnostics]');
    print('Cache Hit: ${result.diagnostics.cacheHit}');
    print('Total Time: ${result.diagnostics.totalTime.inMilliseconds}ms');

    // Show where the title came from
    final titleProv = result.diagnostics.fieldProvenance[MetaField.title];
    if (titleProv != null) {
      print('Title Source: ${titleProv.source} (Score: ${titleProv.score})');
    }
  } finally {
    client.close();
  }

  // 3. Batch Processing
  print('\n--- Batch Processing ---');
  final urls = ['https://dart.dev', 'https://pub.dev'];

  final batchResults = await MetaLink.extractBatch(urls, concurrency: 2);
  for (final res in batchResults) {
    print('${res.metadata.originalUrl} => ${res.metadata.title}');
  }
}

void _printMetadata(ExtractionResult<LinkMetadata> result) {
  if (!result.isSuccess) {
    print('Error: ${result.errors.first.message}');
    return;
  }

  final m = result.metadata;
  print('Title:       ${m.title}');
  print('Description: ${m.description}');
  print('Site Name:   ${m.siteName}');
  print('Kind:        ${m.kind}');

  if (m.images.isNotEmpty) {
    print('Image:       ${m.images.first.url} (${m.images.length} total)');
  }

  if (m.oembed != null) {
    print('oEmbed:      Found ${m.oembed!.type} titled "${m.oembed!.title}"');
  }
}
