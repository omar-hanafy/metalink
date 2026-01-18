import 'package:metalink/src/model/structured_data.dart';
import 'package:test/test.dart';

void main() {
  test('StructuredDataGraph toJson and fromJson', () {
    const graph = StructuredDataGraph(nodes: [
      {'@type': 'Article'},
      {'@type': 'Person'}
    ]);
    final decoded = StructuredDataGraph.fromJson(graph.toJson());
    expect(decoded.nodes.length, 2);
    expect(decoded.nodes.first['@type'], 'Article');
  });

  test('StructuredDataGraph filters empty nodes', () {
    final decoded = StructuredDataGraph.fromJson({
      'nodes': [
        {'@type': 'Article'},
        {},
        'bad'
      ]
    });
    expect(decoded.nodes.length, 1);
  });
}
