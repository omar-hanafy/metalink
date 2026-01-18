import 'dart:io';

import 'package:hive_ce/hive_ce.dart';

class HiveTestBox {
  HiveTestBox({
    required this.box,
    required this.directory,
  });

  final Box<String> box;
  final Directory directory;
}

Future<HiveTestBox> openTestBox({
  String name = 'metalink_test_cache',
}) async {
  final dir = await Directory.systemTemp.createTemp('metalink_hive_');
  Hive.init(dir.path);
  final box = await Hive.openBox<String>(name, path: dir.path);
  return HiveTestBox(box: box, directory: dir);
}

Future<void> closeTestBox(HiveTestBox testBox) async {
  try {
    await testBox.box.close();
  } catch (_) {
    // ignore
  }
  try {
    await testBox.directory.delete(recursive: true);
  } catch (_) {
    // ignore
  }
}
