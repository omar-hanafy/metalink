import 'dart:io';
import 'dart:isolate';

import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/result.dart';
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

  test(
    'explicit failure without errors infers status when asserts are off',
    () async {
      // The constructor assert rejects this state whenever assertions are
      // enabled, which includes `dart test`. Release builds skip the assert,
      // so the probe runs in a child VM with assertions disabled.
      final packageConfig =
          await Isolate.packageConfig ??
          File('.dart_tool/package_config.json').absolute.uri;
      final tempDir = Directory.systemTemp.createTempSync('metalink_status_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final probe = File('${tempDir.path}/status_probe.dart')
        ..writeAsStringSync(_releaseStatusProbe);

      final run = await Process.run(Platform.resolvedExecutable, [
        '--no-enable-asserts',
        '--packages=${packageConfig.toFilePath()}',
        probe.path,
      ]);

      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect((run.stdout as String).trim().split('\n'), <String>[
        'degraded=partial',
        'clean=success',
      ]);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Builds results that the constructor assert would reject and prints their
/// effective statuses.
const _releaseStatusProbe = r'''
import 'dart:io';

import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/result.dart';

ExtractionResult<int> build(List<MetaLinkWarning> warnings) {
  return ExtractionResult<int>(
    metadata: 1,
    diagnostics: const ExtractionDiagnostics(
      cacheHit: false,
      totalTime: Duration.zero,
      fetch: null,
      fieldProvenance: {},
    ),
    warnings: warnings,
    status: ExtractionStatus.failure,
  );
}

void main() {
  var assertsEnabled = false;
  assert(assertsEnabled = true, 'detects assertion mode');
  if (assertsEnabled) {
    stderr.writeln('assertions must be disabled for this probe');
    exit(2);
  }
  final degraded = build(const [
    MetaLinkWarning(code: MetaLinkWarningCode.truncatedHtml, message: 'cut'),
  ]);
  final clean = build(const []);
  stdout.writeln('degraded=${degraded.status.name}');
  stdout.writeln('clean=${clean.status.name}');
}
''';
