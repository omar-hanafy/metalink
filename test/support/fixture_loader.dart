import 'dart:io';

import 'package:path/path.dart' as path;

String fixturePath(String relativePath) {
  return path.join('test', 'fixtures', relativePath);
}

String readFixture(String relativePath) {
  return File(fixturePath(relativePath)).readAsStringSync();
}

List<int> readFixtureBytes(String relativePath) {
  return File(fixturePath(relativePath)).readAsBytesSync();
}
