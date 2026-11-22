import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class Session {
  final String school, username, role, base, token, client, userId;
  String folder;
  String loginId;
  Session({
    required this.school,
    required this.username,
    required this.role,
    required this.base,
    required this.token,
    required this.client,
    required this.userId,
    this.folder = '',
    this.loginId = '',
  });
  String get account => '$school:$userId';
  String get roleName => role == 'dad' ? '爸爸' : '妈妈';
  Map<String, dynamic> toJson() => {
    'school': school,
    'username': username,
    'role': role,
    'base': base,
    'token': token,
    'client': client,
    'userId': userId,
    'folder': folder,
    'loginId': loginId,
  };
  factory Session.fromJson(Map<String, dynamic> j) => Session(
    school: j['school'],
    username: j['username'],
    role: j['role'],
    base: j['base'],
    token: j['token'],
    client: j['client'],
    userId: j['userId'],
    folder: j['folder'] ?? '',
    loginId: j['loginId'] ?? '',
  );
}

class SavedLogin {
  final Session session;
  final String? password;
  final bool allowHttp;
  SavedLogin(this.session, this.password, this.allowHttp);
}

class Vault {
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static Future<Session?> read() async {
    final raw = await storage.read(key: 'session');
    return raw == null ? null : Session.fromJson(jsonDecode(raw));
  }

  static Future<SavedLogin?> readLogin() async {
    final raw = await storage.read(key: 'session');
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return SavedLogin(
      Session.fromJson(j),
      j['savedPassword'] as String?,
      j['allowHttp'] == true,
    );
  }

  static Future<Map<String, dynamic>?> readForm() async {
    final raw = await storage.read(key: 'loginForm');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  static Future<void> rememberForm(
    String school,
    String username,
    String role,
    String? password,
    bool allowHttp,
  ) => storage.write(
    key: 'loginForm',
    value: jsonEncode({
      'school': school,
      'username': username,
      'role': role,
      'password': password,
      'allowHttp': allowHttp,
    }),
  );

  static Future<void> forgetForm() => _writeLocked(
    () => storage.write(key: 'loginForm', value: '{"remember":false}'),
  );

  // Serialize secure-storage mutations across foreground/background engines.
  // SQLite contains only an empty lock table, never credentials or tokens.
  static Future<T> _writeLocked<T>(Future<T> Function() action) async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'jiashu_vault_lock.db'),
      version: 1,
      onCreate: (db, _) =>
          db.execute('CREATE TABLE vault_mutex(id INTEGER PRIMARY KEY)'),
    );
    return db.transaction((_) => action(), exclusive: true);
  }

  static Future<void> save(
    Session s, {
    String? password,
    bool allowHttp = false,
    bool remember = true,
  }) => _writeLocked(() async {
    s.loginId = const Uuid().v4();
    await storage.write(
      key: 'session',
      value: jsonEncode({
        ...s.toJson(),
        'savedPassword': remember ? password : null,
        'allowHttp': allowHttp,
      }),
    );
  });

  static Future<bool> replaceSession(String loginId, Session refreshed) =>
      _writeLocked(() async {
        final saved = await readLogin();
        if (saved == null ||
            saved.session.loginId != loginId ||
            saved.session.account != refreshed.account) {
          return false;
        }
        refreshed.loginId = loginId;
        await storage.write(
          key: 'session',
          value: jsonEncode({
            ...refreshed.toJson(),
            'savedPassword': saved.password,
            'allowHttp': saved.allowHttp,
          }),
        );
        return true;
      });
  static Future<void> clear() => _writeLocked(() async {
    // Migrate existing installations before signing out for the first time.
    if (await readForm() == null) {
      final saved = await readLogin();
      if (saved != null) {
        await rememberForm(
          saved.session.school,
          saved.session.username,
          saved.session.role,
          saved.password,
          saved.allowHttp,
        );
      }
    }
    await storage.delete(key: 'session');
  });
}

class Message {
  final String id, role, text, status, source, version;
  final String kind, remoteId, topicId, contentVersion, bodyDigest;
  final int time, resourceCheckedAt;
  final bool unread, deleted, edited;
  final List<String> images;
  Message({
    required this.id,
    required this.role,
    required this.text,
    required this.time,
    this.status = 'synced',
    this.source = '云笔记',
    this.version = '',
    this.unread = false,
    this.images = const [],
    this.kind = 'note',
    this.remoteId = '',
    this.topicId = '',
    this.contentVersion = '',
    this.bodyDigest = '',
    this.resourceCheckedAt = 0,
    this.deleted = false,
    this.edited = false,
  });
  bool get canEdit =>
      kind == 'note' && !deleted && status == 'synced' && images.isNotEmpty;
  bool get isTopic => kind == 'topic';
  bool get isUpdate => kind == 'update';
  Message withStatus(String value) => Message(
    id: id,
    role: role,
    text: text,
    time: time,
    status: value,
    source: source,
    version: version,
    unread: unread,
    images: images,
    kind: kind,
    remoteId: remoteId,
    topicId: topicId,
    contentVersion: contentVersion,
    bodyDigest: bodyDigest,
    resourceCheckedAt: resourceCheckedAt,
    deleted: deleted,
    edited: edited,
  );
  Map<String, Object?> row(String account) => {
    'account': account,
    'id': id,
    'role': role,
    'body': text,
    'time': time,
    'status': status,
    'source': source,
    'version': version,
    'unread': unread ? 1 : 0,
    'images': jsonEncode(images),
    'kind': kind,
    'remoteId': remoteId,
    'topicId': topicId,
    'contentVersion': contentVersion,
    'bodyDigest': bodyDigest,
    'resourceCheckedAt': resourceCheckedAt,
    'deleted': deleted ? 1 : 0,
    'edited': edited ? 1 : 0,
  };
  factory Message.fromRow(Map<String, Object?> r) => Message(
    id: r['id'] as String,
    role: r['role'] as String,
    text: r['body'] as String,
    time: r['time'] as int,
    status: r['status'] as String,
    source: r['source'] as String,
    version: r['version'] as String,
    unread: r['unread'] == 1,
    images: List<String>.from(jsonDecode(r['images'] as String)),
    kind: r['kind'] as String? ?? 'note',
    remoteId: r['remoteId'] as String? ?? '',
    topicId: r['topicId'] as String? ?? '',
    contentVersion: r['contentVersion'] as String? ?? '',
    bodyDigest: r['bodyDigest'] as String? ?? '',
    resourceCheckedAt: r['resourceCheckedAt'] as int? ?? 0,
    deleted: r['deleted'] == 1,
    edited: r['edited'] == 1,
  );
}

enum MessageDeleteResult { deleted, busy, notFound }

class LocalPage {
  final String revision;
  final Uint8List bytes;
  final bool pending;
  final String? error;
  const LocalPage(this.revision, this.bytes, this.pending, this.error);
}

class Store {
  final Database db;
  final String account;
  Store(this.db, this.account);
  static Future<Store> open(String account) async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'jiashu.db'),
      version: 4,
      onCreate: (db, v) async {
        await db.execute(
          'CREATE TABLE messages(account TEXT,id TEXT,role TEXT,body TEXT,time INTEGER,status TEXT,source TEXT,version TEXT,unread INTEGER,images TEXT,PRIMARY KEY(account,id))',
        );
        await db.execute(
          'CREATE TABLE settings(account TEXT,k TEXT,v TEXT,PRIMARY KEY(account,k))',
        );
        await upgradeTopics(db);
      },
      onUpgrade: (db, old, version) async {
        if (old < 2) await upgradeTopics(db);
        if (old == 2) await upgradeRevisions(db);
        if (old >= 2 && old < 4) await createPageEdits(db);
      },
    );
    return Store(db, account);
  }

  static Future<void> upgradeTopics(DatabaseExecutor db) async {
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
    await db.execute(
      'CREATE INDEX messages_topic ON messages(account,topicId)',
    );
    await upgradeRevisions(db);
    await createPageEdits(db);
  }

  static Future<void> upgradeRevisions(DatabaseExecutor db) => db.execute(
    "ALTER TABLE messages ADD COLUMN bodyDigest TEXT NOT NULL DEFAULT ''",
  );

  static Future<void> createPageEdits(DatabaseExecutor db) async {
    await db.execute("""
      CREATE TABLE page_edits(revision TEXT PRIMARY KEY, account TEXT NOT NULL,
        noteId TEXT NOT NULL, remoteId TEXT NOT NULL, topic TEXT NOT NULL,
        page INTEGER NOT NULL, baseUrl TEXT NOT NULL, baseMd5 TEXT NOT NULL,
        baseDigest TEXT NOT NULL, publishedDigest TEXT, predecessor TEXT, png BLOB NOT NULL, publishedUrl TEXT, error TEXT)
    """);
    await db.execute(
      'CREATE INDEX page_edits_by_note ON page_edits(account,noteId,page)',
    );
  }

  Future<void> queuePage(
    Message note,
    int index,
    String originalMd5,
    String? predecessor,
    Uint8List png,
  ) async {
    await db.transaction((tx) async {
      if (Store.isHidden(note, await hiddenMessages(tx))) {
        throw StateError('这份笔记已从本机移除');
      }
      // The editor may have stayed open while earlier local changes were confirmed.
      var baseDigest = note.bodyDigest;
      final published = await tx.query(
        'page_edits',
        columns: ['baseDigest', 'publishedDigest'],
        where: 'account=? AND noteId=? AND publishedDigest IS NOT NULL',
        whereArgs: [account, note.id],
        orderBy: 'rowid',
      );
      for (final prior in published) {
        if (prior['baseDigest'] == baseDigest) {
          baseDigest = prior['publishedDigest'] as String;
        }
      }
      await tx.insert('page_edits', {
        'revision': const Uuid().v4(),
        'account': account,
        'noteId': note.id,
        'remoteId': note.remoteId,
        'topic': note.topicId,
        'page': index,
        'baseUrl': note.images[index],
        'baseMd5': originalMd5,
        'baseDigest': baseDigest,
        'predecessor': predecessor,
        'png': png,
      });
    });
  }

  // A full-resolution PNG can exceed Android's SQLite CursorWindow size.
  Future<Uint8List> pageBytes(DatabaseExecutor tx, String revision) async {
    final result = BytesBuilder(copy: false);
    const chunk = 512 * 1024;
    while (true) {
      final rows = await tx.rawQuery(
        'SELECT substr(png,?,?) AS bytes FROM page_edits WHERE account=? AND revision=?',
        [result.length + 1, chunk, account, revision],
      );
      final bytes = rows.single['bytes'] as Uint8List;
      result.add(bytes);
      if (bytes.length < chunk) return result.takeBytes();
    }
  }

  Future<LocalPage?> localPage(Message note, int index) => db.transaction((
    tx,
  ) async {
    final rows = await tx.query(
      'page_edits',
      columns: ['revision', 'publishedUrl', 'error'],
      where:
          'account=? AND noteId=? AND page=? AND (publishedUrl IS NULL OR (publishedUrl=? AND publishedDigest=?))',
      whereArgs: [account, note.id, index, note.images[index], note.bodyDigest],
      orderBy: 'rowid DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single, revision = row['revision'] as String;
    return LocalPage(
      revision,
      await pageBytes(tx, revision),
      row['publishedUrl'] == null,
      row['error'] as String?,
    );
  });

  Future<String> editBaseDigest(String revision) async =>
      (await db.query(
            'page_edits',
            columns: ['baseDigest'],
            where: 'account=? AND revision=?',
            whereArgs: [account, revision],
          )).single['baseDigest']
          as String;

  Future<List<Map<String, Object?>>> queuedPages() => db.query(
    'page_edits',
    columns: [
      'revision',
      'noteId',
      'remoteId',
      'topic',
      'page',
      'baseUrl',
      'baseMd5',
      'predecessor',
    ],
    where: 'account=? AND publishedUrl IS NULL',
    whereArgs: [account],
    orderBy: 'rowid',
  );

  Future<List<Message>> messages() async => (await db.query(
    'messages',
    where: 'account=?',
    whereArgs: [account],
    orderBy: 'time ASC,id ASC',
  )).map(Message.fromRow).toList();
  Future<Message?> get(String id) async {
    final rows = await db.query(
      'messages',
      where: 'account=? AND id=?',
      whereArgs: [account, id],
    );
    return rows.isEmpty ? null : Message.fromRow(rows.first);
  }

  // Account-scoped local tombstones live in the existing settings table so
  // an upgrade preserves history without changing the database schema.
  Future<Set<String>> hiddenMessages([DatabaseExecutor? executor]) async =>
      (await (executor ?? db).query(
        'settings',
        columns: ['k'],
        where: 'account=? AND k LIKE ?',
        whereArgs: [account, 'hide:%'],
      )).map((r) => r['k'] as String).toSet();

  static bool isHidden(Message m, Set<String> keys) =>
      keys.contains('hide:id:${m.id}') ||
      (m.topicId.isNotEmpty && keys.contains('hide:topic:${m.topicId}')) ||
      (m.remoteId.isNotEmpty && keys.contains('hide:remote:${m.remoteId}'));

  Future<List<Message>> visibleMessages() async {
    final keys = await hiddenMessages();
    return (await messages()).where((m) => !isHidden(m, keys)).toList();
  }

  Future<bool> clearHistory() async {
    final lease = 'clear:${const Uuid().v4()}';
    if (!await lock(lease)) return false;
    try {
      await db.transaction((tx) async {
        await tx.delete('page_edits', where: 'account=?', whereArgs: [account]);
        await tx.rawInsert(
          """
          INSERT OR IGNORE INTO settings(account,k,v)
          SELECT account,'hide:id:' || id,'1' FROM messages
          WHERE account=? AND kind!='topic'
        """,
          [account],
        );
        await tx.rawInsert(
          """
          INSERT OR IGNORE INTO settings(account,k,v)
          SELECT account,'hide:remote:' || remoteId,'1' FROM messages
          WHERE account=? AND kind='note' AND remoteId!=''
        """,
          [account],
        );
        await tx.rawUpdate(
          """
          UPDATE messages SET unread=0, status=CASE
            WHEN kind!='topic' AND status IN ('queued','uncertain') THEN 'cancelled'
            ELSE status END WHERE account=?
        """,
          [account],
        );
      });
      return true;
    } finally {
      await unlock(lease);
    }
  }

  Future<MessageDeleteResult> hideMessage(String id) async {
    final lease = 'delete:${const Uuid().v4()}';
    if (!await lock(lease)) return MessageDeleteResult.busy;
    try {
      return await db.transaction((tx) async {
        final rows = await tx.query(
          'messages',
          where: 'account=? AND id=?',
          whereArgs: [account, id],
        );
        if (rows.isEmpty) return MessageDeleteResult.notFound;
        final m = Message.fromRow(rows.single);
        final all = (await tx.query(
          'messages',
          where: 'account=?',
          whereArgs: [account],
        )).map(Message.fromRow).toList();
        final topics = <String>{
          if (m.isTopic) m.remoteId.isEmpty ? m.id : m.remoteId,
        };
        var more = m.isTopic;
        while (more) {
          more = false;
          for (final child in all) {
            if (child.isTopic &&
                topics.contains(child.topicId) &&
                topics.add(
                  child.remoteId.isEmpty ? child.id : child.remoteId,
                )) {
              more = true;
            }
          }
        }
        final selected = all
            .where(
              (child) =>
                  child.id == id ||
                  topics.contains(child.topicId) ||
                  (!m.isUpdate &&
                      m.remoteId.isNotEmpty &&
                      child.remoteId == m.remoteId),
            )
            .toList();
        final sources = selected
            .where((child) => !child.isUpdate && child.remoteId.isNotEmpty)
            .map((child) => child.remoteId)
            .toSet();
        selected.addAll(
          all
              .where(
                (child) =>
                    child.isUpdate &&
                    sources.contains(child.remoteId) &&
                    !selected.any((picked) => picked.id == child.id),
              )
              .toList(),
        );
        final keys = <String>{for (final topic in topics) 'hide:topic:$topic'};
        for (final child in selected) {
          keys.add('hide:id:${child.id}');
          if (!child.isUpdate && child.remoteId.isNotEmpty) {
            keys.add('hide:remote:${child.remoteId}');
          }
        }
        for (final key in keys) {
          await tx.insert('settings', {
            'account': account,
            'k': key,
            'v': '1',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final child in selected) {
          await tx.delete(
            'page_edits',
            where: 'account=? AND noteId=?',
            whereArgs: [account, child.id],
          );
          await tx.rawUpdate(
            "UPDATE messages SET unread=0,status=CASE WHEN status IN ('queued','uncertain') THEN 'cancelled' ELSE status END WHERE account=? AND id=?",
            [account, child.id],
          );
        }
        return MessageDeleteResult.deleted;
      });
    } finally {
      await unlock(lease);
    }
  }

  Future<void> put(Message m) async {
    await db.insert(
      'messages',
      m.row(account),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> ingest(
    Message m, {
    required bool baseline,
    required String readerRole,
  }) async => db.transaction((tx) async {
    if (isHidden(m, await hiddenMessages(tx))) return false;
    final rows = await tx.query(
      'messages',
      where: 'account=? AND id=?',
      whereArgs: [account, m.id],
    );
    final old = rows.isEmpty ? null : Message.fromRow(rows.first);
    final changed =
        old != null &&
        old.contentVersion.isNotEmpty &&
        m.contentVersion.isNotEmpty &&
        old.contentVersion != m.contentVersion;
    final revision =
        !baseline &&
        !m.deleted &&
        m.kind == 'note' &&
        old?.status == 'synced' &&
        old!.bodyDigest.isNotEmpty &&
        m.bodyDigest.isNotEmpty &&
        old.bodyDigest != m.bodyDigest;
    final notify =
        m.role != readerRole &&
        !baseline &&
        !m.deleted &&
        (old == null || (changed && m.isTopic));
    final row = m.row(account);
    row['unread'] = m.role != readerRole && (notify || old?.unread == true)
        ? 1
        : 0;
    row['edited'] = changed || old?.edited == true ? 1 : 0;
    if (old != null) row['time'] = old.time;
    await tx.insert(
      'messages',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (revision) {
      await tx.insert(
        'messages',
        Message(
          id: 'update:${const Uuid().v4()}',
          role: 'update',
          text: '笔记有更新：${m.text}',
          time: DateTime.now().millisecondsSinceEpoch,
          kind: 'update',
          remoteId: m.remoteId,
          topicId: m.topicId,
          contentVersion: m.contentVersion,
          bodyDigest: m.bodyDigest,
          unread: true,
        ).row(account),
      );
    }
    return notify || revision;
  });
  Future<void> markMessageRead(String id) async {
    await db.update(
      'messages',
      {'unread': 0},
      where: 'account=? AND id=?',
      whereArgs: [account, id],
    );
  }

  Future<void> markRead({String? topicId, String? topicNodeId}) async {
    await db.update(
      'messages',
      {'unread': 0},
      where: topicId == null
          ? 'account=?'
          : 'account=? AND (topicId=? OR (kind=? AND remoteId=?))',
      whereArgs: topicId == null
          ? [account]
          : [account, topicId, 'topic', topicNodeId ?? ''],
    );
  }

  Future<void> markUnavailable(Set<String> reachable) async {
    for (final m in await messages()) {
      if (m.status == 'synced' &&
          m.remoteId.isNotEmpty &&
          !reachable.contains(m.remoteId)) {
        await db.update(
          'messages',
          {'deleted': 1, 'unread': 0},
          where: 'account=? AND id=?',
          whereArgs: [account, m.id],
        );
      }
    }
  }

  Future<String?> setting(String key) async {
    final r = await db.query(
      'settings',
      where: 'account=? AND k=?',
      whereArgs: [account, key],
    );
    return r.isEmpty ? null : r.first['v'] as String;
  }

  Future<void> set(String key, String value) async {
    await db.insert('settings', {
      'account': account,
      'k': key,
      'v': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> pendingPageEdits() async =>
      (await db.query(
            'settings',
            columns: ['v'],
            where: 'account=? AND k LIKE ?',
            whereArgs: [account, 'edit-index:%'],
          ))
          .map((r) => jsonDecode(r['v'] as String) as Map<String, dynamic>)
          .toList();

  Future<void> finishPageEdit(
    String id, {
    String? revision,
    String? publishedUrl,
    String? publishedDigest,
  }) => db.transaction((tx) async {
    if (revision != null && publishedUrl != null) {
      final row = await tx.query(
        'page_edits',
        columns: ['noteId', 'page', 'baseDigest'],
        where: 'account=? AND revision=?',
        whereArgs: [account, revision],
      );
      if (row.isNotEmpty) {
        await tx.update(
          'page_edits',
          {'baseDigest': publishedDigest},
          where:
              'account=? AND noteId=? AND publishedUrl IS NULL AND baseDigest=? AND revision!=?',
          whereArgs: [
            account,
            row.single['noteId'],
            row.single['baseDigest'],
            revision,
          ],
        );
        await tx.delete(
          'page_edits',
          where:
              'account=? AND noteId=? AND page=? AND publishedUrl IS NOT NULL AND revision!=?',
          whereArgs: [
            account,
            row.single['noteId'],
            row.single['page'],
            revision,
          ],
        );
        await tx.update(
          'page_edits',
          {
            'publishedUrl': publishedUrl,
            'publishedDigest': publishedDigest,
            'error': null,
          },
          where: 'account=? AND revision=?',
          whereArgs: [account, revision],
        );
      }
    }
    await tx.delete(
      'settings',
      where: 'account=? AND k=?',
      whereArgs: [account, 'edit-index:$id'],
    );
  });

  // Cross-isolate lease prevents foreground and background from syncing together.
  Future<bool> lock(String owner) async => db.transaction((tx) async {
    final rows = await tx.query(
      'settings',
      where: 'account=? AND k=?',
      whereArgs: [account, 'lease'],
    );
    final old = rows.isEmpty ? null : jsonDecode(rows.first['v'] as String);
    if (old != null &&
        (old['until'] as int) > DateTime.now().millisecondsSinceEpoch) {
      return false;
    }
    await tx.insert('settings', {
      'account': account,
      'k': 'lease',
      'v': jsonEncode({
        'owner': owner,
        'until': DateTime.now().millisecondsSinceEpoch + 300000,
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  });
  Future<bool> renewLock(String owner) async => db.transaction((tx) async {
    final rows = await tx.query(
      'settings',
      where: 'account=? AND k=?',
      whereArgs: [account, 'lease'],
    );
    if (rows.isEmpty) return false;
    final old = jsonDecode(rows.first['v'] as String);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (old['owner'] != owner || (old['until'] as int) <= now) return false;
    await tx.update(
      'settings',
      {
        'v': jsonEncode({'owner': owner, 'until': now + 300000}),
      },
      where: 'account=? AND k=?',
      whereArgs: [account, 'lease'],
    );
    return true;
  });
  Future<void> unlock(String owner) async => db.transaction((tx) async {
    final r = await tx.query(
      'settings',
      where: 'account=? AND k=?',
      whereArgs: [account, 'lease'],
    );
    if (r.isNotEmpty && jsonDecode(r.first['v'] as String)['owner'] == owner) {
      await tx.delete(
        'settings',
        where: 'account=? AND k=?',
        whereArgs: [account, 'lease'],
      );
    }
  });
}
