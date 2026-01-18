import 'package:metalink/src/model/manifest.dart';
import 'package:test/test.dart';

void main() {
  test('ManifestIcon toJson and fromJson', () {
    final icon = ManifestIcon(
      src: Uri.parse('https://example.com/icon.png'),
      sizes: '128x128',
      type: 'image/png',
      purpose: 'any',
    );
    final decoded = ManifestIcon.fromJson(icon.toJson());
    expect(decoded.src.toString(), 'https://example.com/icon.png');
    expect(decoded.sizes, '128x128');
    expect(decoded.type, 'image/png');
    expect(decoded.purpose, 'any');
  });

  test('WebAppManifestData toJson and fromJson', () {
    final data = WebAppManifestData(
      manifestUrl: Uri.parse('https://example.com/manifest.json'),
      name: 'App',
      shortName: 'A',
      startUrl: Uri.parse('https://example.com/start'),
      display: 'standalone',
      backgroundColor: '#fff',
      themeColor: '#000',
      icons: [
        ManifestIcon(src: Uri.parse('https://example.com/icon.png')),
      ],
    );
    final decoded = WebAppManifestData.fromJson(data.toJson());
    expect(decoded.manifestUrl.toString(), 'https://example.com/manifest.json');
    expect(decoded.name, 'App');
    expect(decoded.shortName, 'A');
    expect(decoded.startUrl.toString(), 'https://example.com/start');
    expect(decoded.icons.length, 1);
  });

  test('WebAppManifestData ignores invalid icons', () {
    final decoded = WebAppManifestData.fromJson({
      'manifestUrl': 'https://example.com/manifest.json',
      'icons': [
        {'src': 'https://example.com/icon.png'},
        'bad'
      ]
    });
    expect(decoded.icons.length, 1);
  });
}
