# CHANGELOG

## 2.2.0

- Requires Dart 3.13.5 or later (Flutter 3.47.7 or later) and raises the
  dependency floors to `hive_ce` 2.20.2, `html` 0.15.7, `xml` 7.1.0, and
  `convert_object` 1.1.1. The `html` release avoids quadratic parsing of
  deeply nested formatting elements in untrusted pages.
- `HiveCacheStore.open` no longer calls `Hive.init`, so it never moves boxes
  that an application opens itself. Applications that relied on that side
  effect must initialize Hive themselves; on native platforms, pass `path`
  unless Hive is already initialized. Stores opened on the same box now share
  it safely, a box the application opened first is never closed by MetaLink,
  and an `open` that overlaps the closing of another store on the same box no
  longer returns a store whose box is closed.
- Results cached by earlier versions are no longer served, so cached previews
  pick up this release's extraction fixes.
- Model `fromJson` methods no longer turn URLs that contain `@`, such as
  `https://medium.com/@john.doe` or `logo@2x.png` image URLs, into `mailto:`
  links, which corrupted results restored from a cache.
- Timestamps are parsed the same way on every host. A value without a
  time-zone designator is read as UTC instead of the host's local time,
  impossible dates such as February 30 or hour 25 are rejected instead of
  rolling over, an unparseable date tag no longer hides a later valid one, and
  an out-of-range epoch value no longer discards an extractor's other fields.
- JSON-LD page fields (title, description, canonical URL, images, kind, and
  locale) now come only from typed nodes that describe the page: a node whose
  `url`, `@id`, or `mainEntityOfPage` matches the page, or a page-like node
  such as an `Article`, `WebPage`, or `Product`, or one of their schema.org
  subtypes, that names no other document. Untyped nodes, breadcrumbs,
  navigation, images, comments, offers, ratings, nested reviews, list items,
  and the stories of a listing page never describe it. Except for untyped
  nodes, they also no longer supply its author, dates, site name, or keywords,
  and list items and nested reviews no longer add videos. `Organization`,
  `WebSite`, and `BreadcrumbList` names no longer replace `<title>`, and a
  generic `WebPage` no longer overrides `og:type` or a more specific type.
- JSON-LD URLs resolve against `<base href>` and match the page when they
  differ only by a trailing slash or the order of query parameters. On
  query-routed sites (`?p=42`, `?t=100`, `?color=red`), a URL with a different
  query is another document. A `url` or `@id` with a `#fragment` names part of
  a page, not the page. A URL that differs from the page URL only by a leading
  `www.` or by query parameters the page URL adds, such as tracking
  parameters, or that matches the page's canonical link or `og:url`, as on AMP
  pages, does not count as another document.
- JSON-LD schema.org subtypes are classified like their parent type, so
  `OpinionNewsArticle`, `TechArticle`, `SocialMediaPosting`, and
  `LiveBlogPosting` pages get the article kind and `MediaGallery` and
  `VideoGallery` pages the gallery kind.
- JSON-LD graphs that reference a node before defining it, as Yoast and
  RankMath do, keep the full definitions. Repeated `@id` definitions are
  merged, with a typed definition winning over an untyped one, image
  references resolve to their image URLs instead of page URLs, and `author`
  and `publisher` references, including arrays, resolve to the referenced
  names.
- JSON-LD values nested more than 64 levels deep are stored as `null`, so
  `structuredData` always serializes and such pages can be cached. JSON-LD no
  longer reports a partial parse for a document that fits its node, visit, or
  depth limit exactly, and an oversized JSON-LD script no longer suppresses
  later scripts.
- oEmbed widths and heights that are not positive or exceed `2^53 - 1` are
  ignored instead of discarding the whole payload, and relative oEmbed
  thumbnail, author, and provider URLs resolve against the oEmbed response
  instead of the page. Non-string oEmbed and manifest values, such as
  `"thumbnail_url": true`, are ignored instead of becoming text or URLs, and a
  numeric oEmbed `version` is formatted like `"1.0"` on every platform.
- Meta `name`, `property`, and `http-equiv` values match ASCII
  case-insensitively, and an empty or unusable meta tag no longer hides a later
  valid duplicate, including the `twitter:image:src` fallback.
- An unusable `og:image` no longer passes its width, height, type, or alt to
  the previous image. `og:video` and `og:audio` secure URLs, types, and
  dimensions now attach to their root item, and non-positive dimensions are
  ignored.
- Metadata URLs are cleaned as browsers clean them: tabs and newlines inside a
  URL are removed and surrounding spaces and control characters are trimmed. A
  `<base href>` without a host is ignored, and a `<title>` inside inline SVG no
  longer becomes the page title.
- Repeated icon URLs keep their best score and richest attributes, and blank
  icon `sizes` and `type` are reported as `null`.
- Mistyped schemes such as `https:/example.com`, `https//example.com`, or
  `https ://example.com`, and a bare `http` or `https`, are reported as invalid
  URLs instead of requesting the host `https` or `http`.
- Charset decoding follows the WHATWG Encoding Standard. Labels resolve through
  its alias table, and a `<meta>` charset with an unrecognized label no longer
  stops the scan for a later valid one. One invalid byte or a character cut
  off at `maxBytes` no longer forces a whole-document UTF-8 fallback,
  `<meta charset="utf-16">` is read as UTF-8, and a `utf-16` header without a
  byte-order mark is little-endian. `WebDecodeResult.charset` names the
  encoding actually used, and EUC-KR is reported as unsupported instead of
  being decoded incorrectly.
- GBK, gb18030, Shift_JIS, and EUC-JP decode as browsers decode them: an
  invalid sequence becomes U+FFFD without swallowing the ASCII byte after it,
  so markup after a bad byte survives. GBK `0x80` decodes as `€`, gb18030
  four-byte sequences are supported, and Shift_JIS and EUC-JP decode the
  Windows-31J (NEC and IBM) extension characters. Single-byte encodings decode
  from the official WHATWG tables, which fixes windows-874, ISO-8859-3, and
  bytes `0x7F` and `0x80` to `0x9F`, and UTF-16 no longer drops the character
  after an unpaired surrogate.
- `RequestPolicy.secure()` rejects non-ASCII and percent-encoded host names,
  which Unicode canonicalization can map to loopback or metadata addresses.
  Pass internationalized hosts in punycode (`xn--`) form. It also rejects
  hosts-file aliases such as `localhost.localdomain`, `localhost4`,
  `localhost6`, and `ip6-localhost`, the `instance-data` metadata name, and
  local or metadata host names written with extra trailing dots, such as
  `localhost..`.
- Policies that require inspectable redirects, including
  `RequestPolicy.secure()`, now fail closed when a custom `Fetcher` follows a
  redirect itself and reports the redirected URL in `FetchResponse.url`,
  instead of accepting the redirected response. A fetcher that follows
  redirects but reports the requested URL cannot be detected, so it must
  return redirects unfollowed, as the `Fetcher` contract requires.
- URL userinfo (`user:password@`) is treated as a credential. It is never sent
  to oEmbed or manifest requests, is removed on cross-origin redirects when the
  policy strips sensitive headers, as the default policy does, and is left out
  of proxy URLs unless the policy forwards sensitive headers through the proxy.
- An invalid `proxyUrl` is reported with reason `policyRejected` and is no
  longer retryable.
- Fixed a 2.1.0 regression where a HEAD request that exceeded its per-attempt
  `timeout` ended the whole request instead of falling back to GET.
- Very large limits work. A `maxBytes` as large as the largest `int` reads the
  whole body instead of failing every request, a `totalTimeout` beyond the
  range of `DateTime` means no limit instead of throwing a `RangeError`, and on
  the web a total or per-attempt timeout longer than about 24.8 days no longer
  expires immediately.
- Concurrent `extract` calls that share one request each receive their own
  result, so editing any list or map in one result, including JSON-LD nodes,
  never affects another call. A joining call is checked by its own request
  policy and retries on its own only when a different policy object rejected
  the shared request or the shared request used its complete `totalTimeout`;
  a per-attempt timeout no longer makes every joining call retry at once.
  `RequestPolicy.secure()` without arguments now returns one shared instance,
  so callers that each pass it share a rejection instead of retrying.
- Long-lived cancellation signals no longer keep completed responses in
  memory.
- Cached full results no longer replay cache-read, cache-write, or
  cache-bypass warnings from the request that wrote them. A cached result
  that claims failure without an error, or has an out-of-range completeness,
  is treated as a cache miss in every build mode.
- A zero or negative `CacheOptions.ttl` consistently means the store's default
  lifetime. A request that passes `CacheOptions(enabled: true)` to a client
  created without a cache now caches in a `MemoryCacheStore` that the client
  owns.
- `extractBatch` no longer starts idle workers when `concurrency` exceeds the
  number of URLs.
- Model `fromJson` methods skip individual malformed entries instead of
  dropping whole lists, and `ExtractionDiagnostics.fromJson` keeps field
  provenance from loosely typed maps. In release builds, an `ExtractionResult`
  created with `ExtractionStatus.failure` but no errors now infers its status
  from its warnings instead of reporting success.
- Documented every public API member and corrected documentation that
  contradicted runtime behavior.
- The Flutter showcase in the repository targets Flutter 3.47.7, keeps its
  preview readable at large text sizes and in dark themes, and documents that
  image and favicon URLs are loaded outside MetaLink's request policy.

## 2.1.0

- Added `MetaLinkParser` pure parsing APIs for decoded HTML and previously
  fetched response bytes, with no implicit network activity.
- Unified document, redirect, oEmbed, manifest, and URL-optimization requests
  behind one request engine with complete-operation deadlines, cancellation,
  fail-closed proxy handling, typed failures, and consistent redirect limits.
- Added request-policy and transport-capability APIs. The opt-in secure preset
  blocks common unsafe and ambiguous literal targets, validates every
  inspectable hop, and strips sensitive headers at trust boundaries. DNS
  validation and pinning remain the responsibility of a policy-aware server
  transport.
- Added browser-compatible opaque redirects that preserve the final response
  URL while secure policies continue to reject transports with hidden hops.
- Added a field-specific `RankingPolicy`, deterministic tie-breaking, candidate
  decisions including structured data, and truthful contributor provenance for
  merged collection items.
- Expanded web charset decoding, including Windows-1252 and other common
  legacy encodings, strict HTML meta declaration sniffing, and explicit
  charset-source diagnostics.
- Added explicit extraction status, retryability, completeness, precise error
  reasons, defensive result invariants, and deterministic async `dispose()`.
  The synchronous `close()` compatibility method is now deprecated.
- Added in-flight request coalescing and made cache keys independent of attempt
  timeouts while preserving request-policy and content-affecting boundaries.
  Failed remote enrichments are not cached, and cache I/O now obeys the shared
  operation lifetime.
- Added explicit cache lifetimes, full-result cache payload restoration, compact
  payload provenance signaling, and defensive memory-cache snapshots.
- Hardened JSON-LD traversal with aggregate decode and derived-value budgets,
  stable document-order tie-breaking, and duplicate `@graph` prevention.
- Fixed structured Open Graph image grouping, redirected manifest URL
  and oEmbed endpoint resolution, enrichment byte ceilings, hostless metadata
  URLs, exact redirect-limit behavior, and consistent user-agent handling.
- Corrected the declared SDK floor to Dart 3.11, matching the already released
  dependency constraints, and refreshed package validation and release CI.
- Added a separate native Flutter showcase demonstrating application-owned link
  preview UI without adding Flutter dependencies to the MetaLink package.

## 2.0.1

- Updated runtime dependencies: `xml` to `^7.0.1`, `convert_object` to `^1.1.0`, `hive_ce` to `^2.19.3`, and `html` to `^0.15.6`.

## 2.0.0

**Complete Rewrite & Major Architecture Update**

*   **New Architecture:** Introduced a candidate-based extraction pipeline (Scoring system) for higher quality metadata selection.
*   **New Extractors:**
    *   **JSON-LD:** Full support for extracting structured data and deriving page metadata from it.
    *   **oEmbed:** Support for discovering and fetching oEmbed (JSON/XML) data.
    *   **Web App Manifest:** Support for fetching `.webmanifest` files.
*   **Robust Networking:**
    *   New `HtmlSnippetFetcher` with advanced charset detection (BOM, Headers, Meta tags).
    *   Smart redirect handling (`HEAD` then `GET`).
    *   Safe body truncation and proxy support.
*   **API Changes:**
    *   `MetaLink.extract` is now the primary static entry point.
    *   `MetaLinkClient` allows for shared configuration and instance management.
    *   New `ExtractionResult` class containing `metadata`, `diagnostics`, and `provenance`.
*   **Caching:** Added `HiveCacheStore` for persistent caching and `MemoryCacheStore`.

## 1.0.4

- CHORE: updated dart_helper_utils version boundaries to ">=4.1.2 <6.0.0"

## 1.0.3

- Allowed to pass optional proxyUrl to the `LinkMetadata` model.

## 1.0.2

- Enhancements to storage caches. 

## 1.0.1

- Enhanced README

## 1.0.0

- Initial Release
