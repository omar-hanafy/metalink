import 'dart:convert';

import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/util/json_utils.dart';

import 'package:metalink/src/fetch/fetch_utils.dart';

class ManifestEnricher {
  const ManifestEnricher();

  Future<WebAppManifestData?> fetchAndParse({
    required Fetcher fetcher,
    required FetchOptions fetchOptions,
    required Uri manifestUrl,
  }) async {
    final response = await FetchUtils.getWithRedirects(
      fetcher,
      manifestUrl,
      options: fetchOptions,
      headers: const {
        'accept':
            'application/manifest+json, application/json;q=0.9, */*;q=0.8',
      },
      maxBytes: 512 * 1024,
    );

    if (response.error != null) return null;
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) return null;

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final obj = JsonUtils.tryDecodeObject(text);
    if (obj == null) return null;

    final name = _asString(obj['name']);
    final shortName = _asString(obj['short_name']);
    final display = _asString(obj['display']);
    final backgroundColor = _asString(obj['background_color']);
    final themeColor = _asString(obj['theme_color']);

    final startUrlRaw = _asString(obj['start_url']);
    final startUrl =
        startUrlRaw == null ? null : _resolveAgainst(manifestUrl, startUrlRaw);

    final icons = <ManifestIcon>[];
    final iconsRaw = obj['icons'];
    if (iconsRaw is List) {
      for (final item in iconsRaw) {
        if (item is! Map) continue;
        final srcRaw = _asString(item['src']);
        if (srcRaw == null) continue;

        final src = _resolveAgainst(manifestUrl, srcRaw);
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
      manifestUrl: manifestUrl,
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

  static String? _asString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
}
