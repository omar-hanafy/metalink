import 'dart:convert';

import 'package:metalink/src/fetch/fetch_utils.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/json_utils.dart';
import 'package:xml/xml.dart' as xml;

/// Fetches an oEmbed endpoint and parses its JSON or XML response into
/// [OEmbedData].
///
/// The extraction pipeline uses this for optional oEmbed enrichment after an
/// endpoint is discovered in the page. Parsing is best-effort: an unusable
/// response yields `null`, and an unusable field yields a `null` field.
class OEmbedEnricher {
  /// Creates a stateless oEmbed enricher.
  const OEmbedEnricher();

  /// Fetches [endpoint] with [fetcher] and parses the body in the endpoint's
  /// declared [OEmbedEndpoint.format].
  ///
  /// The GET request follows redirects and applies the request policy,
  /// timeouts, and redirect limits in [fetchOptions] for
  /// [RequestPurpose.oEmbed]. When [requestContext] is given, its deadline and
  /// cancellation signal also bound the request. The body is read up to the
  /// smaller of `fetchOptions.maxBytes` and 256 KiB and decoded as UTF-8,
  /// replacing malformed bytes.
  ///
  /// Returns `null` when the request fails, the final status is not 2xx, or
  /// the body is not a JSON object or well-formed XML as declared. The
  /// returned [OEmbedData.endpoint] is the final URL after redirects, and
  /// relative `thumbnail_url`, `author_url`, and `provider_url` values are
  /// resolved against it.
  ///
  /// Text and URL fields must be JSON strings; any other JSON value yields
  /// `null` for that field. A numeric `version` is kept as text: a finite
  /// integral number such as `1` or `1.0` becomes `"1.0"` on every platform,
  /// another finite number keeps its decimal text such as `"1.5"`, and a
  /// non-finite number yields `null`. Each width and height, including the
  /// thumbnail's, is a number or numeric string truncated toward zero, and is
  /// `null` unless the result is positive and at most `2^53 - 1`.
  Future<OEmbedData?> fetchAndParse({
    required Fetcher fetcher,
    required FetchOptions fetchOptions,
    required OEmbedEndpoint endpoint,
    RequestContext? requestContext,
  }) async {
    final response = await FetchUtils.getWithRedirects(
      fetcher,
      endpoint.url,
      options: fetchOptions,
      headers: const {
        'accept':
            'application/json, text/xml, application/xml;q=0.9, */*;q=0.8',
      },
      maxBytes: fetchOptions.maxBytes < _maxOEmbedBytes
          ? fetchOptions.maxBytes
          : _maxOEmbedBytes,
      context: requestContext,
      purpose: RequestPurpose.oEmbed,
    );

    if (response.error != null) return null;
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) return null;

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final resolvedEndpointUrl = response.url;

    switch (endpoint.format) {
      case OEmbedFormat.json:
        return _parseJson(resolvedEndpointUrl, text);
      case OEmbedFormat.xml:
        // If XML is declared but parsing fails, return null so enrichment stays best-effort.
        return _parseXml(resolvedEndpointUrl, text);
    }
  }

  OEmbedData? _parseJson(Uri endpointUrl, String text) {
    final obj = JsonUtils.tryDecodeObject(text);
    if (obj == null) return null;

    return OEmbedData(
      endpoint: endpointUrl,
      type: _asString(obj['type']),
      version: _asVersion(obj['version']),
      title: _asString(obj['title']),
      authorName: _asString(obj['author_name']),
      authorUrl: _asUri(endpointUrl, obj['author_url']),
      providerName: _asString(obj['provider_name']),
      providerUrl: _asUri(endpointUrl, obj['provider_url']),
      thumbnailUrl: _asUri(endpointUrl, obj['thumbnail_url']),
      thumbnailWidth: _asDimension(obj['thumbnail_width']),
      thumbnailHeight: _asDimension(obj['thumbnail_height']),
      html: _asString(obj['html']),
      width: _asDimension(obj['width']),
      height: _asDimension(obj['height']),
    );
  }

  OEmbedData? _parseXml(Uri endpointUrl, String text) {
    xml.XmlDocument doc;
    try {
      doc = xml.XmlDocument.parse(text);
    } catch (_) {
      return null;
    }

    String? t(String name) => _xmlText(doc, name);

    return OEmbedData(
      endpoint: endpointUrl,
      type: t('type'),
      version: t('version'),
      title: t('title'),
      authorName: t('author_name'),
      authorUrl: _asUri(endpointUrl, t('author_url')),
      providerName: t('provider_name'),
      providerUrl: _asUri(endpointUrl, t('provider_url')),
      thumbnailUrl: _asUri(endpointUrl, t('thumbnail_url')),
      thumbnailWidth: _asDimension(t('thumbnail_width')),
      thumbnailHeight: _asDimension(t('thumbnail_height')),
      html: t('html'),
      width: _asDimension(t('width')),
      height: _asDimension(t('height')),
    );
  }

  String? _xmlText(xml.XmlDocument doc, String name) {
    final el = doc
        .findAllElements(name)
        .cast<xml.XmlElement?>()
        .firstWhere((e) => e != null, orElse: () => null);
    final text = el?.innerText;
    final v = text?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  // Only JSON strings are text: stringifying `true` or `123` would invent
  // titles and URLs such as `<endpoint>/true`.
  static String? _asString(dynamic v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  // The specification makes `version` a string, but providers often send the
  // number `1.0`. JSON decoding cannot tell `1` from `1.0`, and on the web
  // `1.0.toString()` is "1", so a finite integral number is written as
  // `<integer>.0` on every platform. Other finite numbers keep their decimal
  // text, and infinity or NaN is treated as missing.
  static String? _asVersion(dynamic v) {
    if (v is! num) return _asString(v);
    if (!v.isFinite) return null;
    return v == v.truncateToDouble() ? '${BigInt.from(v)}.0' : v.toString();
  }

  // JSON numbers such as `1e400` decode to infinity, and `toInt()` throws on
  // infinity and NaN while clamping huge finite values on the VM. Such values,
  // integers beyond `2^53 - 1`, and non-positive sizes are treated as missing,
  // so one bad field cannot discard the whole payload.
  static int? _asDimension(dynamic v) {
    final num? number = switch (v) {
      final num n => n,
      final String s => int.tryParse(s.trim()) ?? double.tryParse(s.trim()),
      _ => null,
    };
    if (number == null || !number.isFinite) return null;
    if (number.abs() > _maxExactInteger) return null;
    final value = number.toInt();
    return value > 0 ? value : null;
  }

  // Providers may send relative URLs; they are relative to the oEmbed
  // response, which can live on a different host than the page.
  static Uri? _asUri(Uri base, dynamic v) {
    final s = _asString(v);
    if (s == null) return null;
    try {
      return base.resolve(s);
    } on FormatException {
      return null;
    }
  }
}

const int _maxOEmbedBytes = 256 * 1024;

/// The largest integer that every Dart platform represents exactly (2^53 - 1).
const int _maxExactInteger = 9007199254740991;
