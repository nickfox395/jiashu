import 'dart:convert';
import 'api.dart';
import 'data.dart';
import 'protocol.dart';

abstract class CredentialStore {
  Future<SavedLogin?> read();
  Future<bool> replace(String loginId, Session session);
}

class DeviceCredentials implements CredentialStore {
  @override
  Future<SavedLogin?> read() => Vault.readLogin();
  @override
  Future<bool> replace(String loginId, Session session) =>
      Vault.replaceSession(loginId, session);
}

typedef PasswordLogin =
    Future<Session> Function(
      String school,
      String user,
      String password,
      String role,
      bool allowHttp,
    );

/// Called inside SyncEngine's cross-isolate lease. Passwords live exclusively in
/// secure storage/memory; SQLite holds only nonsecret retry/error state.
class AuthCoordinator {
  final Session initial;
  final Store store;
  final CredentialStore credentials;
  final PasswordLogin login;
  final DateTime Function() now;
  final Future<void> Function()? checkpoint;
  Future<Session>? _flight;
  String? _renewedToken;
  AuthCoordinator(
    this.initial,
    this.store, {
    CredentialStore? credentials,
    PasswordLogin? login,
    DateTime Function()? now,
    this.checkpoint,
  }) : credentials = credentials ?? DeviceCredentials(),
       login =
           login ??
           ((school, user, password, role, allowHttp) => SchoolApi.login(
             school,
             user,
             password,
             role,
             allowHttp,
             previousBase: initial.base,
           )),
       now = now ?? DateTime.now;

  String get key => 'auth:${initial.loginId}';
  static DateTime? expiresAt(String token) {
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
      );
      final exp = payload['exp'];
      return exp is num
          ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<Session> authorize(String? rejectedToken) async {
    if (_flight != null) {
      await _flight;
      // Re-read after the other caller; a 401 must not disappear behind an
      // unrelated proactive check that returned the same rejected token.
      return authorize(rejectedToken);
    }
    final work = _authorize(rejectedToken);
    _flight = work;
    try {
      return await work;
    } finally {
      _flight = null;
    }
  }

  Future<Session> _authorize(String? rejectedToken) async {
    await checkpoint?.call();
    final saved = await credentials.read();
    if (saved == null ||
        saved.session.account != initial.account ||
        saved.session.loginId != initial.loginId) {
      throw const ApiFailure('登录状态已更改，本次同步已停止');
    }
    final blocked = await store.setting('$key:blocked');
    // Older versions permanently blocked every unsuccessful business response,
    // including temporary service failures. Re-evaluate that legacy reason once.
    if (blocked == '账号或密码未被接受，请重新登录；如需验证请先使用官方 App') {
      await store.set('$key:blocked', '');
    } else if (blocked != null && blocked.isNotEmpty) {
      throw LoginRequired(blocked);
    }
    final current = saved.session;
    final expiry = expiresAt(current.token);
    final nearExpiry =
        expiry != null &&
        !expiry.isAfter(now().add(const Duration(minutes: 2)));
    final rejected = rejectedToken != null && current.token == rejectedToken;
    final stillValid =
        rejectedToken == null && expiry != null && expiry.isAfter(now());
    if (stillValid && current.token == _renewedToken) return current;
    if (rejected && current.token == _renewedToken) {
      await rejectedAfterLogin();
      throw const LoginRequired('自动登录后仍被拒绝，请重新登录或在官方 App 完成验证');
    }
    if (!nearExpiry && !rejected) return current;
    if (saved.password == null || saved.password!.isEmpty) {
      throw const LoginRequired('请重新登录一次以保存密码，之后将自动恢复登录');
    }
    final next = int.tryParse(await store.setting('$key:next') ?? '0') ?? 0;
    if (next > now().millisecondsSinceEpoch) {
      if (stillValid) return current;
      throw const ApiFailure('自动登录暂未成功，稍后将自动重试');
    }
    // Persist before networking: an interrupted process must not cause a loop.
    await store.set('$key:next', '${now().millisecondsSinceEpoch + 60000}');
    try {
      final fresh = await login(
        current.school,
        current.username,
        saved.password!,
        current.role,
        saved.allowHttp,
      );
      if (fresh.account != current.account) {
        throw const LoginRequired('自动登录身份不匹配，请重新登录');
      }
      final freshExpiry = expiresAt(fresh.token);
      if (freshExpiry != null && !freshExpiry.isAfter(now())) {
        throw const ApiFailure('服务器返回的登录令牌已到期，稍后将自动重试');
      }
      fresh.folder = current.folder;
      await checkpoint?.call();
      if (!await credentials.replace(current.loginId, fresh)) {
        throw const ApiFailure('登录状态已更改，本次同步已停止');
      }
      _renewedToken = fresh.token;
      await store.set('$key:next', '0');
      await store.set('$key:failures', '0');
      return fresh;
    } on LoginRequired catch (e) {
      await store.set('$key:blocked', e.message);
      rethrow;
    } catch (_) {
      final failures =
          (int.tryParse(await store.setting('$key:failures') ?? '0') ?? 0) + 1;
      final seconds = failures > 3 ? 300 : 30 * (1 << failures);
      await store.set('$key:failures', '$failures');
      await store.set(
        '$key:next',
        '${now().millisecondsSinceEpoch + seconds * 1000}',
      );
      if (stillValid &&
          expiry.isAfter(now()) &&
          (await credentials.read())?.session.loginId == current.loginId) {
        await checkpoint?.call();
        return current;
      }
      throw const ApiFailure('自动登录暂未成功，稍后将自动重试');
    }
  }

  Future<void> rejectedAfterLogin() =>
      store.set('$key:blocked', '自动登录后仍被拒绝，请重新登录或在官方 App 完成验证');
}
