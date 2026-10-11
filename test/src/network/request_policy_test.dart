import 'package:metalink/src/network/request_policy.dart';
import 'package:test/test.dart';

void main() {
  group('RequestPolicy.secure', () {
    test('returns one shared instance for the default preset', () {
      expect(identical(RequestPolicy.secure(), RequestPolicy.secure()), isTrue);
      expect(
        identical(
          RequestPolicy.secure(cachePartition: 'secure'),
          RequestPolicy.secure(),
        ),
        isTrue,
      );
    });

    test('returns a new instance when the preset is customized', () {
      Future<RequestPolicyDecision> allow(RequestTarget _) async =>
          const RequestPolicyDecision.allow();

      for (final custom in [
        () => RequestPolicy.secure(additionalValidator: allow),
        () => RequestPolicy.secure(proxyTargetValidator: allow),
        () => RequestPolicy.secure(cachePartition: 'tenant-a'),
      ]) {
        final policy = custom();
        expect(identical(policy, RequestPolicy.secure()), isFalse);
        expect(identical(policy, custom()), isFalse);
      }
    });

    test('the shared instance keeps the secure preset', () async {
      final policy = RequestPolicy.secure();

      expect(policy.cachePartition, 'secure');
      expect(policy.proxyTargetValidator, isNull);
      expect(policy.forwardSensitiveHeadersThroughProxy, isFalse);
      expect(policy.requireInspectableRedirects, isTrue);
      final loopback = await policy.validateTarget(
        RequestTarget(
          uri: Uri.parse('http://127.0.0.1/'),
          purpose: RequestPurpose.document,
          stage: RequestTargetStage.redirect,
          redirectCount: 1,
          previousUri: Uri.parse('https://example.com/'),
        ),
      );
      final public = await policy.validateTarget(
        RequestTarget(
          uri: Uri.parse('https://example.com/'),
          purpose: RequestPurpose.document,
          stage: RequestTargetStage.initial,
          redirectCount: 0,
        ),
      );
      expect(loopback.allowed, isFalse);
      expect(public.allowed, isTrue);
    });
  });
}
