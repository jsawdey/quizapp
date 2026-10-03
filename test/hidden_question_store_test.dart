import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

void main() {
  late Directory dir;

  setUpAll(sqfliteFfiInit);
  setUp(() async => dir = await Directory.systemTemp.createTemp('hidden_store_test'));
  tearDown(() => dir.delete(recursive: true));

  SqfliteHiddenQuestionStore store() => SqfliteHiddenQuestionStore(
      databaseFactory: databaseFactoryFfi,
      path: () async => p.join(dir.path, 'user.db'));

  test('hidden questions survive reopening', () async {
    final first = store();
    await first.open();
    await first.hide(fakeQuestion('1', sourceId: 'jwolle1'));
    await first.close();

    final second = store();
    await second.open();
    expect(second.isHidden(fakeQuestion('1', sourceId: 'jwolle1')), isTrue);
    expect(second.isHidden(fakeQuestion('1', sourceId: 'jservice:x')), isFalse);
    expect(second.isHidden(fakeQuestion('2', sourceId: 'jwolle1')), isFalse);
    await second.close();
  });

  test('hiding the same question twice is fine', () async {
    final s = store();
    await s.open();
    await s.hide(fakeQuestion('1'));
    await s.hide(fakeQuestion('1'));
    expect(s.isHidden(fakeQuestion('1')), isTrue);
    await s.close();
  });

  test('hide before open is an error', () async {
    await expectLater(store().hide(fakeQuestion('1')), throwsStateError);
  });
}
