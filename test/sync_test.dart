import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:jiashu/api.dart';
import 'package:jiashu/data.dart';
import 'package:jiashu/protocol.dart';
import 'package:jiashu/sync.dart';
import 'package:jiashu/native_note.dart';
import 'package:jiashu/note_edit.dart';
import 'native_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }
  late Database db;
  late Store store;
  final session = Session(
    school: 'test',
    username: 'fixture',
    role: 'dad',
    base: 'https://test.zykj.org',
    token: 'fixture-token',
    client: 'fixture',
    userId: '123',
  );
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE messages(account TEXT,id TEXT,role TEXT,body TEXT,time INTEGER,status TEXT,source TEXT,version TEXT,unread INTEGER,images TEXT,PRIMARY KEY(account,id))',
    );
    await db.execute(
      'CREATE TABLE settings(account TEXT,k TEXT,v TEXT,PRIMARY KEY(account,k))',
    );
    store = Store(db, session.account);
    await Store.upgradeTopics(db);
  });
  tearDown(() async {
    await db.close();
  });
  Message child(String version) => Message(
    id: 'a',
    role: 'child',
    text: '孩子回信',
    time: 1,
    version: version,
    contentVersion: version,
    bodyDigest: version,
  );
  test('Baseline is silent; changed child messages alert once', () async {
    expect(
      await store.ingest(child('v1'), baseline: true, readerRole: 'dad'),
      false,
    );
    expect(
      await store.ingest(child('v1'), baseline: false, readerRole: 'dad'),
      false,
    );
    expect(
      await store.ingest(child('v2'), baseline: false, readerRole: 'dad'),
      true,
    );
    expect(
      (await store.messages()).singleWhere((m) => m.isUpdate).unread,
      true,
    );
    expect(
      await store.ingest(child('v2'), baseline: false, readerRole: 'dad'),
      false,
    );
    await store.markRead();
    expect((await store.get('a'))!.unread, false);
  });
  test(
    'Every other sender is unread once, own messages and baseline stay quiet',
    () async {
      for (final reader in ['dad', 'mom']) {
        for (final sender in ['dad', 'mom', 'child']) {
          final m = Message(
            id: '$reader-$sender',
            role: sender,
            text: '你好',
            time: 1,
          );
          expect(
            await store.ingest(m, baseline: false, readerRole: reader),
            sender != reader,
          );
          expect((await store.get(m.id))!.unread, sender != reader);
          await store.markMessageRead(m.id);
          expect(
            await store.ingest(m, baseline: false, readerRole: reader),
            false,
          );
          expect((await store.get(m.id))!.unread, false);
        }
      }
      final other = Store(db, 'another:123');
      expect(await other.messages(), isEmpty);
      await other.put(child('v1'));
      expect(await store.get('a'), isNull);
    },
  );
  test('Lease rejects competing foreground/background sync', () async {
    expect(await store.lock('fg'), true);
    expect(await store.lock('bg'), false);
    await store.unlock('wrong');
    expect(await store.lock('bg'), false);
    await store.unlock('fg');
    expect(await store.lock('bg'), true);
  });
  test(
    'Lost send response reconciles by ID without duplicate mutation',
    () async {
      final fixture = NativeFixture()..loseFinalResponse = true;
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      await engine.enqueue('吃饭了吗');
      await engine.run();
      expect((await store.messages()).single.status, 'uncertain');
      await engine.run();
      expect(fixture.registrations, 2);
      expect(fixture.tokens, 1);
      expect(fixture.order, [
        ...List.filled(9, 'put'),
        'resources',
        'note',
        'note',
      ]);
      expect(fixture.notes.last['version'], 1);
      expect(fixture.notes.last['fileName'], '爸爸：吃饭了吗');
      expect((await store.messages()).single.status, 'synced');
      expect((await store.messages()).single.unread, false);
      expect((await store.messages()).single.images, hasLength(1));
      // Another parent's installation reads the same native note, not a child message.
      final otherDb = Store(db, 'fresh-install');
      final other = SyncEngine(session, otherDb, apiFactory: fixture.api);
      expect((await other.run()).incoming, 0);
      expect((await otherDb.messages()).single.role, 'dad');
      expect(fixture.registrations, 2);
    },
  );
  test(
    'Interrupted asset upload retries one stable note and resource set',
    () async {
      final fixture = NativeFixture()..failOneUpload = true;
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      await engine.enqueue('测试上传中断');
      await engine.run();
      expect(fixture.registrations, 0);
      expect(fixture.resources, isEmpty);
      expect((await store.messages()).single.status, 'uncertain');
      expect((await engine.run()).status, '同步完成');
      expect(fixture.registrations, 2);
      expect(fixture.objects, hasLength(9));
      expect((await store.messages()).single.status, 'synced');
    },
  );
  test('Lost publication response recovers without a third write', () async {
    final fixture = NativeFixture()..losePublicationResponse = true;
    await store.set('folder', 'root');
    final engine = SyncEngine(session, store, apiFactory: fixture.api);
    await engine.enqueue('补登记响应丢失');
    await engine.run();
    expect((await store.messages()).single.status, 'uncertain');
    expect(fixture.notes.last['version'], 1);
    await engine.run();
    expect((await store.messages()).single.status, 'synced');
    expect(fixture.registrations, 2);
    expect(fixture.tokens, 1);
    expect(fixture.objects.length, 9);
  });
  test(
    'Next sync finishes an interrupted page edit after restarting the app',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      final id = await engine.enqueue('标题保持');
      await engine.run();
      final original = (await store.get(id))!;
      final image = fixture.objects[Uri.parse(original.images.single).path]!;
      fixture.loseResourceResponse = true;
      final edited = Uint8List.fromList([...image, 0]);
      await expectLater(
        NotePageEdit(
          original,
          original.images.single,
          image,
        ).save(session, store, edited, apiFactory: fixture.api),
        throwsA(isA<http.ClientException>()),
      );
      expect(await store.pendingPageEdits(), hasLength(1));
      expect(fixture.notes.last['version'], 1);
      final uploads = fixture.tokens;
      final restarted = Store(db, session.account);
      expect(
        (await SyncEngine(
          session,
          restarted,
          apiFactory: fixture.api,
        ).run()).incoming,
        0,
      );
      expect(await restarted.pendingPageEdits(), isEmpty);
      expect(fixture.notes.last['version'], 2);
      expect(fixture.notes.last['fileName'], '爸爸：标题保持');
      expect(fixture.tokens, uploads);
    },
  );
  test(
    'Queued revisions survive a lost response and a retry uploads the latest local page',
    () async {
      final server = NativeFixture();
      await store.set('folder', 'root');
      final sync = SyncEngine(session, store, apiFactory: server.api);
      final id = await sync.enqueue('连续修改');
      await sync.run();
      final note = (await store.get(id))!;
      final original = server.objects[Uri.parse(note.images.single).path]!;
      final first = Uint8List.fromList([1, 2, 3]);
      final second = Uint8List.fromList([4, 5, 6]);
      await store.queuePage(
        note,
        0,
        md5.convert(original).toString(),
        null,
        first,
      );
      final revision = (await store.localPage(note, 0))!.revision;
      server.loseResourceResponse = true;
      await sync.run();
      expect(await store.pendingPageEdits(), hasLength(1));
      await store.queuePage(
        note,
        0,
        md5.convert(first).toString(),
        revision,
        second,
      );
      final restart = Store(db, session.account);
      expect((await restart.localPage(note, 0))!.bytes, second);
      await SyncEngine(session, restart, apiFactory: server.api).run();
      expect(await restart.queuedPages(), isEmpty);
      final saved = (await restart.get(id))!;
      expect(server.objects[Uri.parse(saved.images.single).path], second);
      expect((await restart.localPage(saved, 0))!.pending, isFalse);
      expect(server.tokens, 3); // Original plus two distinct saves.
    },
  );

  test(
    'A cloud conflict preserves the local page without overwriting the other edit',
    () async {
      final server = NativeFixture();
      await store.set('folder', 'root');
      final sync = SyncEngine(session, store, apiFactory: server.api);
      final id = await sync.enqueue('云端同时修改');
      await sync.run();
      final note = (await store.get(id))!;
      final bytes = Uint8List.fromList([3, 2, 1]);
      final original = server.objects[Uri.parse(note.images.single).path]!;
      await store.queuePage(
        note,
        0,
        md5.convert(original).toString(),
        null,
        bytes,
      );
      server.resources.first['md5'] = 'changed remotely';
      final writes = server.tokens;
      await sync.run();
      final kept = (await store.localPage(note, 0))!;
      expect(kept.bytes, bytes);
      expect(kept.error, contains('已被修改'));
      expect(server.tokens, writes);
      await store.clearHistory();
      expect(await store.queuedPages(), isEmpty);
    },
  );

  test(
    'Edit the second page of a child note and reconcile a lost save response',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      final id = await engine.enqueue('原名');
      await engine.run();
      final originalRows = fixture.resources
          .map(Map<String, dynamic>.from)
          .toList();
      fixture.notes.last['fileName'] = '孩子的笔记';
      final preview = Map<String, dynamic>.from(
        originalRows.singleWhere((r) => r['resourceType'] == 2),
      );
      final oldUrl = Uri.parse(preview['ossImageUrl']);
      final newUrl = oldUrl.replace(path: '/second-page/preview.png');
      final image = fixture.objects[oldUrl.path]!;
      preview.addAll({
        'id': 'second/preview.png',
        'pageName': 'second',
        'pageIndex': 1,
        'ossImageUrl': newUrl.toString(),
      });
      fixture.resources.addAll([
        preview,
        {...preview, 'id': 'second/ink.bin', 'resourceType': 1},
      ]);
      await engine.run();
      final child = (await store.get(id))!;
      expect(child.role, 'child');
      final edit = NotePageEdit(child, child.images[1], image);
      final png = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pGQAAAAASUVORK5CYII=',
        ),
      );
      fixture.losePublicationResponse = true;
      await expectLater(
        edit.save(session, store, png, apiFactory: fixture.api),
        throwsA(isA<http.ClientException>()),
      );
      final writes = List.of(fixture.order);
      fixture.stalePreview = true;
      await expectLater(
        edit.save(session, store, png, apiFactory: fixture.api),
        throwsA(isA<ApiFailure>()),
      );
      expect((await store.get(id))!.images, child.images);
      fixture.stalePreview = false;
      await edit.save(session, store, png, apiFactory: fixture.api);
      expect(fixture.order, writes);
      final reopened = (await Store(db, session.account).get(id))!;
      expect(reopened.images.first, child.images.first);
      expect(reopened.images[1], isNot(child.images[1]));
      expect(fixture.objects[Uri.parse(reopened.images[1]).path], png);
      expect(fixture.notes.last['fileName'], '孩子的笔记');
      expect(fixture.notes.last['parentId'], 'root');
      expect(fixture.notes.last['fileId'], id);
      expect(fixture.resources.where((r) => r['pageIndex'] == 0), originalRows);
      final second = fixture.resources.where(
        (r) => r['pageIndex'] == 1 && r['wasDeleted'] != true,
      );
      expect(second.length, 9);
      for (final r in second.where((r) => [0, 2].contains(r['resourceType']))) {
        expect(fixture.objects[Uri.parse(r['ossImageUrl']).path], png);
      }
      await engine.run();
      expect((await store.get(id))!.images.length, 2);
      await expectLater(
        NotePageEdit(
          child,
          child.images[1],
          image,
        ).save(session, store, png, apiFactory: fixture.api),
        throwsA(isA<ApiFailure>()),
      );
      expect(fixture.order, writes);
    },
  );
  test(
    'Rejected publication stays pending and retries only the index',
    () async {
      final fixture = NativeFixture()..rejectPublication = true;
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      await engine.enqueue('补登记待确认');
      await engine.run();
      await engine.run();
      expect((await store.messages()).single.status, 'uncertain');
      expect(fixture.notes.last['version'], 0);
      fixture.rejectPublication = false;
      await engine.run();
      expect((await store.messages()).single.status, 'synced');
      expect(fixture.notes.last['version'], 1);
      expect(fixture.tokens, 1);
      expect(fixture.order.where((v) => v == 'put').length, 9);
    },
  );
  test(
    'Existing version zero own note repairs silently; child notes stay untouched',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      await engine.enqueue('旧版本已保存消息');
      await engine.run();
      fixture.notes.last['version'] = 0; // Old app had accepted this as synced.
      fixture.notes.add({
        'fileId': 'child-note',
        'parentId': 'root',
        'fileName': '孩子的原笔记',
        'type': 12,
        'shared': false,
        'version': 0,
      });
      await engine.run();
      expect(fixture.registrations, 3);
      expect(
        fixture.notes.singleWhere(
          (n) => n['fileId'] != 'root' && n['fileId'] != 'child-note',
        )['version'],
        1,
      );
      expect(
        fixture.notes.singleWhere(
          (n) => n['fileId'] == 'child-note',
        )['version'],
        0,
      );
      expect((await store.messages()).where((m) => m.isUpdate), isEmpty);
      await engine.run();
      expect(fixture.registrations, 3);
    },
  );
  test(
    'Re-read refuses to overwrite a moved, renamed or shared note',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      await engine.enqueue('核对并发修改');
      await engine.run();
      final expected = Map<String, dynamic>.from(fixture.notes.last)
        ..['version'] = 0;
      for (final change in [
        {'fileName': '孩子重命名'},
        {'parentId': 'other-folder'},
        {'fileUrl': 'https://ezy-test.oss-cn-hangzhou.aliyuncs.com/changed'},
        {'shared': true},
        {'isRecycleBin': true},
        {'version': null},
      ]) {
        fixture.notes.last
          ..clear()
          ..addAll(expected)
          ..addAll(change);
        final api = fixture.api(session);
        await expectLater(
          api.publishNativeNote(expected),
          throwsA(isA<ApiFailure>()),
        );
        api.close();
      }
      expect(fixture.registrations, 2);
    },
  );
  test(
    'Another client already published the note; do not write again',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      await engine.enqueue('核对已有版本');
      await engine.run();
      final expected = Map<String, dynamic>.from(fixture.notes.last)
        ..['version'] = 0;
      final api = fixture.api(session);
      expect((await api.publishNativeNote(expected))['version'], 1);
      api.close();
      expect(fixture.registrations, 2);
    },
  );
  test('Publication requires a confirmed higher version on readback', () async {
    final fixture = NativeFixture()..rejectPublication = true;
    await store.set('folder', 'root');
    final engine = SyncEngine(session, store, apiFactory: fixture.api);
    await engine.enqueue('核对服务器版本');
    await engine.run();
    fixture.rejectPublication = false;
    fixture.beforeNoteRead = () {
      fixture.notes.last['version'] = 0;
    };
    await engine.run();
    expect((await store.messages()).single.status, 'uncertain');
    expect(fixture.tokens, 1);
  });
  test(
    'Upgrade unsent legacy ID once; lost response reuses the new ID',
    () async {
      final fixture = NativeFixture()..loseFinalResponse = true;
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      final id = await engine.enqueue('升级前的待发送消息');
      final queued = (await store.get(id))!;
      await store.put(
        Message.fromRow({
          ...queued.row(session.account),
          'remoteId': NativeNote.legacyFileId(id),
        }),
      );
      await engine.run();
      expect((await store.get(id))!.remoteId, id);
      expect((await store.get(id))!.status, 'uncertain');
      expect(fixture.notes.last['fileId'], id);
      await engine.run();
      expect((await store.get(id))!.status, 'synced');
      expect((await store.messages()).length, 1);
      expect(fixture.tokens, 1);
      expect(fixture.registrations, 2);
    },
  );
  test(
    'Registered legacy note stays readable without replacement or publication',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      final id = await engine.enqueue('已登记的历史消息');
      await engine.run();
      final legacy = NativeNote.legacyFileId(id);
      fixture.notes.last
        ..['fileId'] = legacy
        ..['fileName'] = '爸爸：已登记的历史消息【JS1:$id】'
        ..['version'] = 0;
      for (final r in fixture.resources) {
        r['fileId'] = legacy;
      }
      final original = (await store.get(id))!;
      await store.put(
        Message.fromRow({...original.row(session.account), 'remoteId': legacy}),
      );
      await engine.run();
      expect((await store.get(id))!.remoteId, legacy);
      expect((await store.messages()).length, 1);
      final freshStore = Store(db, 'fresh-install-legacy');
      expect(
        (await SyncEngine(
          session,
          freshStore,
          apiFactory: fixture.api,
        ).run()).incoming,
        0,
      );
      expect((await freshStore.messages()).single.role, 'dad');
      expect((await freshStore.messages()).single.remoteId, legacy);
      expect(fixture.registrations, 2);
      expect(fixture.tokens, 1);
      expect(fixture.notes.last['version'], 0);
    },
  );
  test(
    'Legacy ID registered outside the private tree cannot create a replacement',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      final id = await engine.enqueue('旧编号冲突');
      final legacy = NativeNote.legacyFileId(id);
      final queued = (await store.get(id))!;
      await store.put(
        Message.fromRow({...queued.row(session.account), 'remoteId': legacy}),
      );
      fixture.notes.add({
        'fileId': legacy,
        'parentId': 'elsewhere',
        'type': 12,
        'fileName': letterTitle('dad', queued.text),
        'shared': false,
        'version': 0,
      });
      await engine.run();
      expect((await store.get(id))!.status, 'conflict');
      expect(fixture.tokens, 0);
      expect(fixture.registrations, 0);
    },
  );
  test(
    'Recycled legacy note cannot be resurrected by the ID upgrade',
    () async {
      final fixture = NativeFixture();
      await store.set('folder', 'root');
      final engine = SyncEngine(session, store, apiFactory: fixture.api);
      final id = await engine.enqueue('已删除的旧消息');
      final queued = (await store.get(id))!;
      final legacy = NativeNote.legacyFileId(id);
      await store.put(
        Message.fromRow({
          ...queued.row(session.account),
          'remoteId': legacy,
          'status': 'uncertain',
        }),
      );
      fixture.notes.add({
        'fileId': legacy,
        'parentId': 'root',
        'fileName': letterTitle('dad', queued.text),
        'type': 12,
        'version': 1,
        'shared': false,
        'isRecycleBin': true,
      });
      await engine.run();
      expect((await store.get(id))!.status, 'conflict');
      expect(fixture.registrations, 0);
      expect(fixture.tokens, 0);
    },
  );
  test('Denied or foreign account cannot cause any writes', () async {
    for (final denied in [true, false]) {
      var posts = 0;
      final engine = SyncEngine(
        session,
        store,
        apiFactory: (s) => SchoolApi(
          s,
          client: MockClient((r) async {
            if (r.method == 'POST') posts++;
            return denied
                ? http.Response('{}', 403)
                : http.Response(
                    jsonEncode({
                      'code': 0,
                      'data': NotesCodec().encode(
                        jsonEncode({'userId': '999', 'noteList': []}),
                      ),
                    }),
                    200,
                  );
          }),
        ),
      );
      await engine.enqueue('你好');
      await engine.run();
      expect(posts, 0);
      expect(await store.setting('lastSync'), null);
    }
  });
  test('Column send is blocked until audience is verified', () async {
    var calls = 0;
    final api = SchoolApi(
      session,
      client: MockClient((r) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      ColumnsAdapter(api).send(1, '家书', audienceVerified: false),
      throwsA(isA<ApiFailure>()),
    );
    expect(calls, 0);
    api.close();
  });
}
