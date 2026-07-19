# MetaLink

[![pub package](https://img.shields.io/pub/v/metalink.svg)](https://pub.dev/packages/metalink)
[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](LICENSE)

MetaLink is a metadata extraction package for Dart. It builds link previews
from Open Graph, Twitter Cards, JSON-LD, standard HTML metadata, oEmbed, and Web
App Manifests while retaining diagnostics about how each field was selected.

## Features

- Candidate-based ranking across multiple metadata sources.
- Open Graph, Twitter Card, JSON-LD, standard meta tag, and link relation
  extraction.
- Optional oEmbed and Web App Manifest enrichment.
- Pure parsing APIs for HTML strings and previously fetched response bytes.
- Redirect handling, total deadlines, byte limits, proxy support, and web
  charset detection.
- An opt-in request policy for untrusted URLs and redirect boundaries.
- Concurrent batch extraction.
- In-memory and Hive-backed caches.
- Structured errors, warnings, diagnostics, raw metadata, and field
  provenance.

## Requirements

MetaLink supports Dart `>=3.11.0 <4.0.0`.

## Installation

Add the latest compatible release:

```shell
dart pub add metalink
```

Or declare it directly:

```yaml
dependencies:
  metalink: ^2.1.0
```

## Quick start

Use the static `MetaLink` helper for one-off requests:

```dart
import 'package:metalink/metalink.dart';

Future<void> main() async {
  final result = await MetaLink.extract('https://flutter.dev');

  if (!result.isSuccess) {
    print('Extraction failed: ${result.errors.first.message}');
    return;
  }

  final metadata = result.metadata;
  print('Title: ${metadata.title}');
  print('Description: ${metadata.description}');

  if (metadata.images.isNotEmpty) {
    print('Image: ${metadata.images.first.url}');
  }
}
```

Extraction failures are returned in `ExtractionResult.errors`; routine network
or parsing failures do not require a `try`/`catch` around each URL.

## Flutter showcase

MetaLink is deliberately UI-free, but the repository includes a complete
native Flutter showcase at
[`examples/flutter_link_preview`](https://github.com/omar-hanafy/metalink/tree/main/examples/flutter_link_preview).

The sample uses `MetaLinkClient` directly and builds a responsive Material 3
preview from `LinkMetadata`. It demonstrates loading, partial, failure, and
cached states; ranked images and icons; request cancellation; diagnostics; and
deterministic disposal. The widget remains example code so applications can own
their visual language instead of inheriting a package-level UI contract.

The older `metalink_flutter` widget package is discontinued. Existing releases
remain available for migration, while new applications should depend only on
`metalink` and adapt the showcase to their own state and design systems.

### Result status

`ExtractionStatus` distinguishes complete metadata, usable partial metadata,
and failure while preserving the v2-compatible `isSuccess` property:

```dart
switch (result.status) {
  case ExtractionStatus.success:
    print(result.metadata.title);
  case ExtractionStatus.partial:
    print('${result.metadata.title} (${result.warnings.length} warnings)');
  case ExtractionStatus.failure:
    print('${result.primaryError?.message}; retryable: ${result.retryable}');
    print('Reason: ${result.primaryError?.reason}');
}
```

Use `metadataOrNull` when failed results should not expose placeholder metadata.

## Parse content without fetching

`MetaLinkParser` is deterministic and performs no network requests. Use it when
another crawler, authenticated client, browser, or fixture already owns the
content:

```dart
final parser = MetaLinkParser();
final result = await parser.parseHtml(
  html,
  documentUrl: Uri.parse('https://example.com/articles/1'),
);
```

Use `parseResponse` when you have raw response bytes, requested and final URLs,
and headers. It applies BOM, HTTP header, HTML meta, and UTF-8 fallback charset
precedence, including Windows-1252 decoding. Pure parsing never performs oEmbed
or manifest enrichment; requesting those options produces a partial result and
a warning.

## Reusable client

Create a `MetaLinkClient` when you want connection reuse, shared configuration,
or caching across requests:

```dart
final client = MetaLinkClient(
  options: MetaLinkClientOptions(
    fetch: FetchOptions(
      timeout: const Duration(seconds: 5),
      totalTimeout: const Duration(seconds: 20),
      userAgent: 'MyPreviewBot/1.0',
      maxBytes: 1024 * 1024,
      requestPolicy: RequestPolicy.secure(),
    ),
    extract: const ExtractOptions(
      extractJsonLd: true,
      enableOEmbed: true,
      enableManifest: true,
      maxImages: 5,
    ),
    cache: const CacheOptions(
      enabled: true,
      ttl: Duration(hours: 1),
    ),
  ),
);

try {
  final result = await client.extract('https://github.com');
  print(result.metadata.title);
} finally {
  await client.dispose();
}
```

`dispose()` deterministically closes resources owned by the client and is safe
to call more than once. Resources injected into the constructor remain owned by
the caller.

MetaLink applies one stable default user agent to document, redirect, oEmbed,
manifest, and optimization requests. `FetchOptions.userAgent` replaces that
default, while an explicit case-insensitive `User-Agent` entry in
`FetchOptions.headers` takes final precedence.

An injected `http.Client` has unknown redirect capabilities by default. If it
really returns redirect responses without following them, describe that with
`httpClientCapabilities`; otherwise a policy requiring inspectable redirects
will fail closed. Supplying a custom `Fetcher` gives full control over the same
capability contract.

The default request policy preserves MetaLink 2.x target compatibility while
removing sensitive headers on cross-origin redirects. `RequestPolicy.secure()`
additionally rejects common loopback, private-literal, link-local, multicast,
and metadata-service targets and requires inspectable redirects. Server
transports should still validate resolved DNS addresses and apply DNS-pinning
controls appropriate to their environment.

Browser transports cannot expose redirect responses. In compatibility mode,
the browser can follow enabled redirects and MetaLink preserves the final URL,
but the intermediate hop list, `maxRedirects`, per-hop policy validation, and
MetaLink's cross-origin header filtering are unavailable. The secure policy
therefore rejects the default browser transport before sending a request. For
untrusted browser-side URLs, use a policy-aware server proxy or a custom
`Fetcher` that can expose and validate every hop.

## Batch extraction

```dart
final results = await MetaLink.extractBatch(
  [
    'https://dart.dev',
    'https://pub.dev',
    'https://flutter.dev',
  ],
  concurrency: 3,
);

for (final result in results) {
  print('${result.metadata.originalUrl} -> ${result.metadata.title}');
}
```

The result list preserves input order. A failure for one URL does not prevent
the remaining URLs from being processed.

## Persistent Hive cache

`HiveCacheStore.open` can initialize and own its Hive box. Supply an
application-owned persistent path in production:

```dart
import 'dart:io';

import 'package:metalink/metalink.dart';

final store = await HiveCacheStore.open(
  boxName: 'metadata_cache',
  path: Directory.systemTemp.path, // Use an app cache directory in production.
);
final client = MetaLinkClient(cacheStore: store);

try {
  final result = await client.extract('https://dart.dev');
  print(result.metadata.title);
} finally {
  await client.dispose();
  await store.close();
}
```

The store is closed separately because an injected cache remains caller-owned.
For short-lived or test-only caching, use `MemoryCacheStore`.

Custom cache implementations can use `CacheEntry.withLifetime` with
`CacheLifetime.storeDefault()`, `CacheLifetime.neverExpires()`, or
`CacheLifetime.expiresAfter(...)` instead of relying on a magic nonpositive
TTL value.

The compact `CachePayloadKind.linkMetadata` remains the default for v2
compatibility. Set `CacheOptions.payloadKind` to
`CachePayloadKind.extractionResult` when cache hits must retain status,
completeness, warnings, raw metadata, and provenance. For compact cache hits,
`result.diagnostics.provenanceAvailable` is `false`.

Results with failed oEmbed or manifest enrichment are not cached, so a
temporary provider failure or a short request deadline cannot poison a later
extraction that has enough time to complete.

## Raw metadata and diagnostics

Raw DOM metadata is opt-in and belongs to `ExtractionResult.raw`:

```dart
final client = MetaLinkClient(
  options: const MetaLinkClientOptions(
    extract: ExtractOptions(includeRawMetadata: true),
  ),
);

try {
  final result = await client.extract('https://example.com');
  print(result.raw);
  print(result.diagnostics.fieldProvenance);
  print(result.diagnostics.itemProvenance);
  print(result.diagnostics.candidateDecisions);
  print(result.warnings);
} finally {
  await client.dispose();
}
```

## Extraction pipeline

MetaLink gathers candidates and ranks them instead of accepting the first tag
it sees. The local pipeline combines:

1. Open Graph metadata
2. Twitter Card metadata
3. Standard HTML metadata
4. Link relations such as canonical URLs and icons
5. JSON-LD structured data
6. Optional oEmbed and manifest enrichment

Field and item provenance record selected sources and scores. Candidate
decisions explain accepted and rejected alternatives. Pure parsers can also
receive a custom `RankingPolicy`; `DefaultRankingPolicy` preserves score-first,
stage-order, and document-order precedence.

## License

MetaLink is available under the [BSD 3-Clause License](LICENSE).
