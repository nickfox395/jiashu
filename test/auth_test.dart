import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:jiashu/api.dart';
import 'package:jiashu/auth.dart';
import 'package:jiashu/data.dart';
import 'package:jiashu/protocol.dart';

class MemoryCredentials implements CredentialStore {
  SavedLogin? saved;
  MemoryCredentials(this.saved);
  @override
  Future<SavedLogin?> read() async => saved;
  @override
  Future<bool> replace(String id, Session session) async {
    final old = saved;
    if (old == null ||
        old.session.loginId != id ||
        old.session.account != session.account) {
      return false;
    }
    session.loginId = id;
    saved = SavedLogin(session, old.password, old.allowHttp);
    return true;
  }
}

String testToken(DateTime expiry, String tag) =>
    'fixture.${base64Url.encode(utf8.encode(jsonEncode({'exp': expiry.millisecondsSinceEpoch ~/ 1000, 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier': '123', 'tag': tag})))}.fixture';

void main() {
  sqfliteFfiInit();
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }
  late Database db;
  late Store store;
  late Session initial;
  late MemoryCredentials vault;
  late DateTime clock;
  late int logins;
  Session fresh({String tag = 'new'}) => Session(
    school: initial.school,
    username: initial.username,
    role: initial.role,
    base: initial.base,
    token: testToken(clock.add(const Duration(hours: 2)), tag),
    client: 'new-client',
    userId: initial.userId,
  );
  Future<Session> login(
    String school,
    String user,
    String password,
    String role,
    bool allowHttp,
  ) async {
    logins++;
    expect(password, 'fixture-password');
    expect(allowHttp, true);
    expect(role, 'mom');
    return fresh();
  }

  AuthCoordinator coordinator({PasswordLogin? action, Session? session}) =>
      AuthCoordinator(
        session ?? initial,
        store,
        credentials: vault,
        login: action ?? login,
        now: () => clock,
      );
  setUp(() async {
    clock = DateTime.utc(2026, 11, 17, 8);
    logins = 0;
    initial = Session(
      school: 'test',
      username: 'fixture',
      role: 'mom',
      base: 'https://test.zykj.org',
      token: testToken(clock.add(const Duration(minutes: 1)), 'old'),
      client: 'old-client',
      userId: '123',
      loginId: 'generation-1',
    );
    vault = MemoryCredentials(SavedLogin(initial, 'fixture-password', true));
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE settings(account TEXT,k TEXT,v TEXT,PRIMARY KEY(account,k))',
    );
    store = Store(db, initial.account);
  });
  tearDown(() => db.close());

  test(
    'Proactive refresh is single-flight and persists no password in SQLite/session JSON',
    () async {
      final auth = coordinator();
      final sessions = await Future.wait(
        List.generate(8, (_) => auth.authorize(null)),
      );
      expect(logins, 1);
      expect(
        sessions.every((s) => s.token == vault.saved!.session.token),
        true,
      );
      expect(vault.saved!.session.loginId, initial.loginId);
      expect(vault.saved!.password, 'fixture-password');
      expect(
        jsonEncode(await db.query('settings')).contains('fixture-password'),
        false,
      );
      expect(
        jsonEncode(vault.saved!.session.toJson()).contains('fixture-password'),
        false,
      );
      // A second engine with an old in-memory session adopts the persisted token.
      await coordinator().authorize(initial.token);
      expect(logins, 1);
    },
  );

  test(
    'HTML 401 refreshes once and retries the same request with fresh credentials',
    () async {
      initial = fresh(tag: 'old')..loginId = 'generation-1';
      vault.saved = SavedLogin(initial, 'fixture-password', true);
      final auth = coordinator();
      final requests = <http.Request>[];
      final api = SchoolApi(
        initial,
        authorize: auth.authorize,
        onLoginRejected: auth.rejectedAfterLogin,
        client: MockClient((r) async {
          requests.add(r);
          return requests.length == 1
              ? http.Response('<html>Unauthorized</html>', 401)
              : http.Response('{"success":true,"result":"ok"}', 200);
        }),
      );
      expect(await api.call('/test', body: {'same': 'payload'}), 'ok');
      expect(logins, 1);
      expect(requests, hasLength(2));
      expect(requests[0].body, requests[1].body);
      expect(
        requests[1].headers['Authorization'],
        'Bearer ${vault.saved!.session.token}',
      );
      expect(requests[1].headers['ClientCode'], 'new-client');
      api.close();
    },
  );

  test('A second 401 stops reauthentication until a manual login', () async {
    initial = fresh(tag: 'old')..loginId = 'generation-1';
    vault.saved = SavedLogin(initial, 'fixture-password', true);
    final auth = coordinator();
    var requests = 0;
    final api = SchoolApi(
      initial,
      authorize: auth.authorize,
      onLoginRejected: auth.rejectedAfterLogin,
      client: MockClient((r) async {
        requests++;
        return http.Response('', 401);
      }),
    );
    await expectLater(api.call('/test'), throwsA(isA<LoginRequired>()));
    final count = logins;
    expect(requests, 2);
    expect(logins, 1);
    await expectLater(
      coordinator().authorize(null),
      throwsA(isA<LoginRequired>()),
    );
    expect(logins, count);
    api.close();
  });

  test('403 and network timeouts do not replay POST or force login', () async {
    initial = fresh(tag: 'old')..loginId = 'generation-1';
    vault.saved = SavedLogin(initial, 'fixture-password', true);
    for (final timedOut in [false, true]) {
      var requests = 0;
      final api = SchoolApi(
        initial,
        authorize: coordinator().authorize,
        client: MockClient((r) async {
          requests++;
          if (timedOut) throw TimeoutException('test');
          return http.Response('denied', 403);
        }),
      );
      await expectLater(
        api.call('/test', body: {'write': true}),
        throwsA(isA<Exception>()),
      );
      expect(requests, 1);
      expect(logins, 0);
      api.close();
    }
  });

  test(
    'Network login failures back off across coordinator restarts and then recover',
    () async {
      Future<Session> offline(
        String a,
        String b,
        String c,
        String d,
        bool e,
      ) async {
        logins++;
        throw const SocketException('private-server-error');
      }

      expect(await coordinator(action: offline).authorize(null), same(initial));
      expect(await coordinator(action: offline).authorize(null), same(initial));
      expect(logins, 1);
      clock = clock.add(const Duration(seconds: 61));
      await expectLater(
        coordinator(action: offline).authorize(null),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        coordinator(action: offline).authorize(null),
        throwsA(isA<ApiFailure>()),
      );
      expect(logins, 2);
      clock = clock.add(const Duration(seconds: 121));
      await coordinator().authorize(null);
      expect(logins, 3);
    },
  );

  test(
    'Wrong password blocks retries; new manual-login generation clears the block',
    () async {
      Future<Session> bad(
        String a,
        String b,
        String c,
        String d,
        bool e,
      ) async {
        logins++;
        throw const LoginRequired('请重新登录');
      }

      await expectLater(
        coordinator(action: bad).authorize(null),
        throwsA(isA<LoginRequired>()),
      );
      clock = clock.add(const Duration(days: 1));
      await expectLater(
        coordinator(action: bad).authorize(null),
        throwsA(isA<LoginRequired>()),
      );
      expect(logins, 1);
      final manual = fresh()..loginId = 'generation-2';
      vault.saved = SavedLogin(manual, 'new-password', true);
      expect(await coordinator(session: manual).authorize(null), same(manual));
      await expectLater(
        coordinator().authorize(null),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  test(
    'Logout or new login during a network request cannot restore the old session',
    () async {
      for (final replaceLogin in [false, true]) {
        vault.saved = SavedLogin(initial, 'fixture-password', true);
        await store.set('auth:generation-1:next', '0');
        final started = Completer<void>(), response = Completer<Session>();
        Future<Session> delayed(
          String a,
          String b,
          String c,
          String d,
          bool e,
        ) {
          started.complete();
          return response.future;
        }

        final pending = coordinator(action: delayed).authorize(null);
        await started.future;
        final newLogin = fresh(tag: 'manual')..loginId = 'new-login';
        vault.saved = replaceLogin
            ? SavedLogin(newLogin, 'new-password', true)
            : null;
        final assertion = expectLater(pending, throwsA(isA<ApiFailure>()));
        response.complete(fresh());
        await assertion;
        expect(vault.saved?.session.loginId, replaceLogin ? 'new-login' : null);
      }
    },
  );

  test(
    'Old installations without a saved password require a one-time manual login',
    () async {
      vault.saved = SavedLogin(initial, null, false);
      await expectLater(
        coordinator().authorize(null),
        throwsA(isA<LoginRequired>()),
      );
      expect(logins, 0);
    },
  );

  test(
    'Verification requirement without a token is handled before student-role checks',
    () async {
      final client = MockClient(
        (r) async => r.method == 'GET'
            ? http.Response('{"server":"https://test.zykj.org"}', 200)
            : http.Response(
                '{"success":true,"result":{"needSmsVerification":true}}',
                200,
              ),
      );
      await expectLater(
        SchoolApi.login(
          'test',
          'fixture',
          'fixture',
          'dad',
          false,
          httpClient: client,
        ),
        throwsA(
          isA<LoginRequired>().having(
            (e) => e.message,
            'message',
            contains('官方 App'),
          ),
        ),
      );
      client.close();
    },
  );

  test(
    'A discovery outage can reuse the saved school address; a rejected school cannot',
    () async {
      var status = 503, posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') return http.Response('', status);
        expect(request.url.host, 'test.zykj.org');
        posts++;
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {'roleType': 1, 'accessToken': fresh().token},
          }),
          200,
        );
      });
      Future<Session> recover() => SchoolApi.login(
        'test',
        'fixture',
        'fixture-password',
        'dad',
        false,
        httpClient: client,
        previousBase: initial.base,
      );
      expect((await recover()).userId, initial.userId);
      status = 404;
      await expectLater(recover(), throwsA(isA<ApiFailure>()));
      expect(posts, 1);
      client.close();
    },
  );

  test(
    'Automatic login cannot downgrade to HTTP without persisted consent',
    () async {
      var posts = 0;
      final client = MockClient((r) async {
        if (r.method == 'POST') posts++;
        return http.Response('{"server":"http://test.zykj.org"}', 200);
      });
      await expectLater(
        SchoolApi.login(
          'test',
          'fixture',
          'fixture',
          'dad',
          false,
          httpClient: client,
        ),
        throwsA(isA<LoginRequired>()),
      );
      expect(posts, 0);
      client.close();
    },
  );
}
