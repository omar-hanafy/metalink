import 'dart:convert';

import 'package:metalink/src/fetch/fetch_utils.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/json_utils.dart';

/// Fetches a web app manifest and parses it into [WebAppManifestData].
///
/// The extraction pipeline uses this for optional manifest enrichment after a
/// `<link rel="manifest">` URL is discovered in the page. Parsing is
/// best-effort: an unusable response yields `null`.
class ManifestEnricher {
  /// Creates a stateless manifest enricher.
  const ManifestEnricher();

  /// Fetches [manifestUrl] with [fetcher] and parses the JSON manifest.
  ///
  /// The GET request follows redirects and applies the request policy,
  /// timeouts, and redirect limits in [fetchOptions] for
  /// [RequestPurpose.manifest]. When [requestContext] is given, its deadline
  /// and cancellation signal also bound the request. The body is read up to
  /// the smaller of `fetchOptions.maxBytes` and 512 KiB and decoded as UTF-8,
  /// replacing malformed bytes.
  ///
  /// Returns `null` when the request fails, the final status is not 2xx, or
  /// the body is not a JSON object. The returned
  /// [WebAppManifestData.manifestUrl] is the final URL after redirects, and
  /// `start_url` and each icon `src` are resolved against it. Text and URL
  /// fields must be JSON strings; any other JSON value yields `null` for that
  /// field. Icon entries that are not objects or have no string `src` are
  /// skipped.
  Future<WebAppManifestData?> fetchAndParse({
    required Fetcher fetcher,
    required FetchOptions fetchOptions,
    required Uri manifestUrl,
    RequestContext? requestContext,
  }) async {
    final response = await FetchUtils.getWithRedirects(
      fetcher,
      manifestUrl,
      options: fetchOptions,
      headers: const {
        'accept':
            'application/manifest+json, application/json;q=0.9, */*;q=0.8',
      },
      maxBytes: fetchOptions.maxBytes < _maxManifestBytes
          ? fetchOptions.maxBytes
          : _maxManifestBytes,
      context: requestContext,
      purpose: RequestPurpose.manifest,
    );

    if (response.error != null) return null;
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) return null;

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final obj = JsonUtils.tryDecodeObject(text);
    if (obj == null) return null;
    final resolvedManifestUrl = response.url;

    final name = _asString(obj['name']);
    final shortName = _asString(obj['short_name']);
    final display = _asString(obj['display']);
    final backgroundColor = _asString(obj['background_color']);
    final themeColor = _asString(obj['theme_color']);

    final startUrlRaw = _asString(obj['start_url']);
    final startUrl = startUrlRaw == null
        ? null
        : _resolveAgainst(resolvedManifestUrl, startUrlRaw);

    final icons = <ManifestIcon>[];
    final iconsRaw = obj['icons'];
    if (iconsRaw is List) {
      for (final item in iconsRaw) {
        if (item is! Map) continue;
        final srcRaw = _asString(item['src']);
        if (srcRaw == null) continue;

        final src = _resolveAgainst(resolvedManifestUrl, srcRaw);
        if (src == null) continue;

        icons.add(
          ManifestIcon(
            src: src,
            sizes: _asString(item['sizes']),
            type: _asString(item['type']),
            purpose: _asString(item['purpose']),
          ),
        );
      }
    }

    return WebAppManifestData(
      manifestUrl: resolvedManifestUrl,
      name: name,
      shortName: shortName,
      startUrl: startUrl,
      display: display,
      backgroundColor: backgroundColor,
      themeColor: themeColor,
      icons: icons,
    );
  }

  static Uri? _resolveAgainst(Uri base, String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    // Use Uri.resolve to support both absolute and relative manifest URLs.
    try {
      return base.resolve(s);
    } catch (_) {
      return Uri.tryParse(s);
    }
  }

  // Only JSON strings are text: stringifying `false` or `42` would invent
  // names and URLs such as `<manifest>/false`.
  static String? _asString(dynamic v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }
}

const int _maxManifestBytes = 512 * 1024;
