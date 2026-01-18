import 'dart:convert';

import 'package:xml/xml.dart' as xml;

import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/util/json_utils.dart';

import 'package:metalink/src/fetch/fetch_utils.dart';

class OEmbedEnricher {
  const OEmbedEnricher();

  Future<OEmbedData?> fetchAndParse({
    required Fetcher fetcher,
    required FetchOptions fetchOptions,
    required OEmbedEndpoint endpoint,
  }) async {
    final response = await FetchUtils.getWithRedirects(
      fetcher,
      endpoint.url,
      options: fetchOptions,
      headers: const {
        'accept':
            'application/json, text/xml, application/xml;q=0.9, */*;q=0.8',
      },
      maxBytes: 256 * 1024,
    );

    if (response.error != null) return null;
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) return null;

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);

    switch (endpoint.format) {
      case OEmbedFormat.json:
        return _parseJson(endpoint.url, text);
      case OEmbedFormat.xml:
        // If XML is declared but parsing fails, return null so enrichment stays best-effort.
        return _parseXml(endpoint.url, text);
    }
  }

  OEmbedData? _parseJson(Uri endpointUrl, String text) {
    final obj = JsonUtils.tryDecodeObject(text);
    if (obj == null) return null;

    return OEmbedData(
      endpoint: endpointUrl,
      type: _asString(obj['type']),
      version: _asString(obj['version']),
      title: _asString(obj['title']),
      authorName: _asString(obj['author_name']),
      authorUrl: _asUri(obj['author_url']),
      providerName: _asString(obj['provider_name']),
      providerUrl: _asUri(obj['provider_url']),
      thumbnailUrl: _asUri(obj['thumbnail_url']),
      thumbnailWidth: _asInt(obj['thumbnail_width']),
      thumbnailHeight: _asInt(obj['thumbnail_height']),
      html: _asString(obj['html']),
      width: _asInt(obj['width']),
      height: _asInt(obj['height']),
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
      authorUrl: _asUri(t('author_url')),
      providerName: t('provider_name'),
      providerUrl: _asUri(t('provider_url')),
      thumbnailUrl: _asUri(t('thumbnail_url')),
      thumbnailWidth: _asInt(t('thumbnail_width')),
      thumbnailHeight: _asInt(t('thumbnail_height')),
      html: t('html'),
      width: _asInt(t('width')),
      height: _asInt(t('height')),
    );
  }

  String? _xmlText(xml.XmlDocument doc, String name) {
    final el = doc.findAllElements(name).cast<xml.XmlElement?>().firstWhere(
          (e) => e != null,
          orElse: () => null,
        );
    final text = el?.innerText;
    final v = text?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static String? _asString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }

  static Uri? _asUri(dynamic v) {
    final s = _asString(v);
    if (s == null) return null;
    return Uri.tryParse(s);
  }
}
