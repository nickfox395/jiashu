import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jiashu/data.dart';
import 'package:jiashu/main.dart';
import 'package:jiashu/note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

class _UnusedStore extends Fake implements Store {}

void main() {
  testWidgets(
    'Edit a child page with pen, whiteout and text, and undo each change',
    (tester) async {
      final image = File('test/fixtures/native-page.png').readAsBytesSync();
      final session = Session(
        school: 'test',
        username: 'fixture',
        role: 'dad',
        base: '',
        token: '',
        client: '',
        userId: '123',
      );
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: NoteEditor(
                session: session,
                store: _UnusedStore(),
                note: Message(
                  id: 'child',
                  role: 'child',
                  text: '原名',
                  time: 1,
                  images: [
                    'https://example.test/first',
                    'https://example.test/second',
                  ],
                ),
                pageIndex: 1,
              ),
            ),
          );
        },
        () => MockClient((r) async {
          expect(r.url.path, '/second');
          return http.Response.bytes(image, 200);
        }),
      );
      for (var i = 0; i < 40 && find.text('画笔').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('编辑正文 · 第 2 页'), findsOneWidget);
      final save = find.widgetWithText(TextButton, '保存');
      final canvas = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.child is CustomPaint,
      );
      expect(tester.widget<TextButton>(save).onPressed, isNull);
      await tester.drag(canvas, const Offset(15, 10));
      await tester.pump();
      await tester.tap(find.text('涂白'));
      await tester.pump();
      await tester.drag(canvas, const Offset(0, 10));
      await tester.pump();
      await tester.tap(find.text('文字'));
      await tester.pump();
      await tester.tap(canvas);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '改在这一页');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        expect(tester.widget<TextButton>(save).onPressed, isNotNull);
        await tester.tap(find.byTooltip('撤销'));
        await tester.pump();
      }
      expect(tester.widget<TextButton>(save).onPressed, isNull);
    },
  );
  testWidgets('Chat opens, resumes and sends at the bottom of a long history', (
    tester,
  ) async {
    FlutterBackgroundServiceAndroid.registerWith();
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    sqfliteFfiInit();
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
    databaseFactory = databaseFactoryFfiNoIsolate;
    final temp = Directory.systemTemp.createTempSync('jiashu-test-');
    await databaseFactory.setDatabasesPath(temp.path);
    final session = Session(
      school: 'local',
      username: 'fixture',
      role: 'dad',
      base: 'http://127.0.0.1',
      token: '',
      client: '',
      userId: '0',
    );
    final store = (await tester.runAsync(() => Store.open(session.account)))!;
    addTearDown(() async {
      await store.db.close();
      temp.deleteSync(recursive: true);
    });
    for (var i = 1; i <= 40; i++) {
      await store.put(
        Message(
          id: 'm$i',
          role: 'child',
          text: '消息 $i',
          time: i,
          unread: i >= 39,
          images: [
            if (i >= 39) 'https://example.test/1',
            if (i == 40) 'https://example.test/2',
          ],
        ),
      );
    }
    await store.put(
      Message(
        id: 'topic',
        remoteId: 'topic',
        role: 'mom',
        text: '周末计划',
        time: 41,
        kind: 'topic',
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (_) async => null,
    );
    await store.lock('offline-test');
    await tester.pumpWidget(JiashuApp(initial: session));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(find.text('消息 40').hitTestable(), findsOneWidget);
    expect(find.text('创建于 ${timeLabel(41)}').hitTestable(), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    final star = tester.widget<Text>(find.text('*').first);
    expect(star.style?.color, Colors.red);
    expect(find.text('2 条未读家书'), findsOneWidget);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final info = ImageInfo(image: recorder.endRecording().toImageSync(1, 1));
    PaintingBinding.instance.imageCache.putIfAbsent(
      const NetworkImage('https://example.test/1'),
      () => OneFrameImageStreamCompleter(Future.value(info)),
    );
    await tester.tap(find.text('消息 40'));
    await tester.pumpAndSettle();
    expect(find.text('笔记正文 · 第 1 页'), findsOneWidget);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('笔记正文 · 第 2 页'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await store.get('m40'))!.unread, isFalse);
    expect((await store.get('m39'))!.unread, isTrue);
    expect(find.text('1 条未读家书'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('消息 39'),
      140,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('消息 39'));
    await tester.pumpAndSettle();
    expect(find.text('笔记正文 · 第 1 页'), findsOneWidget);
    expect(find.byTooltip('下一页'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('*'), findsNothing);
    expect((await store.get('m39'))!.unread, isFalse);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('周末计划'));
    await tester.pumpAndSettle();
    expect(find.text('妈妈开启 · ${timeLabel(41)}'), findsOneWidget);
    await tester.tap(find.byTooltip('返回上一级话题'));
    await tester.pumpAndSettle();
    controller.jumpTo(1500);
    await tester.pump();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    controller.jumpTo(1500);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '刚刚发送');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.text('刚刚发送').hitTestable(), findsOneWidget);
    await store.unlock('offline-test');
    await tester.tap(find.byTooltip('家书设置'));
    await tester.pumpAndSettle();
    expect(find.text('后台接收与新消息提醒'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(find.text('重新检查通路'), findsNothing);
    expect(find.text('孩子怎么回复？'), findsNothing);
    await tester.ensureVisible(find.text('清空聊天记录'));
    await tester.tap(find.text('清空聊天记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('周末计划').hitTestable(), findsOneWidget);
    expect(find.text('刚刚发送'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Login exposes parent identity, school, account and transport choice',
    (tester) async {
      await tester.pumpWidget(const JiashuApp());
      expect(find.text('爸爸'), findsOneWidget);
      expect(find.text('妈妈'), findsOneWidget);
      expect(find.text('学生密码'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      await tester.tap(find.text('妈妈'));
      await tester.pump();
      final segment = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segment.selected, {'mom'});
      expect(tester.takeException(), isNull);
    },
  );
}
