# CHANGELOG

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
