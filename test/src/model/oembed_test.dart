import 'package:metalink/src/model/oembed.dart';
import 'package:test/test.dart';

void main() {
  test('OEmbedEndpoint toJson and fromJson', () {
    final endpoint = OEmbedEndpoint(
      url: Uri.parse('https://example.com/oembed'),
      format: OEmbedFormat.xml,
    );
    final decoded = OEmbedEndpoint.fromJson(endpoint.toJson());
    expect(decoded.url.toString(), 'https://example.com/oembed');
    expect(decoded.format, OEmbedFormat.xml);
  });

  test('OEmbedData toJson and fromJson', () {
    final data = OEmbedData(
      endpoint: Uri.parse('https://example.com/oembed'),
      type: 'video',
      version: '1.0',
      title: 'Title',
      authorName: 'Author',
      authorUrl: Uri.parse('https://example.com/author'),
      providerName: 'Provider',
      providerUrl: Uri.parse('https://example.com'),
      thumbnailUrl: Uri.parse('https://example.com/thumb'),
      thumbnailWidth: 100,
      thumbnailHeight: 50,
      html: '<iframe></iframe>',
      width: 640,
      height: 360,
    );
    final decoded = OEmbedData.fromJson(data.toJson());
    expect(decoded.endpoint.toString(), 'https://example.com/oembed');
    expect(decoded.type, 'video');
    expect(decoded.authorName, 'Author');
    expect(decoded.providerName, 'Provider');
    expect(decoded.thumbnailWidth, 100);
  });
}
