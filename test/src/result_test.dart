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
      errors: [MetaLinkError(code: MetaLinkErrorCode.unknown, message: 'x')],
    );
    expect(result.isSuccess, isFalse);
    expect(result.status, ExtractionStatus.failure);
    expect(result.metadataOrNull, isNull);
    expect(result.primaryError?.code, MetaLinkErrorCode.unknown);
    expect(result.retryable, isFalse);
  });

  test('ExtractionResult can explicitly represent a partial value', () {
    const result = ExtractionResult<int>(
      metadata: 1,
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: Duration.zero,
        fetch: null,
        fieldProvenance: {},
      ),
      status: ExtractionStatus.partial,
      completeness: 0.75,
    );

    expect(result.isSuccess, isTrue);
    expect(result.isPartial, isTrue);
    expect(result.metadataOrNull, 1);
    expect(result.completeness, 0.75);
  });

  test('retryability is derived from structured errors', () {
    const result = ExtractionResult<int>(
      metadata: 1,
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: Duration.zero,
        fetch: null,
        fieldProvenance: {},
      ),
      errors: [
        MetaLinkError(code: MetaLinkErrorCode.timeout, message: 'slow'),
        MetaLinkError(
          code: MetaLinkErrorCode.httpStatus,
          message: 'busy',
          statusCode: 503,
        ),
      ],
    );

    expect(result.retryable, isTrue);
  });

  test('fatal errors dominate a contradictory explicit status', () {
    const result = ExtractionResult<int>(
      metadata: 1,
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: Duration.zero,
        fetch: null,
        fieldProvenance: {},
      ),
      status: ExtractionStatus.success,
      errors: [MetaLinkError(code: MetaLinkErrorCode.parse, message: 'broken')],
    );

    expect(result.status, ExtractionStatus.failure);
    expect(result.isFailure, isTrue);
    expect(result.isSuccess, isFalse);
    expect(result.metadataOrNull, isNull);
  });
}
