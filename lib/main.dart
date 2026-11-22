import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'alerts.dart';
import 'api.dart';
import 'data.dart';
import 'note_editor.dart';
import 'protocol.dart';
import 'sync.dart';
import 'topics.dart';

const ink = Color(0xFF203E38),
    paper = Color(0xFFF7F4ED),
    muted = Color(0xFF758078);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alerts.init();
  await configureBackground();
  Session? session;
  try {
    session = await Vault.read();
  } catch (_) {
    await Vault.clear();
  }
  runApp(JiashuApp(initial: session));
}

class JiashuApp extends StatefulWidget {
  final Session? initial;
  const JiashuApp({super.key, this.initial});
  @override
  State<JiashuApp> createState() => _JiashuAppState();
}

class _JiashuAppState extends State<JiashuApp> {
  late Session? session = widget.initial;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '家书',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: ink, surface: paper),
      scaffoldBackgroundColor: paper,
      fontFamilyFallback: const ['Noto Sans CJK SC', 'sans-serif'],
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    ),
    home: session == null
        ? LoginPage(onLogin: (s) => setState(() => session = s))
        : ChatPage(
            key: ValueKey(session!.account),
            session: session!,
            onLogout: () => setState(() => session = null),
          ),
  );
}

class LoginPage extends StatefulWidget {
  final ValueChanged<Session> onLogin;
  const LoginPage({super.key, required this.onLogin});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final school = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController();
  String role = 'dad', error = '';
  bool allowHttp = false, busy = false, obscure = true;
  @override
  void dispose() {
    school.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (busy) return;
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = '请填写学生账号和密码');
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final s = await SchoolApi.login(
        school.text.trim().toLowerCase(),
        username.text.trim(),
        password.text,
        role,
        allowHttp,
      );
      await Vault.save(s, password: password.text, allowHttp: allowHttp);
      await Alerts.plugin.cancel(101);
      password.clear();
      if (mounted) widget.onLogin(s);
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: ink,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(
                    Icons.mark_email_unread_outlined,
                    color: paper,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  '家书',
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: ink,
                    letterSpacing: 6,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '把日常，说给彼此听。',
                  style: TextStyle(fontSize: 18, color: muted),
                ),
                const SizedBox(height: 30),
                const Text(
                  '这封家书，来自',
                  style: TextStyle(color: ink, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'dad',
                      label: Text('爸爸'),
                      icon: Icon(Icons.person_outline),
                    ),
                    ButtonSegment(
                      value: 'mom',
                      label: Text('妈妈'),
                      icon: Icon(Icons.favorite_border),
                    ),
                  ],
                  selected: {role},
                  onSelectionChanged: busy
                      ? null
                      : (v) => setState(() => role = v.first),
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: school,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '学校代码',
                    hintText: '例如 sxz',
                    prefixIcon: Icon(Icons.school_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: username,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '学生账号',
                    prefixIcon: Icon(Icons.account_circle_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: password,
                  enabled: !busy,
                  obscureText: obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => login(),
                  decoration: InputDecoration(
                    labelText: '学生密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => obscure = !obscure),
                      icon: Icon(
                        obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: allowHttp,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => allowHttp = v ?? false),
                  title: const Text(
                    '学校只提供 HTTP 时，允许明文连接',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    '密码和消息可能被网络中间方读取。本机密码加密保存，用于自动登录。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: busy ? null : login,
                    child: busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('打开家书'),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '使用孩子的学生账号。爸爸 / 妈妈是消息署名，并非学校账号角色。家书是独立客户端。',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ChatPage extends StatefulWidget {
  final Session session;
  final VoidCallback onLogout;
  const ChatPage({super.key, required this.session, required this.onLogout});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  Store? store;
  final composer = TextEditingController(),
      scroll = ScrollController(keepScrollOffset: false);
  Timer? timer;
  StreamSubscription? backgroundEvents;
  List<Message> messages = [];
  String topicId = '';
  final drafts = <String, String>{};
  TopicView get topics => TopicView(messages);
  Message? get currentTopic => topics.folders[topicId];
  List<Message> get visibleMessages => topics.children(topicId);
  bool get canSend =>
      store != null &&
      !deleting &&
      (topicId.isEmpty ||
          (currentTopic != null &&
              !currentTopic!.deleted &&
              currentTopic!.status != 'conflict'));
  String notesStatus = '正在连接云笔记…', lastSync = '尚未同步';
  bool syncing = false,
      deleting = false,
      foreground = true,
      background = false,
      notified = false,
      active = true;
  int unread = 0;
  int refreshGeneration = 0;
  Session get session => widget.session;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    init();
  }

  Future<void> init() async {
    store = await Store.open(session.account);
    await refresh();
    background = await store!.setting('background') == '1';
    if (!active) return;
    if (background) await FlutterBackgroundService().startService();
    if (!active) return;
    backgroundEvents = FlutterBackgroundService().on('updated').listen((
      event,
    ) async {
      if (event?['account'] != session.account || !mounted || !active) return;
      final count = (event?['incoming'] as int?) ?? 0;
      await refresh();
      if (count > 0 && foreground) announce(count);
    });
    await sync();
    if (!active) return;
    timer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!foreground || !active) return;
      final next = int.tryParse(await store!.setting('nextSync') ?? '0') ?? 0;
      if (next <= DateTime.now().millisecondsSinceEpoch) await sync();
      await refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && active) {
      scrollBottom();
      refresh();
      sync();
    }
  }

  @override
  void dispose() {
    active = false;
    timer?.cancel();
    backgroundEvents?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (store == null) return;
    final generation = ++refreshGeneration;
    final list = await store!.visibleMessages();
    final old = {for (final m in messages) m.id: m};
    for (final m in list) {
      if (old[m.id] != null && old[m.id]!.contentVersion != m.contentVersion) {
        for (final url in m.images) {
          await NetworkImage(url).evict();
        }
      }
    }
    final ns = await store!.setting('notesStatus'),
        ls = await store!.setting('lastSync');
    if (!mounted || !active || generation != refreshGeneration) return;
    setState(() {
      messages = list;
      unread = list.where((m) => m.unread).length;
      notesStatus = ns ?? notesStatus;
      lastSync = ls == null
          ? '尚未同步'
          : timeLabel(DateTime.parse(ls).millisecondsSinceEpoch);
    });
  }

  Future<void> sync() async {
    if (store == null || syncing || deleting || !active) return;
    setState(() => syncing = true);
    try {
      final result = await SyncEngine(
        session,
        store!,
        isActive: () => active,
      ).run();
      if (!active) return;
      await Alerts.authentication(session, store!, result);
      await refresh();
      if (result.incoming > 0) {
        await Alerts.incoming(result.incoming);
        if (foreground) announce(result.incoming);
      }
    } finally {
      if (mounted && active) setState(() => syncing = false);
    }
  }

  Future<void> deleteMessage(Message m) async {
    if (store == null || !active || deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          m.isTopic
              ? '删除这个目录？'
              : m.isUpdate
              ? '删除这条更新提醒？'
              : '删除这条消息？',
        ),
        content: Text(
          m.isTopic
              ? '仅从本机家书移除“${m.text}”及其中的全部子目录、消息和更新提醒，云笔记原件保留。\n\n其中的待发消息将停止发送或重试；后续同步也不会重新显示这个目录。'
              : m.isUpdate
              ? '仅从本机家书移除这条提醒，原消息和云笔记保留。之后笔记再次更新仍会提醒。'
              : '仅从本机家书移除这条消息及关联的更新提醒，云笔记原件保留。\n\n待发消息将停止发送或重试；发送结果未确认的消息可能已经保存在云笔记。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !active) return;
    setState(() => deleting = true);
    try {
      final result = await store!.hideMessage(m.id);
      await refresh();
      if (result == MessageDeleteResult.deleted &&
          m.isTopic &&
          mounted &&
          active) {
        if (topicId.isNotEmpty && !topics.folders.containsKey(topicId)) {
          openTopic(topics.folders.containsKey(m.topicId) ? m.topicId : '');
        }
        drafts.removeWhere(
          (id, _) => id.isNotEmpty && !topics.folders.containsKey(id),
        );
      }
      if (result == MessageDeleteResult.deleted && unread == 0) {
        await Alerts.plugin.cancel(100);
        if (mounted && active) setState(() => notified = false);
      }
      if (!mounted || !active) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (result) {
            MessageDeleteResult.deleted => '已从本机家书删除，云笔记保留',
            MessageDeleteResult.busy => '正在同步，请稍后再删除',
            MessageDeleteResult.notFound => '消息已不存在',
          }),
        ),
      );
    } catch (e) {
      if (mounted && active) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    } finally {
      if (mounted && active) setState(() => deleting = false);
    }
  }

  Future<void> clearHistory() async {
    if (!active || store == null || deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空聊天记录？'),
        content: const Text(
          '清空本机当前账号在所有话题中的消息和更新提醒，并取消待发消息。云端原件、话题目录和草稿保留，之后仍可接收新消息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !active) return;
    setState(() => deleting = true);
    try {
      final cleared = await store!.clearHistory();
      if (cleared) {
        await refresh();
        if (unread == 0) {
          await Alerts.plugin.cancel(100);
          if (mounted) setState(() => notified = false);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(cleared ? '已清空本机聊天记录' : '正在同步，请稍后再清空')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  void announce(int count) {
    if (!mounted) return;
    setState(() => notified = true);
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('收到 $count 条新消息或笔记更新'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> send() async {
    if (!canSend || composer.text.trim().isEmpty) return;
    final target = topicId, body = composer.text.trim();
    try {
      await SyncEngine(session, store!).enqueue(body, topicId: target);
      if (!mounted || !active) return;
      drafts.remove(target);
      if (topicId == target) composer.clear();
      await refresh();
      if (topicId == target) scrollBottom();
      await sync();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    }
  }

  void scrollBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) scroll.jumpTo(0);
    });
  }

  Future<void> markRead() async {
    await store?.markRead(topicId: topicId, topicNodeId: topicId);
    await Alerts.plugin.cancel(100);
    await refresh();
    if (mounted) setState(() => notified = false);
    scrollBottom();
  }

  void openTopic(String id) {
    FocusScope.of(context).unfocus();
    drafts[topicId] = composer.text;
    setState(() {
      topicId = id;
      composer.text = drafts[id] ?? '';
    });
    scrollBottom();
  }

  Future<void> newTopic() async {
    if (!canSend) return;
    final parent = topicId;
    var value = '';
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(parent.isEmpty ? '开启话题' : '开启分支话题'),
        content: TextField(
          autofocus: true,
          maxLength: 60,
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
          ],
          decoration: const InputDecoration(hintText: '话题标题，也可以是一句想说的话'),
          onChanged: (text) => value = text,
          onSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (!mounted || !active || title == null || title.trim().isEmpty) return;
    try {
      final id = await SyncEngine(
        session,
        store!,
      ).enqueue(title.trim(), topicId: parent, topic: true);
      await refresh();
      if (!mounted || !active) return;
      openTopic(id);
      await sync();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    }
  }

  void showUnread() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('未读家书'),
            subtitle: Text('选择消息进入所在话题；已读只标记当前话题'),
          ),
          for (final m in messages.where((m) => m.unread && !m.deleted))
            ListTile(
              leading: Icon(
                m.isTopic ? Icons.forum_outlined : Icons.mail_outline,
              ),
              title: Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(topics.folders[m.topicId]?.text ?? '家书 · 日常消息'),
              onTap: () {
                Navigator.pop(context);
                openTopic(m.isTopic ? m.remoteId : m.topicId);
              },
            ),
        ],
      ),
    ),
  );

  Future<void> toggleBackground(bool value) async {
    if (store == null) return;
    if (value && !await Alerts.permission()) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('系统通知未获允许，请在手机设置中允许家书通知')));
      }
      return;
    }
    await store!.set('background', value ? '1' : '0');
    if (value) {
      await FlutterBackgroundService().startService();
    } else {
      FlutterBackgroundService().invoke('stop');
    }
    if (mounted) setState(() => background = value);
  }

  Future<void> logout() async {
    active = false;
    timer?.cancel();
    await store?.set('background', '0');
    FlutterBackgroundService().invoke('stop');
    await Vault.clear();
    await Alerts.plugin.cancel(100);
    await Alerts.plugin.cancel(101);
    if (mounted) widget.onLogout();
  }

  void settings() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '家书设置',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${session.username} · ${session.school} · ${session.roleName}',
                style: const TextStyle(color: muted),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('后台接收与新消息提醒'),
                subtitle: const Text('每 3 分钟检查一次新消息'),
                value: background,
                onChanged: (v) async {
                  await toggleBackground(v);
                  if (context.mounted) update(() {});
                },
              ),
              const Divider(),
              TextButton.icon(
                onPressed: store == null || deleting
                    ? null
                    : () {
                        Navigator.pop(context);
                        clearHistory();
                      },
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清空聊天记录'),
              ),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  logout();
                },
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: topicId.isEmpty,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) openTopic(currentTopic?.topicId ?? '');
    },
    child: Scaffold(
      appBar: AppBar(
        leading: topicId.isEmpty
            ? null
            : IconButton(
                tooltip: '返回上一级话题',
                onPressed: () => openTopic(currentTopic?.topicId ?? ''),
                icon: const Icon(Icons.arrow_back),
              ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              topicId.isEmpty ? '家书' : '话题对话',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
            ),
            Text(
              topicId.isEmpty
                  ? '与孩子的日常 · ${session.roleName}'
                  : '家书 / ${topics.path(topicId).length} 层话题 · ${session.roleName}',
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '同步',
            onPressed: syncing ? null : () => sync(),
            icon: syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: '家书设置',
            onPressed: settings,
            icon: const Icon(Icons.tune),
          ),
          if (currentTopic != null)
            PopupMenuButton<String>(
              key: const ValueKey('current-topic-menu'),
              tooltip: '目录操作',
              enabled: !syncing && !deleting,
              onSelected: (_) {
                final topic = currentTopic;
                if (topic != null) deleteMessage(topic);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'delete', child: Text('删除当前目录')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            InkWell(
              onTap: settings,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                color: const Color(0xFFEAEDE5),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_outlined, size: 16, color: ink),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$notesStatus\n最后成功同步 $lastSync',
                        style: const TextStyle(
                          fontSize: 11,
                          color: ink,
                          height: 1.6,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          topicId.isEmpty
                              ? '话题与日常消息'
                              : currentTopic?.text ?? '话题不可用',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            color: ink,
                          ),
                        ),
                        Text(
                          topicId.isEmpty
                              ? '目录开启话题，笔记是独立发言'
                              : !canSend
                              ? '话题已删除、移出或发生冲突，暂不能发送'
                              : '${currentTopic?.role == 'dad'
                                    ? '爸爸'
                                    : currentTopic?.role == 'mom'
                                    ? '妈妈'
                                    : '孩子'}开启 · ${timeLabel(currentTopic!.time)}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: canSend ? newTopic : null,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: Text(topicId.isEmpty ? '开启话题' : '开分支'),
                  ),
                ],
              ),
            ),
            if (unread > 0 || notified)
              Material(
                color: const Color(0xFFE2ECDC),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.mark_email_unread, color: ink),
                  title: Text(
                    '$unread 条未读家书',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: showUnread,
                  trailing: TextButton(
                    onPressed: markRead,
                    child: const Text('本话题已读'),
                  ),
                ),
              ),
            Expanded(child: chatHistory()),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      enabled: canSend,
                      controller: composer,
                      minLines: 1,
                      maxLines: 3,
                      maxLength: 60,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                      ],
                      decoration: const InputDecoration(
                        hintText: '在当前话题发一条消息…',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: canSend ? send : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(52, 52),
                      padding: const EdgeInsets.all(14),
                    ),
                    child: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 9),
              child: Text(
                '笔记是平级消息 · 每条最多 60 字 · 在线专栏待接通',
                style: TextStyle(fontSize: 10, color: muted),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget chatHistory() {
    final chatItems = visibleMessages;
    return chatItems.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mail_outline, size: 68, color: muted),
                  const SizedBox(height: 20),
                  const Text(
                    '从一句问候开始',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      color: ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '直接发送消息，或开启一个新话题。\n孩子在同一个话题目录里新建笔记即可回复。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, height: 1.7),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: settings,
                    child: const Text('查看通路与使用说明'),
                  ),
                ],
              ),
            ),
          )
        : ListView.builder(
            reverse: true,
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            itemCount: chatItems.length,
            itemBuilder: (context, i) {
              final m = chatItems[chatItems.length - 1 - i];
              return m.isTopic ? topicCard(m) : bubble(m);
            },
          );
  }

  Widget topicCard(Message m) {
    final children = topics
        .children(m.remoteId)
        .where((c) => !c.deleted)
        .toList();
    final count = topics.unreadBelow(m.remoteId);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xffe9eee5),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 10,
        ),
        leading: const Icon(Icons.forum_outlined, color: ink),
        title: Text(
          m.text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('创建于 ${timeLabel(m.time)}'),
            Text(
              m.deleted
                  ? '已删除或移出 · 保留本机历史'
                  : m.status != 'synced'
                  ? (m.status == 'conflict' ? '话题位置已改变 · 已停止发送' : '等待同步，可先写消息')
                  : '${children.where((c) => !c.isTopic).length} 条消息 · ${children.where((c) => c.isTopic).length} 个分支${m.edited ? ' · 已编辑' : ''}',
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (count > 0)
              Badge(
                label: Text('$count'),
                child: const Icon(Icons.chevron_right),
              ),
            PopupMenuButton<String>(
              key: ValueKey('topic-menu:${m.id}'),
              tooltip: '目录操作',
              enabled: !syncing && !deleting,
              onSelected: (_) => deleteMessage(m),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'delete', child: Text('删除目录')),
              ],
            ),
          ],
        ),
        onTap: () => openTopic(m.remoteId),
      ),
    );
  }

  Future<void> openNote(Message note, {required bool edit}) async {
    final index = note.images.length == 1
        ? 0
        : await showModalBottomSheet<int>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: note.images.length,
                itemBuilder: (context, i) => ListTile(
                  title: Text('第 ${i + 1} 页'),
                  onTap: () => Navigator.pop(context, i),
                ),
              ),
            ),
          );
    if (index == null || !mounted || !active) return;
    if (!edit) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text('笔记正文 · 第 ${index + 1} 页')),
            body: Center(
              child: InteractiveViewer(
                minScale: .5,
                maxScale: 5,
                child: Image.network(
                  note.images[index],
                  errorBuilder: (_, _, _) => const Text('图片加载失败，请检查网络'),
                ),
              ),
            ),
          ),
        ),
      );
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NoteEditor(
          session: session,
          store: store!,
          note: note,
          pageIndex: index,
        ),
      ),
    );
    if (saved == true && mounted && active) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正文页面已保存')));
      await refresh();
    }
  }

  Widget bubble(Message m) {
    final original = m.isUpdate
        ? messages
              .where((n) => !n.isUpdate && n.remoteId == m.remoteId)
              .firstOrNull
        : null;
    final page = original ?? m;
    final mine = m.role == session.role, child = m.role == 'child';
    final name = m.isUpdate
        ? '笔记更新'
        : child
        ? '孩子'
        : m.role == 'dad'
        ? '爸爸'
        : '妈妈';
    final label = m.deleted
        ? '已删除或移出 · 保留本机历史'
        : m.status == 'queued'
        ? '等待发送'
        : m.status == 'uncertain'
        ? '结果待核对 · 会自动重试'
        : m.status == 'conflict'
        ? '远端消息已改动 · 已停止重发'
        : m.contentVersion.isEmpty && m.remoteId.isNotEmpty
        ? '页面同步中'
        : '服务器已保存';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .8,
        ),
        margin: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      '$name  ·  ${timeLabel(m.time)}${m.edited ? ' · 已编辑' : ''}${m.unread ? '  ●' : ''}',
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: ValueKey('message-menu:${m.id}'),
                    tooltip: '消息操作',
                    enabled: !syncing && !deleting,
                    icon: const Icon(Icons.more_horiz, size: 20, color: muted),
                    onSelected: (action) {
                      if (action == 'delete') {
                        deleteMessage(m);
                      } else {
                        openNote(page, edit: action == 'edit');
                      }
                    },
                    itemBuilder: (_) => [
                      if (page.images.isNotEmpty)
                        const PopupMenuItem(
                          value: 'view',
                          child: Text('查看笔记正文'),
                        ),
                      if (page.kind == 'note' &&
                          !page.deleted &&
                          page.status == 'synced' &&
                          page.images.isNotEmpty)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('修改笔记正文'),
                        ),
                      const PopupMenuItem(value: 'delete', child: Text('删除消息')),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: mine ? ink : Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: SelectableText(
                m.text,
                style: TextStyle(
                  fontSize: 16,
                  color: mine ? Colors.white : ink,
                  height: 1.6,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 4, left: 4),
              child: Text(
                '${m.source} · $label',
                style: TextStyle(
                  fontSize: 10,
                  color: m.status == 'synced' ? muted : Colors.deepOrange,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String timeLabel(int milliseconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
