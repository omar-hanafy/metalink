import 'package:metalink/src/options.dart';
import 'package:metalink/src/cache/cache_store.dart';
import 'package:test/test.dart';

void main() {
  test('FetchOptions copyWith overrides fields', () {
    const base = FetchOptions();
    final updated = base.copyWith(
      timeout: const Duration(seconds: 1),
      userAgent: 'agent',
      followRedirects: false,
      maxRedirects: 1,
      maxBytes: 10,
      stopAfterHead: false,
      proxyUrl: 'https://proxy',
      headers: {'x': 'y'},
    );
    expect(updated.timeout, const Duration(seconds: 1));
    expect(updated.userAgent, 'agent');
    expect(updated.followRedirects, isFalse);
    expect(updated.maxRedirects, 1);
    expect(updated.maxBytes, 10);
    expect(updated.stopAfterHead, isFalse);
    expect(updated.proxyUrl, 'https://proxy');
    expect(updated.headers, {'x': 'y'});
  });

  test('ExtractOptions copyWith overrides fields', () {
    const base = ExtractOptions();
    final updated = base.copyWith(
      extractOpenGraph: false,
      extractTwitterCard: false,
      extractStandardMeta: false,
      extractLinkRels: false,
      extractJsonLd: false,
      enableOEmbed: true,
      enableManifest: true,
      includeRawMetadata: true,
      maxImages: 1,
      maxIcons: 2,
      maxVideos: 3,
      maxAudios: 4,
    );
    expect(updated.extractOpenGraph, isFalse);
    expect(updated.extractTwitterCard, isFalse);
    expect(updated.extractStandardMeta, isFalse);
    expect(updated.extractLinkRels, isFalse);
    expect(updated.extractJsonLd, isFalse);
    expect(updated.enableOEmbed, isTrue);
    expect(updated.enableManifest, isTrue);
    expect(updated.includeRawMetadata, isTrue);
    expect(updated.maxImages, 1);
    expect(updated.maxIcons, 2);
    expect(updated.maxVideos, 3);
    expect(updated.maxAudios, 4);
  });

  test('CacheOptions copyWith overrides fields', () {
    const base = CacheOptions();
    final updated = base.copyWith(
      enabled: false,
      ttl: const Duration(seconds: 1),
      payloadKind: CachePayloadKind.extractionResult,
    );
    expect(updated.enabled, isFalse);
    expect(updated.ttl, const Duration(seconds: 1));
    expect(updated.payloadKind, CachePayloadKind.extractionResult);
  });

  test('MetaLinkClientOptions copyWith overrides fields', () {
    const base = MetaLinkClientOptions();
    final updated = base.copyWith(
      fetch: const FetchOptions(timeout: Duration(seconds: 1)),
      extract: const ExtractOptions(maxImages: 1),
      cache: const CacheOptions(enabled: false),
    );
    expect(updated.fetch.timeout, const Duration(seconds: 1));
    expect(updated.extract.maxImages, 1);
    expect(updated.cache.enabled, isFalse);
  });
}
