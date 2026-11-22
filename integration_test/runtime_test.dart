import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jiashu/alerts.dart';
import 'package:jiashu/data.dart';
import 'package:jiashu/main.dart';
import 'package:jiashu/native_note.dart';
import 'package:jiashu/sync.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android vault, chat rendering, notification and service lifecycle', (
    tester,
  ) async {
    final s = Session(
      school: 'runtime-fixture',
      username: '测试账号',
      role: 'dad',
      base: 'http://127.0.0.1:1',
      token: 'not-a-real-token',
      client: 'fixture',
      userId: '0',
    );
    await Alerts.init();
    await configureBackground();
    await Vault.save(s, password: 'runtime-fixture-password', allowHttp: true);
    expect((await Vault.read())!.account, s.account);
    expect((await Vault.readLogin())!.password, 'runtime-fixture-password');
    // Seed a version-2 database, as shipped in 0.3.0; preserve it during upgrade.
    final legacy = await openDatabase(
      p.join(await getDatabasesPath(), 'jiashu.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE messages(account TEXT,id TEXT,role TEXT,body TEXT,time INTEGER,status TEXT,source TEXT,version TEXT,unread INTEGER,images TEXT,PRIMARY KEY(account,id))',
        );
        await db.execute(
          'CREATE TABLE settings(account TEXT,k TEXT,v TEXT,PRIMARY KEY(account,k))',
        );
        for (final column in [
          "kind TEXT NOT NULL DEFAULT 'note'",
          "remoteId TEXT NOT NULL DEFAULT ''",
          "topicId TEXT NOT NULL DEFAULT ''",
          "contentVersion TEXT NOT NULL DEFAULT ''",
          'resourceCheckedAt INTEGER NOT NULL DEFAULT 0',
          'deleted INTEGER NOT NULL DEFAULT 0',
          'edited INTEGER NOT NULL DEFAULT 0',
        ]) {
          await db.execute('ALTER TABLE messages ADD COLUMN $column');
        }
      },
    );
    await legacy.insert('messages', {
      'account': s.account,
      'id': 'old-history',
      'role': 'dad',
      'body': '升级前的家书',
      'time': 1,
      'status': 'synced',
      'source': '云笔记',
      'version': '',
      'unread': 0,
      'images': '[]',
    });
    await legacy.close();
    expect((await Vault.readLogin())!.allowHttp, true);
    final prefFiles = Directory('/data/user/0/cn.jiashu.jiashu/shared_prefs')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.xml'))
        .toList();
    expect(prefFiles, isNotEmpty);
    for (final file in prefFiles) {
      expect(
        (await file.readAsString()).contains('runtime-fixture-password'),
        false,
        reason: 'Password must not appear as plaintext in Android preferences',
      );
    }
    final updated = Session.fromJson(
      s.toJson()..['token'] = 'updated-fixture-token',
    );
    expect(await Vault.replaceSession(s.loginId, updated), true);
    expect((await Vault.read())!.token, 'updated-fixture-token');
    expect((await Vault.readLogin())!.password, 'runtime-fixture-password');
    final store = await Store.open(s.account);
    expect((await store.get('old-history'))!.text, '升级前的家书');
    expect((await store.get('old-history'))!.topicId, '');
    await store.put(
      Message(
        id: 'topic-a',
        role: 'dad',
        text: '今天的校园生活',
        time: 2,
        kind: 'topic',
        remoteId: 'topic-a',
      ),
    );
    await store.put(
      Message(
        id: 'topic-b',
        role: 'child',
        text: '一起看看这道题',
        time: 3,
        kind: 'topic',
        remoteId: 'topic-b',
        topicId: 'topic-a',
        unread: true,
      ),
    );
    await store.put(
      Message(
        id: 'branch-reply',
        role: 'child',
        text: '这道应用题我不太明白',
        time: 4,
        topicId: 'topic-b',
        unread: true,
      ),
    );
    await store.put(
      Message(
        id: 'fixture-child',
        role: 'child',
        text: '爸爸，今天的练习做完啦！',
        time: DateTime.now().millisecondsSinceEpoch - 60000,
        unread: true,
        topicId: 'topic-a',
      ),
    );
    // Render Chinese using actual Android fonts, not the host test font.
    final nativeImage = await NativeNote.render(
      Message(
        id: '0123456789abcdef0123456789abcdef',
        role: 'dad',
        text: '家书测试123。爸爸想你了，记得吃好睡好。🌷',
        time: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    expect(nativeImage.length, greaterThan(1000));
    await File(
      '/data/user/0/cn.jiashu.jiashu/cache/native-runtime.png',
    ).writeAsBytes(nativeImage);
    await store.put(
      Message(
        id: 'fixture-dad',
        role: 'dad',
        text: '辛苦啦，记得休息，晚上聊。',
        topicId: 'topic-a',
        remoteId: 'fixture-remote-dad',
        bodyDigest: 'before-writing',
        contentVersion: 'before-writing',
        time: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await tester.pumpWidget(JiashuApp(initial: s));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('今天的校园生活'), findsOneWidget);
    expect(find.text('创建于 ${timeLabel(2)}'), findsOneWidget);
    expect(find.text('爸爸，今天的练习做完啦！'), findsNothing);
    await tester.tap(find.text('今天的校园生活'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('爸爸，今天的练习做完啦！'), findsOneWidget);
    expect(find.text('辛苦啦，记得休息，晚上聊。'), findsOneWidget);
    expect(find.text('3 条未读家书'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '留在本话题的草稿');
    await tester.tap(find.text('一起看看这道题'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('这道应用题我不太明白'), findsOneWidget);
    expect(find.text('爸爸，今天的练习做完啦！'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.tap(find.byTooltip('返回上一级话题'));
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '留在本话题的草稿',
    );
    await tester.enterText(find.byType(TextField), '');
    FocusManager.instance.primaryFocus?.unfocus();
    expect(
      await store.ingest(
        Message(
          id: 'fixture-dad',
          role: 'dad',
          text: '辛苦啦，记得休息，晚上聊。',
          time: 10,
          topicId: 'topic-a',
          remoteId: 'fixture-remote-dad',
          bodyDigest: 'continued-writing',
          contentVersion: 'continued-writing',
        ),
        baseline: false,
      ),
      true,
    );
    FlutterBackgroundService().invoke('updated', {
      'account': s.account,
      'incoming': 1,
    });
    // Manual refresh also reloads local unread events even with the fixture offline.
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('4 条未读家书'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('笔记有更新：辛苦啦，记得休息，晚上聊。'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    final screenshot = await binding.takeScreenshot('chat-runtime');
    await File(
      '/data/user/0/cn.jiashu.jiashu/cache/chat-runtime.png',
    ).writeAsBytes(screenshot);
    // Exercise the actual message menu and confirmation on Android.
    final update = (await store.messages()).singleWhere((m) => m.isUpdate);
    final updateMenu = find.byKey(ValueKey('message-menu:${update.id}'));
    Future<void> openMessageMenu(Finder menu) async {
      // Dialog focus restoration can scroll the composer into view. Start from
      // a settled list layout and bring the actual button into its viewport.
      tester
          .widget<ListView>(find.byType(ListView).first)
          .controller!
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        menu,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(menu), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
    }

    await openMessageMenu(updateMenu);
    await tester.tap(find.text('删除消息'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条更新提醒？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await store.visibleMessages()).any((m) => m.id == update.id), true);
    await openMessageMenu(updateMenu);
    await tester.tap(find.text('删除消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('笔记有更新：辛苦啦，记得休息，晚上聊。'), findsNothing);
    expect(
      (await store.visibleMessages()).any((m) => m.id == 'fixture-dad'),
      true,
    );
    final parentMenu = find.byKey(const ValueKey('message-menu:fixture-dad'));
    await openMessageMenu(parentMenu);
    await tester.tap(find.text('删除消息'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条消息？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('辛苦啦，记得休息，晚上聊。'), findsNothing);
    expect(
      (await store.visibleMessages()).any(
        (m) => m.remoteId == 'fixture-remote-dad',
      ),
      false,
    );
    expect(
      await store.get('fixture-dad'),
      isNotNull,
    ); // Identity tombstone retained.
    expect(
      await store.ingest(
        Message(
          id: 'fixture-dad',
          role: 'dad',
          text: '隐藏笔记的新内容',
          time: 20,
          topicId: 'topic-a',
          remoteId: 'fixture-remote-dad',
          bodyDigest: 'after-deletion',
          contentVersion: 'after-deletion',
        ),
        baseline: false,
      ),
      false,
    );
    // Folder menu cancellation leaves the subtree; deleting the current
    // folder then returns to its surviving parent and keeps unrelated history.
    await openMessageMenu(find.byKey(const ValueKey('topic-menu:topic-b')));
    await tester.tap(find.text('删除目录'));
    await tester.pumpAndSettle();
    expect(find.text('删除这个目录？'), findsOneWidget);
    expect(find.textContaining('全部子目录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await store.visibleMessages()).any((m) => m.id == 'topic-b'), true);
    await tester.tap(find.byKey(const ValueKey('current-topic-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除当前目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('话题与日常消息'), findsOneWidget);
    expect(find.text('今天的校园生活'), findsNothing);
    expect((await store.visibleMessages()).single.id, 'old-history');
    await tester.tap(find.byTooltip('家书设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('清空聊天记录'));
    await tester.tap(find.text('清空聊天记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('从一句问候开始'), findsOneWidget);
    expect(await store.visibleMessages(), isEmpty);
    expect((await store.messages()).where((m) => m.unread), isEmpty);
    await Alerts.permission();
    await Alerts.incoming(1);
    final active = await Alerts.plugin.getActiveNotifications();
    expect(active.any((n) => n.id == 100), true);
    expect(active.singleWhere((n) => n.id == 100).title, '家书有新消息');
    await Alerts.authentication(
      s,
      store,
      const SyncResult(0, '请重新登录', requiresLogin: true),
    );
    expect(
      (await Alerts.plugin.getActiveNotifications()).any((n) => n.id == 101),
      true,
    );
    await store.set('background', '1');
    await FlutterBackgroundService().startService();
    await tester.pump(const Duration(seconds: 4));
    expect(await FlutterBackgroundService().isRunning(), true);
    await store.set('background', '0');
    FlutterBackgroundService().invoke('stop');
    await tester.pump(const Duration(seconds: 3));
    expect(await FlutterBackgroundService().isRunning(), false);
    await Alerts.plugin.cancel(100);
    await Alerts.plugin.cancel(101);
    // Race refresh against logout on the actual Android storage plugins.
    await Future.wait([
      Vault.replaceSession(s.loginId, updated),
      Vault.clear(),
    ]);
    expect(await Vault.read(), null);
    expect(await Vault.readLogin(), null);
    expect(await Vault.replaceSession(s.loginId, updated), false);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
