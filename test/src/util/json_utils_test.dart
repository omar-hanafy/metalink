import 'package:metalink/src/util/json_utils.dart';
import 'package:test/test.dart';

void main() {
  test('tryDecodeObject returns map or null', () {
    expect(JsonUtils.tryDecodeObject('{"a":1}')!['a'], 1);
    expect(JsonUtils.tryDecodeObject('[1,2,3]'), isNull);
    expect(JsonUtils.tryDecodeObject('not-json'), isNull);
  });

  test('tryDecodeList returns list or null', () {
    expect(JsonUtils.tryDecodeList('[1,2]'), [1, 2]);
    expect(JsonUtils.tryDecodeList('{"a":1}'), isNull);
    expect(JsonUtils.tryDecodeList('bad'), isNull);
  });

  test('tryDecodeAny returns decoded or null', () {
    expect(JsonUtils.tryDecodeAny('true'), true);
    expect(JsonUtils.tryDecodeAny('bad'), isNull);
  });
}
