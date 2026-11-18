import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:todo_endfield/main.dart';
import 'package:todo_endfield/server.dart';

void main() {
  testWidgets('the task editor previews and saves a renamed subtask', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final form = parse('''
      <form>
        <input name="id" value="7">
        <input name="title" value="交作业">
        <input name="subitem_id[0]" value="11">
        <input name="subitem_title[0]" value="校对">
        <input name="subitem_due_date[0]" value="2026-11-21">
        <input name="subitem_due_time[0]" value="15:00">
      </form>
    ''').querySelector('form')!;
    final model = TaskEditor(form, Uri.parse('https://example.test/admin.php'));
    Map<String, String>? savedTitles;
    Map<String, Deadline>? savedDeadlines;
    await tester.pumpWidget(MaterialApp(home: EditScreen(
      model: model,
      save: (changes, titles, deadlines, completions) async {
        savedTitles = titles;
        savedDeadlines = deadlines;
        return false;
      },
    )));

    await tester.tap(find.text('校对'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final name = find.descendant(of: dialog, matching: find.byType(TextField));
    final save = find.descendant(of: dialog, matching: find.widgetWithText(FilledButton, '保存'));
    expect(tester.widget<TextField>(name).controller!.text, '校对');
    expect(find.descendant(of: dialog, matching: find.text('15:00')), findsOneWidget);
    await tester.enterText(name, '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(name, '核对答案');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('核对答案'), findsOneWidget);
    expect(find.text('2026-11-21 15:00'), findsOneWidget);
    expect(savedTitles, isNull);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(savedTitles, {'11': '核对答案'});
    expect(savedDeadlines, isEmpty);
  });
}
