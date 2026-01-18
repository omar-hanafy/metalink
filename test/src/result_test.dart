import 'package:metalink/src/result.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:test/test.dart';

void main() {
  test('ExtractionResult isSuccess when errors empty', () {
    const result = ExtractionResult<int>(
      metadata: 1,
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: Duration.zero,
        fetch: null,
        fieldProvenance: {},
      ),
    );
    expect(result.isSuccess, isTrue);
  });

  test('ExtractionResult isSuccess false when errors present', () {
    const result = ExtractionResult<int>(
      metadata: 1,
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: Duration.zero,
        fetch: null,
        fieldProvenance: {},
      ),
      errors: [
        MetaLinkError(code: MetaLinkErrorCode.unknown, message: 'x'),
      ],
    );
    expect(result.isSuccess, isFalse);
  });
}
