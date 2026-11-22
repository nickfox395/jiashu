import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:jiashu/api.dart';
import 'package:jiashu/data.dart';
import 'package:jiashu/native_note.dart';
import 'package:jiashu/protocol.dart';
import 'package:jiashu/sync.dart';
import 'package:jiashu/topics.dart';

Map<String, dynamic> node(
  String id,
  String parent,
  String title, {
  bool topic = false,
  bool shared = false,
}) => {
  'fileId': id,
  'parentId': parent,
  'fileName': title,
  'type': topic ? 0 : 12,
  'shared': shared,
  'version': 1,
  'createTime': '2026-11-17T08:00:00Z',
};

class TopicServer extends SchoolApi {
  final records = <Map<String, dynamic>>[node('root', '0', '家书', topic: true)];
  final hashes = <String, String>{}, failures = <String>{};
  final reads = <String>[];
  int folderWrites = 0, noteWrites = 0;
  bool loseFolderResponse = false;
  TopicServer(super.session);
  @override
  Future<List<Map<String, dynamic>>> allNotes({
    bool includeRecycled = false,
  }) async => records.map((e) => Map<String, dynamic>.from(e)).toList();
  @override
  Future<void> addFolder(String id, String parent, String title) async {
    folderWrites++;
    records.add(node(id, parent, title, topic: true));
    if (loseFolderResponse) {
      loseFolderResponse = false;
      throw const SocketException('response lost');
    }
  }

  @override
  Future<void> addNativeNote(
    Message m,
    String parent, {
    Future<void> Function()? checkpoint,
  }) async {
    await checkpoint?.call();
    noteWrites++;
    records.add(
      node(NativeNote.fileId(m.id), parent, letterTitle(m.role, m.text)),
    );
  }

  @override
  Future<({List<String> images, String digest})> noteContent(String id) async {
    reads.add(id);
    if (failures.contains(id)) throw const ApiFailure('页面尚未同步');
    return (
      images: ['https://ezy-test.oss-cn-hangzhou.aliyuncs.com/$id.png'],
      digest: hashes[id] ?? 'v1',
    );
  }

  @override
  void close() {} // Reused in-memory server, no network calls.
}

void main() {
  sqfliteFfiInit();
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }
  final session = Session(
    school: 'test',
    username: 'fixture',
    role: 'dad',
    base: 'https://test.zykj.org',
    token: 'fixture',
    client: '',
    userId: '123',
  );
  late Database db;
  late Store store;
  late TopicServer server;
  late SyncEngine engine;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE messages(account TEXT,id TEXT,role TEXT,body TEXT,time INTEGER,status TEXT,source TEXT,version TEXT,unread INTEGER,images TEXT,PRIMARY KEY(account,id))',
    );
    await db.execute(
      'CREATE TABLE settings(account TEXT,k TEXT,v TEXT,PRIMARY KEY(account,k))',
    );
    await Store.upgradeTopics(db);
    store = Store(db, session.account);
    server = TopicServer(session);
    engine = SyncEngine(session, store, apiFactory: (_) => server);
    await store.set('folder', 'root');
  });
  tearDown(() => db.close());
  Future<Message> remote(String id) async => (await store.messages())
      .singleWhere((m) => m.remoteId == id && !m.isUpdate);

  test(
    'Clearing all chats keeps topics usable and new replies visible',
    () async {
      server.records.addAll([
        node('t', 'root', '目录', topic: true),
        node('old', 't', '同名回信'),
        node('daily', 'root', '日常消息'),
      ]);
      await engine.run();
      server.hashes['old'] = 'edited';
      server.records.lastWhere((r) => r['fileId'] == 'old')['version'] = 2;
      await engine.run();
      final pending = await engine.enqueue('待发', topicId: 't');
      final other = Store(db, 'other');
      await other.put((await store.get(pending))!);
      await store.lock('sync');
      expect(await store.clearHistory(), false);
      await store.unlock('sync');
      expect(await store.clearHistory(), true);
      expect((await store.visibleMessages()).single.remoteId, 't');
      expect((await store.get(pending))!.status, 'cancelled');
      expect((await store.messages()).where((m) => m.unread), isEmpty);
      expect((await other.visibleMessages()).single.status, 'queued');
      server.records.add(node('new', 't', '同名回信'));
      expect((await engine.run()).incoming, 1);
      expect(
        (await store.visibleMessages()).map((m) => m.remoteId),
        unorderedEquals(['t', 'new']),
      );
      expect(server.noteWrites, 0);
    },
  );

  test(
    'Same clean title creates distinct notes; legacy pending topic reconciles',
    () async {
      final topic = await engine.enqueue('旧目录', topic: true);
      server.records.add(
        node(topic, 'root', '爸爸：旧目录【JS1:$topic】', topic: true),
      );
      final a = await engine.enqueue('一起看', topicId: topic);
      final b = await engine.enqueue('一起看', topicId: topic);
      await engine.run();
      expect(server.folderWrites, 0);
      expect(
        server.records
            .where((n) => n['fileName'] == '爸爸：一起看')
            .map((n) => n['fileId']),
        unorderedEquals([a, b]),
      );
      await engine.run();
      expect((await store.visibleMessages()).length, 3);
      expect((await store.get(topic))!.status, 'synced');
    },
  );

  test(
    'Local deletion hides source and revisions across sync without changing server',
    () async {
      server.records.add(node('child-note', 'root', '孩子的一条消息'));
      await engine.run();
      server.hashes['child-note'] = 'v2';
      server.records.last['version'] = 2;
      expect((await engine.run()).incoming, 1);
      final source = await remote('child-note');
      expect((await store.visibleMessages()).length, 2);
      expect(await store.hideMessage(source.id), MessageDeleteResult.deleted);
      expect(await store.visibleMessages(), isEmpty);
      expect((await store.messages()).every((m) => !m.unread), true);
      final reopened = Store(db, session.account);
      expect(await reopened.visibleMessages(), isEmpty);
      server.reads.clear();
      server.hashes['child-note'] = 'v3';
      server.records.last['version'] = 3;
      expect((await engine.run()).incoming, 0);
      expect(server.reads, isEmpty);
      expect(await store.visibleMessages(), isEmpty);
      expect(server.records.any((n) => n['fileId'] == 'child-note'), true);
      expect(server.noteWrites, 0);
      final other = Store(db, 'another-account');
      await other.put(source);
      expect((await other.visibleMessages()).single.text, source.text);
    },
  );

  test(
    'Deleting only an update leaves its note and permits future updates',
    () async {
      server.records.add(node('child-note', 'root', '可继续回复'));
      await engine.run();
      server.hashes['child-note'] = 'v2';
      server.records.last['version'] = 2;
      await engine.run();
      final update = (await store.messages()).singleWhere((m) => m.isUpdate);
      expect(await store.hideMessage(update.id), MessageDeleteResult.deleted);
      expect((await store.visibleMessages()).single.isUpdate, false);
      server.hashes['child-note'] = 'v3';
      server.records.last['version'] = 3;
      expect((await engine.run()).incoming, 1);
      final visible = await store.visibleMessages();
      expect(visible.length, 2);
      expect(visible.singleWhere((m) => m.isUpdate).id, isNot(update.id));
      expect((await engine.run()).incoming, 0);
    },
  );

  test('Deleting queued or uncertain messages cancels further sends', () async {
    final first = await engine.enqueue('还没发出');
    final second = await engine.enqueue('发送结果待核对');
    await store.put((await store.get(second))!.withStatus('uncertain'));
    for (final id in [first, second]) {
      expect(await store.hideMessage(id), MessageDeleteResult.deleted);
      expect((await store.get(id))!.status, 'cancelled');
    }
    await engine.run();
    expect(server.noteWrites, 0);
    expect(await store.visibleMessages(), isEmpty);
    // A previously lost response may arrive later; retain its server object,
    // but never resurrect the deleted local conversation entry.
    final old = (await store.get(second))!;
    server.records.add(node(second, 'root', letterTitle(old.role, old.text)));
    await engine.run();
    expect(await store.visibleMessages(), isEmpty);
    expect(server.noteWrites, 0);
  });

  test('Deletion respects sync lease and supports topics', () async {
    server.records.add(node('topic', 'root', '话题', topic: true));
    server.records.add(node('child-note', 'topic', '保留消息'));
    await engine.run();
    final source = await remote('child-note');
    expect(await store.lock('background-fixture'), true);
    expect(await store.hideMessage(source.id), MessageDeleteResult.busy);
    expect((await store.visibleMessages()).length, 2);
    await store.unlock('background-fixture');
    expect(await store.hideMessage('missing'), MessageDeleteResult.notFound);
    expect(await store.hideMessage(source.id), MessageDeleteResult.deleted);
    expect((await store.visibleMessages()).single.isTopic, true);
    expect(
      await store.hideMessage((await remote('topic')).id),
      MessageDeleteResult.deleted,
    );
    expect(await store.visibleMessages(), isEmpty);
  });

  test(
    'Deleting a topic hides nested content and future descendants without touching siblings',
    () async {
      server.records.addAll([
        node('topic', 'root', '待删除话题', topic: true),
        node('branch', 'topic', '子目录', topic: true),
        node('reply', 'branch', '子目录回复'),
        node('sibling', 'root', '保留话题', topic: true),
        node('keep', 'sibling', '保留消息'),
      ]);
      await engine.run();
      server.hashes['reply'] = 'edited';
      server.records.singleWhere((n) => n['fileId'] == 'reply')['version'] = 2;
      await engine.run();
      final pendingTopic = await engine.enqueue(
        '待发子目录',
        topicId: 'branch',
        topic: true,
      );
      final pendingReply = await engine.enqueue('待发回复', topicId: pendingTopic);
      expect(
        await store.hideMessage((await remote('topic')).id),
        MessageDeleteResult.deleted,
      );
      expect((await store.get(pendingTopic))!.status, 'cancelled');
      expect((await store.get(pendingReply))!.status, 'cancelled');
      expect((await store.messages()).where((m) => m.unread), isEmpty);
      expect((await store.visibleMessages()).map((m) => m.remoteId).toSet(), {
        'sibling',
        'keep',
      });
      server.records.addAll([
        node('new-branch', 'branch', '后来新增的目录', topic: true),
        node('new-reply', 'new-branch', '后来新增的消息'),
      ]);
      server.reads.clear();
      expect((await engine.run()).incoming, 0);
      expect(server.reads, isNot(contains('new-reply')));
      expect(
        (await Store(
          db,
          session.account,
        ).visibleMessages()).map((m) => m.remoteId).toSet(),
        {'sibling', 'keep'},
      );
      expect(server.records, hasLength(8)); // All server objects remain.
      expect(server.folderWrites, 0);
      expect(server.noteWrites, 0);
      // Moving a previously hidden descendant outside does not resurrect it.
      server.records.singleWhere((n) => n['fileId'] == 'reply')['parentId'] =
          'sibling';
      await engine.run();
      expect(
        (await store.visibleMessages()).any((m) => m.remoteId == 'reply'),
        false,
      );
    },
  );

  test('Deleting a queued topic cancels its whole local subtree', () async {
    final root = await engine.enqueue('还没上传的话题', topic: true);
    final branch = await engine.enqueue('分支', topicId: root, topic: true);
    final note = await engine.enqueue('待发内容', topicId: branch);
    expect(await store.hideMessage(root), MessageDeleteResult.deleted);
    await engine.run();
    for (final id in [root, branch, note]) {
      expect((await store.get(id))!.status, 'cancelled');
    }
    expect(await store.visibleMessages(), isEmpty);
    expect(server.folderWrites, 0);
    expect(server.noteWrites, 0);
  });

  test(
    'Distinct legacy and modern objects with the same title retain separate histories',
    () async {
      const id = '0123456789abcdef0123456789abcdef';
      final legacy = NativeNote.legacyFileId(id);
      const title = '妈妈：不同远端笔记【JS1:$id】';
      server.records.addAll([
        node(legacy, 'root', title),
        node(id, 'root', title),
      ]);
      server.hashes[legacy] = 'old-content';
      server.hashes[id] = 'new-content';
      await engine.run();
      expect((await store.messages()).length, 2);
      expect((await remote(legacy)).bodyDigest, 'old-content');
      expect((await remote(id)).bodyDigest, 'new-content');
      await engine.run();
      expect((await store.messages()).length, 2);
      expect((await store.messages()).every((m) => m.role == 'mom'), true);
      expect(server.noteWrites, 0);
    },
  );

  test(
    'Folders open topics; all direct notes are independent sibling messages with their own author',
    () async {
      const parent = '0123456789abcdef0123456789abcdef';
      const mom = '1123456789abcdef0123456789abcdef';
      server.records.addAll([
        node(parent, 'root', letterTitle('dad', '今天怎么样'), topic: true),
        node('child-1', parent, '数学考了95分'),
        node('child-2', parent, '最后一题不会'),
        node(NativeNote.fileId(mom), parent, letterTitle('mom', '晚上一起看')),
        node('branch', parent, '一起看错题', topic: true),
        node('child-3', 'branch', '解题过程'),
      ]);
      expect(
        (await engine.run()).incoming,
        0,
      ); // Upgrade baselines nested history.
      final view = TopicView(await store.messages());
      expect(view.children(parent).where((m) => !m.isTopic).length, 3);
      expect((await remote('child-1')).role, 'child');
      expect((await remote(NativeNote.fileId(mom))).role, 'mom');
      expect((await remote('child-3')).topicId, 'branch');
      expect(view.path('branch'), [parent, 'branch']);
      expect(view.children(''), hasLength(1));
    },
  );

  test(
    'New note alerts once; move is silent; resource edit appends one update event',
    () async {
      server.records.addAll([
        node('a', 'root', 'A', topic: true),
        node('b', 'root', 'B', topic: true),
      ]);
      await engine.run();
      server.records.add(node('reply', 'a', '新回信'));
      expect((await engine.run()).incoming, 1);
      expect((await engine.run()).incoming, 0);
      final original = await remote('reply');
      server.records.last['parentId'] = 'b';
      server.records.last['version'] = 2;
      expect((await engine.run()).incoming, 0);
      expect((await remote('reply')).id, original.id);
      expect((await remote('reply')).topicId, 'b');
      expect((await remote('reply')).edited, false);
      server.hashes['reply'] = 'changed-page-md5';
      await db.update(
        'messages',
        {'resourceCheckedAt': 0},
        where: 'id=?',
        whereArgs: [original.id],
      );
      expect((await engine.run()).incoming, 1);
      expect((await remote('reply')).edited, true);
      expect((await engine.run()).incoming, 0);
      expect(
        (await store.messages()).where((m) => m.remoteId == 'reply'),
        hasLength(2),
      );
    },
  );

  test(
    'Late preview remains the same message and a failed branch does not block others',
    () async {
      await engine.run();
      server.records.addAll([
        node('late', 'root', '页面稍后到达'),
        node('ready', 'root', '完整回信'),
      ]);
      server.failures.add('late');
      expect((await engine.run()).incoming, 2);
      expect((await remote('late')).images, isEmpty);
      expect((await remote('ready')).images, isNotEmpty);
      server.failures.clear();
      expect((await engine.run()).incoming, 0);
      expect((await remote('late')).images, isNotEmpty);
      expect((await remote('late')).edited, false);
    },
  );

  test(
    'Private traversal excludes shared branches, cycles, and children illegally attached to notes',
    () async {
      server.records.addAll([
        node('private', 'root', '我的话题', topic: true),
        node('own', 'private', '我的回信'),
        node('shared', 'root', '共享目录', topic: true, shared: true),
        node('hidden', 'shared', '不应读取'),
        node('outside', '0', '学习资料'),
        node('bad', 'own', '笔记不是容器'),
        node('cycle-a', 'cycle-b', 'A', topic: true),
        node('cycle-b', 'cycle-a', 'B', topic: true),
      ]);
      await engine.run();
      expect(server.reads, ['own']);
      server.records.firstWhere((r) => r['fileId'] == 'private')['parentId'] =
          '0';
      await engine.run();
      expect((await remote('own')).deleted, true);
      expect((await remote('private')).deleted, true);
      expect(
        (await store.messages()).any((m) => m.remoteId == 'hidden'),
        false,
      );
    },
  );

  test(
    'Offline parent, branch and peer messages publish under exactly the intended folders',
    () async {
      final parent = await engine.enqueue('新话题', topic: true);
      final branch = await engine.enqueue('分支', topicId: parent, topic: true);
      final first = await engine.enqueue('第一条', topicId: branch);
      final second = await engine.enqueue('第二条', topicId: branch);
      expect((await engine.run()).status, '同步完成');
      expect(server.folderWrites, 2);
      expect(server.noteWrites, 2);
      expect(
        server.records.singleWhere((n) => n['fileId'] == branch)['parentId'],
        parent,
      );
      for (final id in [first, second]) {
        expect(
          server.records.singleWhere(
            (n) => n['fileId'] == NativeNote.fileId(id),
          )['parentId'],
          branch,
        );
        expect((await store.get(id))!.status, 'synced');
      }
    },
  );

  test(
    'Lost topic-create response is reconciled before sending queued children',
    () async {
      server.loseFolderResponse = true;
      final parent = await engine.enqueue('话题', topic: true);
      await engine.enqueue('话题内的消息', topicId: parent);
      await engine.run();
      expect(server.folderWrites, 1);
      expect(server.noteWrites, 0);
      expect((await engine.run()).status, '同步完成');
      expect(server.folderWrites, 1);
      expect(server.noteWrites, 1);
    },
  );

  test(
    'A disappeared destination blocks a queued message instead of sending it at the root',
    () async {
      server.records.add(node('a', 'root', '话题', topic: true));
      await engine.run();
      final draft = await engine.enqueue('不要发送到别处', topicId: 'a');
      server.records.removeWhere((n) => n['fileId'] == 'a');
      await engine.run();
      expect((await store.get(draft))!.status, 'conflict');
      expect(server.noteWrites, 0);
    },
  );

  test(
    'Parent note continuation appends unread updates without duplicates or false authorship',
    () async {
      await engine.run();
      final id = await engine.enqueue('请在这里续写');
      expect((await engine.run()).incoming, 0);
      final fid = NativeNote.fileId(id);
      final original = await remote(fid);
      server.hashes[fid] = 'reply-v2';
      server.records.last['version'] = 2;
      expect((await engine.run()).incoming, 1);
      var events = (await store.messages()).where((m) => m.isUpdate).toList();
      expect(events, hasLength(1));
      expect(events.single.unread, true);
      expect(events.single.role, 'update');
      expect(events.single.remoteId, fid);
      expect(events.single.topicId, original.topicId);
      expect((await remote(fid)).role, 'dad');
      expect((await remote(fid)).id, original.id);
      expect((await remote(fid)).time, original.time);
      await store.markRead(topicId: '');
      expect((await engine.run()).incoming, 0);
      expect((await store.get(events.single.id))!.unread, false);
      // Rename with unchanged resource content is not a continuation.
      server.records.last['fileName'] = letterTitle('dad', '改个标题');
      server.records.last['version'] = 3;
      expect((await engine.run()).incoming, 0);
      // Editing back to an earlier body is still a new observed change.
      server.hashes[fid] = 'v1';
      server.records.last['version'] = 4;
      expect((await engine.run()).incoming, 1);
      events = (await store.messages()).where((m) => m.isUpdate).toList();
      expect(events, hasLength(2));
      expect(events.where((m) => m.unread), hasLength(1));
      expect((await engine.run()).incoming, 0);
    },
  );

  test(
    'Upgrade establishes body baseline silently, then detects a resource-only continuation',
    () async {
      server.records.add(node('legacy', 'root', '旧笔记'));
      await engine.run();
      await db.update(
        'messages',
        {'bodyDigest': '', 'resourceCheckedAt': 0},
        where: 'remoteId=?',
        whereArgs: ['legacy'],
      );
      server.hashes['legacy'] = 'first-seen-after-upgrade';
      expect((await engine.run()).incoming, 0);
      expect((await store.messages()).where((m) => m.isUpdate), isEmpty);
      server.hashes['legacy'] = 'new-writing';
      await db.update(
        'messages',
        {'resourceCheckedAt': DateTime.now().millisecondsSinceEpoch - 61000},
        where: 'remoteId=?',
        whereArgs: ['legacy'],
      );
      expect((await engine.run()).incoming, 1);
      expect((await store.messages()).where((m) => m.isUpdate), hasLength(1));
      expect((await engine.run()).incoming, 0);
    },
  );

  test(
    'Marking one topic read preserves unread messages in another branch',
    () async {
      for (final (id, parent) in [('one', 'a'), ('two', 'b')]) {
        await store.ingest(
          Message(
            id: id,
            role: 'child',
            text: id,
            time: 1,
            topicId: parent,
            remoteId: id,
            contentVersion: 'v1',
          ),
          baseline: false,
          readerRole: 'dad',
        );
      }
      await store.markRead(topicId: 'a');
      expect((await store.get('one'))!.unread, false);
      expect((await store.get('two'))!.unread, true);
    },
  );

  test(
    'Database migration retains old chat text, unread state and pending sends',
    () async {
      final old = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await old.execute(
          'CREATE TABLE messages(account TEXT,id TEXT,role TEXT,body TEXT,time INTEGER,status TEXT,source TEXT,version TEXT,unread INTEGER,images TEXT,PRIMARY KEY(account,id))',
        );
        await old.insert('messages', {
          'account': session.account,
          'id': 'old-id',
          'role': 'dad',
          'body': '旧版待发消息',
          'time': 1,
          'status': 'queued',
          'source': '云笔记',
          'version': '',
          'unread': 1,
          'images': '[]',
        });
        await Store.upgradeTopics(old);
        final m = (await Store(old, session.account).messages()).single;
        expect(m.text, '旧版待发消息');
        expect(m.status, 'queued');
        expect(m.unread, true);
        expect(m.topicId, '');
        expect(m.kind, 'note');
      } finally {
        await old.close();
      }
    },
  );
}
