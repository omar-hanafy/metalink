import 'package:metalink/src/model/errors.dart';
import 'package:test/test.dart';

void main() {
  test('MetaLinkError toJson and fromJson', () {
    final err = MetaLinkError(
      code: MetaLinkErrorCode.httpStatus,
      message: 'oops',
      uri: Uri.parse('https://example.com'),
      statusCode: 500,
      cause: StateError('x'),
      stackTrace: StackTrace.fromString('stack'),
    );
    final decoded = MetaLinkError.fromJson(err.toJson());
    expect(decoded.code, MetaLinkErrorCode.httpStatus);
    expect(decoded.message, 'oops');
    expect(decoded.uri.toString(), 'https://example.com');
    expect(decoded.statusCode, 500);
  });

  test('MetaLinkWarning toJson and fromJson', () {
    final warn = MetaLinkWarning(
      code: MetaLinkWarningCode.charsetFallback,
      message: 'warn',
      uri: Uri.parse('https://example.com'),
      cause: 'cause',
    );
    final decoded = MetaLinkWarning.fromJson(warn.toJson());
    expect(decoded.code, MetaLinkWarningCode.charsetFallback);
    expect(decoded.message, 'warn');
    expect(decoded.uri.toString(), 'https://example.com');
  });

  test('MetaLinkError.fromJson defaults unknown code', () {
    final decoded = MetaLinkError.fromJson({'code': 'nope', 'message': ''});
    expect(decoded.code, MetaLinkErrorCode.unknown);
  });

  test('MetaLinkWarning.fromJson defaults partialParse', () {
    final decoded = MetaLinkWarning.fromJson({'code': 'nope', 'message': ''});
    expect(decoded.code, MetaLinkWarningCode.partialParse);
  });
}
