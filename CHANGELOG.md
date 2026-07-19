# CHANGELOG

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
