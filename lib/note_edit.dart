import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';
import 'auth.dart';
import 'data.dart';
import 'native_note.dart';
import 'protocol.dart';
import 'topics.dart';

/// Stage a single page under new object keys. Persist its manifest before the
/// resource update so a later sync can finish publication after a lost response.
class NotePageEdit {
  final Message note;
  final String preview;
  final String previewMd5;
  final String? revision, predecessor;
  NotePageEdit.queued(
    this.note,
    this.preview,
    this.previewMd5,
    this.revision,
    this.predecessor,
  );
  String? intendedDigest, pngDigest, editedPageName;
  Map<String, dynamic>? originalIndex;
  NotePageEdit(this.note, this.preview, Uint8List original)
    : previewMd5 = md5.convert(original).toString(),
      revision = null,
      predecessor = null;

  static String manifest(List<Map<String, dynamic>> rows) {
    final entries =
        rows
            .map(
              (r) => jsonEncode([
                for (final k in [
                  'fileId',
                  'pageName',
                  'pageIndex',
                  'id',
                  'resourceType',
                  'md5',
                  'ossImageUrl',
                ])
                  '${r[k]}',
              ]),
            )
            .toList()
          ..sort();
    return sha256.convert(utf8.encode(jsonEncode(entries))).toString();
  }

  Future<void> save(
    Session session,
    Store store,
    Uint8List png, {
    SchoolApi Function(Session)? apiFactory,
  }) async {
    final lease = const Uuid().v4();
    if (!await store.lock(lease)) throw const ApiFailure('正在同步，请稍后再保存');
    Future<void> checkpoint() async {
      if (!await store.renewLock(lease)) {
        throw const ApiFailure('同步状态已变化，请重新保存');
      }
    }

    final auth = AuthCoordinator(session, store, checkpoint: checkpoint);
    final api =
        apiFactory?.call(session) ??
        SchoolApi(
          session,
          authorize: auth.authorize,
          onLoginRejected: auth.rejectedAfterLogin,
        );
    try {
      await upload(api, store, png, checkpoint);
    } finally {
      api.close();
      await store.unlock(lease);
    }
  }

  Future<void> upload(
    SchoolApi api,
    Store store,
    Uint8List png,
    Future<void> Function() checkpoint,
  ) async {
    final session = api.session;
    final id = note.remoteId;
    final root = await store.setting('folder');
    final hidden = await store.hiddenMessages();
    if (root == null ||
        Store.isHidden(note, hidden) ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const ApiFailure('这份笔记已不可用');
    }
    final parent = note.topicId.isEmpty ? root : note.topicId;
    final before = await readIndex(api, root, id, parent, originalIndex);
    originalIndex ??= before;
    if (int.tryParse('${originalIndex!['version']}') == null) {
      throw const ApiFailure('无法核对笔记版本');
    }
    final resources = await api.noteResources(id);
    final current = manifest(resources);
    final hash = sha256.convert(png).toString();
    if (current != intendedDigest || hash != pngDigest) {
      final baseDigest = revision == null
          ? note.bodyDigest
          : await store.editBaseDigest(revision!);
      if (SchoolApi.resourceDigest(resources) != baseDigest ||
          before['version'] != originalIndex!['version']) {
        throw ApiFailure(
          revision == null ? '笔记已被修改，请重新打开后编辑' : '云端笔记已被修改，本机版本已保留',
        );
      }
      final previews = resources.where((r) {
        if ('${r['resourceType']}' != '2') return false;
        final url = Uri.parse(SchoolApi.pageContent([r]).images.single);
        return url.toString() == preview ||
            (predecessor != null &&
                url.pathSegments.contains('edit-$predecessor'));
      });
      if (previews.length != 1) throw const ApiFailure('无法唯一定位原页，请重新同步');
      final page = previews.single;
      if ('${page['md5']}'.toLowerCase() != previewMd5) {
        // Some tablet-authored notes retain an outdated MD5 in the index.
        // Compare the downloaded original before replacing such a page.
        final currentBytes = await api.client
            .readBytes(
              Uri.parse(SchoolApi.pageContent([page]).images.single),
              headers: {'Cache-Control': 'no-cache'},
            )
            .timeout(const Duration(seconds: 25));
        if (md5.convert(currentBytes).toString() != previewMd5) {
          throw const ApiFailure('页面图片与服务器版本不一致，请重新同步');
        }
      }
      final name = page['pageName'];
      final number = int.tryParse('${page['pageIndex']}');
      if (name is! String || name.isEmpty || number == null || number < 0) {
        throw const ApiFailure('服务器缺少页面标识');
      }
      final selected = resources.where((r) => r['pageName'] == name).toList();
      final other = resources.where((r) => r['pageName'] != name);
      final selectedIds = selected.map((r) => r['id']).toSet();
      if (selectedIds.contains(null) ||
          selectedIds.length != selected.length ||
          other.any((r) => selectedIds.contains(r['id'])) ||
          selected.any((r) => '${r['pageIndex']}' != '$number') ||
          resources.any(
            (r) => '${r['pageIndex']}' == '$number' && r['pageName'] != name,
          ) ||
          selected.where((r) => '${r['resourceType']}' == '2').length != 1) {
        throw const ApiFailure('页面归属不明确，无法单独替换这一页');
      }
      final now = DateTime.now();
      final plan = NativeNote(
        session.userId,
        id,
        NativeNote.chinaDay(now),
        'edit-${revision ?? const Uuid().v4()}',
        await NativeNote.pageBlobs(png),
      );
      final host = await api.uploadPage(plan, now, checkpoint: checkpoint);
      final replacement = plan.resources(
        host,
        now,
        pageName: name,
        pageIndex: number,
      );
      final ids = replacement.map((r) => r['id']).toSet();
      if (other.any((r) => ids.contains(r['id']))) {
        throw const ApiFailure('页面资源编号冲突');
      }
      await checkpoint();
      final latest = await readIndex(api, root, id, parent, originalIndex);
      if (latest['version'] != before['version'] ||
          manifest(await api.noteResources(id)) != current) {
        throw const ApiFailure('保存前检测到笔记已变化，请重新打开后编辑');
      }
      intendedDigest = manifest([...other, ...replacement]);
      pngDigest = hash;
      editedPageName = name;
      await store.set('edit-index:$id', jsonEncode(receipt));
      await api.call(
        '/CloudNotes/api/Resources/AddOrUpdate',
        notes: true,
        body: [
          ...replacement,
          for (final r in selected.where((r) => !ids.contains(r['id'])))
            {
              ...r,
              'wasDeleted': true,
              'updateTimeStamp': replacement.first['updateTimeStamp'],
            },
        ],
      );
    }
    await confirm(api, store, root, receipt, checkpoint);
  }

  Map<String, dynamic> get receipt => {
    'localId': note.id,
    if (revision != null) 'revision': revision,
    'manifest': intendedDigest,
    'page': editedPageName,
    'pngSha256': pngDigest,
    'index': {
      for (final key in [
        'fileId',
        'parentId',
        'fileName',
        'fileUrl',
        'version',
      ])
        key: originalIndex![key],
    },
  };

  static Future<Map<String, dynamic>> readIndex(
    SchoolApi api,
    String root,
    String id,
    String parent,
    Map<String, dynamic>? expected,
  ) async {
    final notes = await api.allNotes();
    final roots = notes.where((n) => n['fileId'] == root);
    final n = NoteTree(notes, root).nodes[id];
    if (roots.length != 1 ||
        '${roots.single['type']}' != '0' ||
        ![false, 0].contains(roots.single['shared']) ||
        n == null ||
        '${n['type']}' != '12' ||
        ![false, 0].contains(n['shared']) ||
        n['parentId'] != parent) {
      throw const ApiFailure('笔记已移动、共享或删除，请重新同步');
    }
    if (expected != null &&
        ['parentId', 'fileName', 'fileUrl'].any((k) => n[k] != expected[k])) {
      throw const ApiFailure('笔记信息已变化，请重新打开后编辑');
    }
    return n;
  }

  // Called under the account lease, including on the first sync after a restart.
  static Future<void> confirm(
    SchoolApi api,
    Store store,
    String root,
    Map<String, dynamic> receipt,
    Future<void> Function() checkpoint, {
    bool recovering = false,
  }) async {
    final expected = receipt['index'] as Map<String, dynamic>;
    final id = expected['fileId'] as String,
        parent = expected['parentId'] as String;
    final oldVersion = int.parse('${expected['version']}');
    final intendedDigest = receipt['manifest'] as String;
    await checkpoint();
    if (manifest(await api.noteResources(id)) != intendedDigest) {
      if (recovering) {
        await store.finishPageEdit(id);
        return;
      }
      throw const ApiFailure('正文资源尚未完整确认，请重新同步核对');
    }
    final latest = await readIndex(api, root, id, parent, expected);
    if (int.tryParse('${latest['version']}') == oldVersion) {
      await api.call(
        '/CloudNotes/api/Notes/AddOrUpdate',
        notes: true,
        body: {
          for (final k in ['fileId', 'fileName', 'parentId', 'fileUrl'])
            k: latest[k],
          'type': '12',
        },
      );
    }
    final after = await readIndex(api, root, id, parent, expected);
    final confirmed = await api.noteResources(id);
    if ((int.tryParse('${after['version']}') ?? -1) <= oldVersion ||
        manifest(confirmed) != intendedDigest) {
      throw const ApiFailure('服务器尚未确认这次修改，请再核对一次');
    }
    final content = SchoolApi.pageContent(confirmed);
    String? publishedUrl;
    if (receipt['pngSha256'] != null) {
      final page = confirmed.where(
        (r) =>
            r['pageName'] == receipt['page'] && '${r['resourceType']}' == '2',
      );
      if (page.length != 1) throw const ApiFailure('未找到保存后的正文页面');
      final url = Uri.parse(SchoolApi.pageContent(page.toList()).images.single);
      publishedUrl = url.toString();
      final bytes = await api.client
          .readBytes(url, headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 25));
      if (sha256.convert(bytes).toString() != receipt['pngSha256']) {
        throw const ApiFailure('服务器返回的正文与修改不一致，请稍后重新保存');
      }
    }
    final local = await store.get(receipt['localId'] as String);
    if (local != null) {
      await store.ingest(
        Message.fromRow({
          ...local.row(store.account),
          'images': jsonEncode(content.images),
          'bodyDigest': content.digest,
          'version': sha256
              .convert(
                utf8.encode(
                  '${after['fileName']}|${after['version']}|${after['updateTime']}',
                ),
              )
              .toString(),
          'contentVersion': sha256
              .convert(utf8.encode('${after['fileName']}|${content.digest}'))
              .toString(),
          'resourceCheckedAt': DateTime.now().millisecondsSinceEpoch,
        }),
        baseline: true,
        readerRole: api.session.role,
      );
    }
    await store.finishPageEdit(
      id,
      revision: receipt['revision'] as String?,
      publishedUrl: publishedUrl,
      publishedDigest: content.digest,
    );
  }
}
