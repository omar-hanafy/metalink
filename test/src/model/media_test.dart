import 'package:metalink/src/model/media.dart';
import 'package:test/test.dart';

void main() {
  test('ImageCandidate toJson and fromJson', () {
    final image = ImageCandidate(
      url: Uri.parse('https://example.com/img'),
      width: 10,
      height: 20,
      mimeType: 'image/png',
      alt: 'alt',
      byteSize: 123,
    );
    final decoded = ImageCandidate.fromJson(image.toJson());
    expect(decoded.url.toString(), 'https://example.com/img');
    expect(decoded.width, 10);
    expect(decoded.height, 20);
    expect(decoded.mimeType, 'image/png');
    expect(decoded.alt, 'alt');
    expect(decoded.byteSize, 123);
  });

  test('VideoCandidate toJson and fromJson', () {
    final video = VideoCandidate(
      url: Uri.parse('https://example.com/vid'),
      width: 10,
      height: 20,
      mimeType: 'video/mp4',
    );
    final decoded = VideoCandidate.fromJson(video.toJson());
    expect(decoded.url.toString(), 'https://example.com/vid');
    expect(decoded.width, 10);
    expect(decoded.height, 20);
    expect(decoded.mimeType, 'video/mp4');
  });

  test('AudioCandidate toJson and fromJson', () {
    final audio = AudioCandidate(
      url: Uri.parse('https://example.com/aud'),
      mimeType: 'audio/mpeg',
    );
    final decoded = AudioCandidate.fromJson(audio.toJson());
    expect(decoded.url.toString(), 'https://example.com/aud');
    expect(decoded.mimeType, 'audio/mpeg');
  });
}
