# MetaLink

[![pub package](https://img.shields.io/pub/v/metalink.svg)](https://pub.dev/packages/metalink)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

**MetaLink** is a high-performance, robust, and modular metadata extraction library for Dart. It goes beyond simple regex scraping by using a candidate-based pipeline to extract the highest quality metadata from OpenGraph, Twitter Cards, JSON-LD, standard HTML tags, oEmbed, and Web App Manifests.

## 🚀 Features

*   **Candidate-Based Pipeline:** Scores multiple sources (OG, JSON-LD, HTML) to pick the best title, image, or description.
*   **Comprehensive Extraction:**
    *   OpenGraph & Twitter Cards
    *   JSON-LD (Structured Data)
    *   HTML Meta Tags (`<title>`, `<meta name="description">`)
    *   Link Rel (`canonical`, `icon`, `manifest`)
    *   **oEmbed** discovery and enrichment.
    *   **Web App Manifest** parsing.
*   **Robust Networking:**
    *   Smart charset detection (BOM, Content-Type, `<meta charset>`).
    *   Safe truncation (limits max body size).
    *   Efficient redirect handling (tries `HEAD` before `GET`).
    *   Proxy support.
*   **High Performance:**
    *   `extractBatch` for concurrent processing.
    *   Built-in **Memory** and **Hive** (disk) caching.
*   **Detailed Diagnostics:** exact provenance of where every field came from (e.g., "Title from og:title (score: 0.95)").

## 📦 Installation

Add MetaLink to your `pubspec.yaml`:

```yaml
dependencies:
  metalink: ^2.0.0
```

## 🔍 Quick Start

Use the static `MetaLink` helper for simple, one-off requests:

```dart
import 'package:metalink/metalink.dart';

void main() async {
  // Simple extraction
  final result = await MetaLink.extract('https://flutter.dev');

  if (result.isSuccess) {
    print('Title: ${result.metadata.title}');
    print('Description: ${result.metadata.description}');
    print('Image: ${result.metadata.images.firstOrNull?.url}');
  }
}
```

## 📚 Advanced Usage

For production apps, create a `MetaLinkClient` to share configuration and caching.

### 1. Custom Configuration

```dart
final client = MetaLinkClient(
  options: MetaLinkClientOptions(
    fetch: FetchOptions(
      timeout: Duration(seconds: 5),
      userAgent: 'Bot/1.0',
      maxBytes: 1024 * 1024, // 1MB limit
    ),
    extract: ExtractOptions(
      extractJsonLd: true,
      enableOEmbed: true, // Fetch oEmbed data if available
      maxImages: 5,
    ),
    cache: CacheOptions(
      enabled: true,
      ttl: Duration(hours: 1),
    ),
  ),
);

try {
  final result = await client.extract('https://github.com');
  print(result.metadata.title);
} finally {
  client.close();
}
```

### 2. Batch Processing

Process multiple URLs concurrently:

```dart
final urls = [
  'https://dart.dev',
  'https://pub.dev',
  'https://flutter.dev',
];

// Extract 3 URLs in parallel
final results = await MetaLink.extractBatch(urls, concurrency: 3);

for (final res in results) {
  print('${res.metadata.originalUrl} -> ${res.metadata.title}');
}
```

### 3. Caching (Hive)

Persist metadata to disk using `HiveCacheStore`.

```dart
// Initialize Hive (required once per app)
import 'package:hive_ce/hive_ce.dart';

final cacheDir = Directory.systemTemp; // Use valid app dir
Hive.init(cacheDir.path);

final store = await HiveCacheStore.open(boxName: 'metadata_cache');

final client = MetaLinkClient(cacheStore: store);
// ... use client ...
```

## 🧩 The Extraction Pipeline

MetaLink V2 uses a **pipeline** approach. Instead of taking the first tag it finds, it gathers "candidates" from various extractors:

1.  **OpenGraphExtractor**: `og:title`, `og:image`...
2.  **TwitterCardExtractor**: `twitter:title`, `twitter:image`...
3.  **JsonLdExtractor**: Parses embedded JSON-LD graphs.
4.  **LinkRelExtractor**: `rel="canonical"`, `rel="icon"`.
5.  **StandardMetaExtractor**: `<title>`, `<meta name="description">`.
6.  **Enrichers**: Fetches `oEmbed` and `manifest.json` if discovered.

Each candidate is scored. For example, an `og:title` typically outscores a standard `<title>` tag. You can inspect this decision-making process via `result.diagnostics.fieldProvenance`.

## 📄 License

MIT