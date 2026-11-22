import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';
import 'data.dart';
import 'protocol.dart';
import 'native_note.dart';
import 'note_edit.dart';
import 'auth.dart';
import 'topics.dart';

class SyncResult {
  final int incoming;
  final String status;
  final bool requiresLogin;
  const SyncResult(this.incoming, this.status, {this.requiresLogin = false});
}

class SyncEngine {
  final Session session;
  final Store store;
  final SchoolApi Function(Session)? apiFactory;
  final bool Function()? isActive;
  SyncEngine(this.session, this.store, {this.apiFactory, this.isActive});
  static String newId() => const Uuid().v4().replaceAll('-', '');
  Future<String> enqueue(
    String body, {
    String topicId = '',
    bool topic = false,
  }) async {
    final id = newId();
    letterTitle(session.role, body);
    await store.put(
      Message(
        id: id,
        role: session.role,
        text: body,
        time: DateTime.now().millisecondsSinceEpoch,
        status: 'queued',
        kind: topic ? 'topic' : 'note',
        topicId: topicId,
        remoteId: topic ? id : NativeNote.fileId(id),
      ),
    );
    return id;
  }

  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String remoteId(Message m) => m.remoteId.isNotEmpty
      ? m.remoteId
      : m.isTopic
      ? m.id
      : NativeNote.fileId(m.id);

  Future<SyncResult> run({bool checkColumns = false}) async {
    final lease = newId();
    if (!await store.lock(lease)) return const SyncResult(0, '另一个同步任务正在运行');
    Future<void> checkpoint() async {
      if (isActive?.call() == false || !await store.renewLock(lease)) {
        throw const ApiFailure('同步已停止，稍后重新核对发送结果');
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

    var incoming = 0;
    try {
      var notes = await api.allNotes();
      if (isActive?.call() == false) return const SyncResult(0, '同步已停止');
      var folder = await store.setting('folder') ?? '';
      if (folder.isEmpty) {
        // Only adopt an exact dedicated root; never wander through unrelated notebooks.
        final candidates = notes.where(
          (n) =>
              '${n['type']}' == '0' &&
              '${n['parentId']}' == '0' &&
              n['fileName'] == '家书',
        );
        if (candidates.length > 1) {
          throw const ApiFailure('发现多个家书目录，请在官方 App 中整理为一个后重试');
        }
        folder = candidates.isNotEmpty
            ? '${candidates.first['fileId']}'
            : const Uuid()
                  .v5(Namespace.url.value, 'jiashu:v1:${session.account}')
                  .replaceAll('-', '');
        await store.set(
          'folder',
          folder,
        ); // Persist before sending so retries use the same ID.
      }
      if (!notes.any((n) => '${n['fileId']}' == folder)) {
        if (await store.setting('folderVerified') == '1') {
          throw const ApiFailure('家书目录已被移走或删除，请在云笔记恢复后重试');
        }
        await checkpoint();
        await api.addFolder(folder, '0', '家书');
        notes = await api.allNotes();
      }
      final roots = notes.where(
        (n) =>
            '${n['fileId']}' == folder &&
            '${n['type']}' == '0' &&
            (n['shared'] == false || n['shared'] == 0),
      );
      if (roots.length != 1) throw const ApiFailure('未能确认家书私有目录');
      await store.set('folderVerified', '1');
      final hidden = await store.hiddenMessages();
      final hiddenFolders = hidden
          .where((key) => key.startsWith('hide:topic:'))
          .map((key) => key.substring('hide:topic:'.length))
          .toSet();
      var tree = NoteTree(notes, folder, hiddenFolders: hiddenFolders);
      var warnings = tree.excluded, periodicBudget = 20;
      for (final receipt in await store.pendingPageEdits()) {
        final expected = receipt['index'] as Map<String, dynamic>;
        final id = expected['fileId'] as String, node = tree.nodes[id];
        if (node == null ||
            hidden.contains('hide:remote:$id') ||
            [
              'fileName',
              'parentId',
              'fileUrl',
            ].any((k) => node[k] != expected[k])) {
          await store.finishPageEdit(id);
          continue;
        }
        try {
          await NotePageEdit.confirm(
            api,
            store,
            folder,
            receipt,
            checkpoint,
            recovering: true,
          );
        } on LoginRequired {
          rethrow;
        } catch (_) {
          warnings++;
        }
      }
      final baseline = await store.setting('treeBaseline') != '1';
      final previous = await store.messages();
      final byRemote = {
        for (final m in previous.where(
          (m) => m.remoteId.isNotEmpty && !m.isUpdate,
        ))
          m.remoteId: m,
      };
      final localOwners = {for (final m in byRemote.values) m.id: m.remoteId};
      final now = DateTime.now().millisecondsSinceEpoch;
      // Oldest resource checks first so unchanged notes cannot starve one another.
      final nodes = tree.nodes.values.toList()
        ..sort(
          (a, b) => (byRemote['${a['fileId']}']?.resourceCheckedAt ?? 0)
              .compareTo(byRemote['${b['fileId']}']?.resourceCheckedAt ?? 0),
        );
      for (var n in nodes) {
        await checkpoint();
        final fileId = '${n['fileId']}', title = '${n['fileName'] ?? ''}';
        final topic = '${n['type']}' == '0';
        final valid = parseLetter(title, fileId, topic: topic);
        var id = byRemote[fileId]?.id ?? valid?.legacyId ?? 'note:$fileId';
        // Distinct server objects may share a JS1 title. Never overwrite one
        // object's history or edits with another object's content.
        if (localOwners[id] != null && localOwners[id] != fileId) {
          id = 'note:$fileId';
        }
        localOwners[id] = fileId;
        final old = byRemote[fileId] ?? await store.get(id);
        if (hidden.contains('hide:id:$id') ||
            hidden.contains('hide:remote:$fileId')) {
          continue;
        }
        if (old?.status == 'conflict') continue;
        if (old != null &&
            (old.status == 'queued' || old.status == 'uncertain') &&
            (valid?.role != old.role ||
                valid?.body != old.text ||
                '${n['parentId']}' !=
                    (old.topicId.isEmpty ? folder : old.topicId) ||
                old.isTopic != topic)) {
          await store.put(old.withStatus('conflict'));
          continue;
        }
        var version = digest('$title|${n['version']}|${n['updateTime']}');
        var images = old?.images ?? <String>[];
        var content = topic ? digest(title) : old?.contentVersion ?? '';
        var bodyDigest = old?.bodyDigest ?? '';
        var checked = old?.resourceCheckedAt ?? 0;
        var resourceFailed = false;
        final needsPublication =
            !topic &&
            '${n['version']}' == '0' &&
            valid != null &&
            (valid.legacyId == fileId ||
                (old?.id == fileId &&
                    old?.role == valid.role &&
                    old?.text == valid.body));
        var publicationFailed = needsPublication;
        final changed =
            old == null || old.version != version || content.isEmpty;
        if (!topic &&
            (needsPublication ||
                changed ||
                (now - checked >= 60000 && periodicBudget > 0))) {
          if (!changed) periodicBudget--;
          try {
            final result = await api.noteContent(fileId);
            if (result.images.isEmpty) throw const ApiFailure('笔记页面尚未同步');
            images = result.images;
            content = digest('$title|${result.digest}');
            bodyDigest = result.digest;
            checked = now;
            if (needsPublication) {
              n = await api.publishNativeNote(n, checkpoint: checkpoint);
              version = digest('$title|${n['version']}|${n['updateTime']}');
              publicationFailed = false;
            }
          } on LoginRequired {
            rethrow;
          } catch (_) {
            warnings++;
            resourceFailed = true;
          }
        }
        // Title-only arrival is visible immediately; a delayed preview is not
        // another new message. A broken note cannot block other topic branches.
        final pending =
            publicationFailed ||
            (resourceFailed && old != null && old.status != 'synced');
        if (await store.ingest(
          Message(
            id: id,
            role: valid?.role ?? 'child',
            text: valid?.body ?? title,
            time:
                DateTime.tryParse(
                  '${n['createTime']}',
                )?.millisecondsSinceEpoch ??
                now,
            kind: topic ? 'topic' : 'note',
            remoteId: fileId,
            topicId: '${n['parentId']}' == folder ? '' : '${n['parentId']}',
            version: resourceFailed ? old?.version ?? '' : version,
            contentVersion: content,
            bodyDigest: bodyDigest,
            resourceCheckedAt: checked,
            images: images,
            status: pending ? 'uncertain' : 'synced',
          ),
          baseline: baseline,
          readerRole: session.role,
        )) {
          incoming++;
        }
      }
      await store.markUnavailable(tree.nodes.keys.toSet());
      await store.set('treeBaseline', '1');
      await store.set('baseline', '1');
      final pending = (await store.messages())
          .where(
            (m) =>
                !Store.isHidden(m, hidden) &&
                (m.status == 'queued' || m.status == 'uncertain'),
          )
          .toList();
      while (pending.isNotEmpty) {
        var progressed = false;
        for (final m in List<Message>.of(pending)) {
          await checkpoint();
          final target = m.topicId.isEmpty ? folder : m.topicId;
          var fileId = remoteId(m);
          final targetBlocked = (await store.messages()).any(
            (p) =>
                p.isTopic &&
                remoteId(p) == target &&
                (p.deleted || p.status == 'conflict'),
          );
          if (targetBlocked) {
            await store.put(m.withStatus('conflict'));
            pending.remove(m);
            progressed = true;
            continue;
          }
          // A previously registered note with delayed resources is read again,
          // never re-uploaded just because its preview is temporarily missing.
          if (tree.nodes.containsKey(fileId)) {
            pending.remove(m);
            progressed = true;
            continue;
          }
          if (!tree.folders.contains(target)) {
            if (pending.any((p) => p.isTopic && remoteId(p) == target)) {
              continue;
            }
            await store.put(m.withStatus('conflict'));
            pending.remove(m);
            progressed = true;
            continue;
          }
          if (notes.any(
            (n) => '${n['fileId']}' == fileId || '${n['fileId']}' == m.id,
          )) {
            await store.put(m.withStatus('conflict'));
            pending.remove(m);
            progressed = true;
            continue;
          }
          // Upgrade only unregistered pending notes. A registered legacy note
          // is reconciled above, never silently copied or deleted.
          if (!m.isTopic && !RegExp(r'^[a-f0-9]{32}$').hasMatch(m.id)) {
            await store.put(m.withStatus('conflict'));
            pending.remove(m);
            progressed = true;
            continue;
          }
          if (!m.isTopic && fileId == NativeNote.legacyFileId(m.id)) {
            final allStates = await api.allNotes(includeRecycled: true);
            if (allStates.any(
              (n) => '${n['fileId']}' == fileId || '${n['fileId']}' == m.id,
            )) {
              await store.put(m.withStatus('conflict'));
              pending.remove(m);
              progressed = true;
              continue;
            }
            await checkpoint();
            fileId = NativeNote.fileId(m.id);
          }
          if (!m.isTopic && fileId != NativeNote.fileId(m.id)) {
            await store.put(m.withStatus('conflict'));
            pending.remove(m);
            progressed = true;
            continue;
          }
          await store.put(
            Message.fromRow({
              ...m.withStatus('uncertain').row(session.account),
              'remoteId': fileId,
            }),
          );
          if (m.isTopic) {
            await api.addFolder(fileId, target, letterTitle(m.role, m.text));
          } else {
            await api.addNativeNote(m, target, checkpoint: checkpoint);
          }
          notes = await api.allNotes();
          tree = NoteTree(notes, folder, hiddenFolders: hiddenFolders);
          var n = tree.nodes[fileId];
          if (n == null ||
              '${n['parentId']}' != target ||
              '${n['type']}' != (m.isTopic ? '0' : '12') ||
              n['fileName'] != letterTitle(m.role, m.text)) {
            throw const ApiFailure('发送结果待核对，暂未确认服务器保存');
          }
          final result = m.isTopic ? null : await api.noteContent(fileId);
          if (result != null && result.images.isEmpty) {
            throw const ApiFailure('笔记已登记，页面资源待核对');
          }
          if (!m.isTopic && (int.tryParse('${n['version']}') ?? 0) < 1) {
            n = await api.publishNativeNote(n, checkpoint: checkpoint);
          }
          final title = '${n['fileName']}';
          await store.ingest(
            Message(
              id: m.id,
              role: m.role,
              text: m.text,
              time: m.time,
              kind: m.kind,
              remoteId: fileId,
              topicId: m.topicId,
              images: result?.images ?? [],
              resourceCheckedAt: now,
              bodyDigest: result?.digest ?? '',
              version: digest('$title|${n['version']}|${n['updateTime']}'),
              contentVersion: digest(
                m.isTopic ? title : '$title|${result!.digest}',
              ),
            ),
            baseline: true,
            readerRole: session.role,
          );
          pending.remove(m);
          progressed = true;
        }
        if (!progressed) {
          for (final m in pending) {
            await store.put(m.withStatus('conflict'));
          }
          break; // Locally corrupt/cyclic parent dependencies cannot loop forever.
        }
      }
      final blockedNotes = <String>{};
      for (final job in await store.queuedPages()) {
        final id = job['remoteId'] as String,
            revision = job['revision'] as String;
        if (blockedNotes.contains(id) ||
            await store.setting('edit-index:$id') != null) {
          continue;
        }
        await checkpoint();
        try {
          final note = await store.get(job['noteId'] as String);
          if (note == null ||
              !note.canEdit ||
              note.remoteId != id ||
              note.topicId != job['topic']) {
            throw const ApiFailure('云端笔记已移动或不可用，本机修改仍保留');
          }
          final edit = NotePageEdit.queued(
            note,
            job['baseUrl'] as String,
            job['baseMd5'] as String,
            revision,
            job['predecessor'] as String?,
          );
          await edit.upload(
            api,
            store,
            await store.pageBytes(store.db, revision),
            checkpoint,
          );
        } on LoginRequired {
          rethrow;
        } catch (e) {
          blockedNotes.add(id);
          warnings++;
          await store.db.update(
            'page_edits',
            {'error': e is ApiFailure ? e.message : '网络不可用，稍后重试'},
            where: 'account=? AND revision=?',
            whereArgs: [store.account, revision],
          );
        }
      }
      await store.set('lastSync', DateTime.now().toIso8601String());
      await store.set(
        'notesStatus',
        warnings == 0 ? '云笔记已同步 · 话题对话' : '话题已同步 · $warnings 项页面待同步或目录不可用',
      );
      await store.set('failures', '0');
      await store.set('nextSync', '0');
      if (checkColumns) {
        try {
          final count = await api.columnPagesCount();
          await store.set(
            'columnsStatus',
            count == 0 ? '在线专栏：账号暂无可用专用页面' : '在线专栏：发现 $count 个页面，接收范围和回信格式待验证',
          );
        } catch (e) {
          await store.set('columnsStatus', '在线专栏：${safeError(e)}');
        }
      }
      return SyncResult(incoming, '同步完成');
    } catch (e) {
      final failures =
          (int.tryParse(await store.setting('failures') ?? '0') ?? 0) + 1;
      final delay = failures > 4 ? 300 : 20 * (1 << failures);
      await store.set('failures', '$failures');
      await store.set(
        'nextSync',
        '${DateTime.now().millisecondsSinceEpoch + delay * 1000}',
      );
      await store.set('notesStatus', safeError(e));
      return SyncResult(
        incoming,
        safeError(e),
        requiresLogin: e is LoginRequired,
      );
    } finally {
      api.close();
      await store.unlock(lease);
    }
  }
}
