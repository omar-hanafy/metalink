import 'package:metalink/src/model/icon.dart';
import 'package:test/test.dart';

void main() {
  test('IconCandidate toJson and fromJson', () {
    final icon = IconCandidate(
      url: Uri.parse('https://example.com/icon'),
      sizes: '16x16',
      type: 'image/png',
      rel: 'icon',
    );
    final decoded = IconCandidate.fromJson(icon.toJson());
    expect(decoded.url.toString(), 'https://example.com/icon');
    expect(decoded.sizes, '16x16');
    expect(decoded.type, 'image/png');
    expect(decoded.rel, 'icon');
  });
}
