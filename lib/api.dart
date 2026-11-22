import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'data.dart';
import 'protocol.dart';
import 'native_note.dart';

class SchoolApi {
  Session session;
  final http.Client client;
  final Future<Uint8List> Function(Message)? pageRenderer;
  final Future<Session> Function(String? rejectedToken)? authorize;
  final Future<void> Function()? onLoginRejected;
  SchoolApi(
    this.session, {
    http.Client? client,
    this.pageRenderer,
    this.authorize,
    this.onLoginRejected,
  }) : client = client ?? http.Client();
  static Future<Session> login(
    String school,
    String username,
    String password,
    String role,
    bool allowHttp, {
    http.Client? httpClient,
    String? previousBase,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,40}$').hasMatch(school)) {
      throw const ApiFailure('请输入正确的学校代码');
    }
    final client = httpClient ?? http.Client();
    try {
      http.Response? discovery;
      try {
        discovery = await client
            .get(Uri.https('hagateway.zyai.cc', '/api/discovery/$school'))
            .timeout(const Duration(seconds: 20));
      } on http.ClientException {
        if (previousBase == null) rethrow;
      } on TimeoutException {
        if (previousBase == null) rethrow;
      }
      String? address = previousBase;
      if (discovery != null) {
        if (discovery.statusCode == 200) {
          final data = jsonDecode(utf8.decode(discovery.bodyBytes));
          address = data['server'] as String?;
        } else if (discovery.statusCode < 500 || previousBase == null) {
          throw const ApiFailure('无法查询学校，请检查学校代码或稍后重试');
        }
      }
      final base = Uri.tryParse(address ?? '');
      if (base == null ||
          !['http', 'https'].contains(base.scheme) ||
          base.userInfo.isNotEmpty ||
          !(base.host.endsWith('.zykj.org') ||
              base.host.endsWith('.zyai.cc')) ||
          base.query.isNotEmpty) {
        throw const ApiFailure('学校网关返回了未识别的服务器地址');
      }
      if (base.scheme == 'http' && !allowHttp) {
        throw const LoginRequired('该学校仅提供 HTTP，请重新登录并确认传输说明');
      }
      final request = http.Request('POST', base.resolve('/api/TokenAuth/Login'))
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          'AppName': 'WebClient',
          'AppVersion': '0',
          'ClientCode': '',
        })
        ..body = jsonEncode({
          'userName': username,
          'password': password,
          'clientType': 1,
        });
      final response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 20));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const LoginRequired('账号或密码未被接受，请重新登录');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiFailure('登录服务暂不可用（HTTP ${response.statusCode}）');
      }
      final envelope = jsonDecode(utf8.decode(response.bodyBytes));
      if (envelope is Map && envelope['success'] == false) {
        final error = envelope['error'];
        final reason = error is Map
            ? '${error['message']} ${error['details']}'
            : '';
        if (RegExp(
          r'密码错误|密码不正确|用户名或密码|账号或密码|身份验证|短信验证|invalid (user|password|credential)|incorrect password',
          caseSensitive: false,
        ).hasMatch(reason)) {
          throw const LoginRequired('请检查账号密码或在官方 App 完成验证后重新登录');
        }
        throw const ApiFailure('登录服务暂未完成请求，请稍后重试');
      }
      final result = unwrap(response.statusCode, envelope);
      if (result is Map &&
          (result['needSmsVerification'] == true ||
              result['needSmsVerify'] == true ||
              result['needChangePwd'] == true)) {
        throw const LoginRequired('请先在官方 App 完成验证或修改密码，再重新登录家书');
      }
      if (result is! Map ||
          result['roleType'] != 1 ||
          result['accessToken'] is! String) {
        throw const LoginRequired('需要有效的学生账号，请重新登录');
      }
      final token = result['accessToken'] as String;
      return Session(
        school: school,
        username: username,
        role: role,
        base: base.toString().replaceAll(RegExp(r'/$'), ''),
        token: token,
        client: '${result['clientCode'] ?? ''}',
        userId: principalFromToken(token),
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<dynamic> call(String path, {Object? body, bool notes = false}) async {
    if (authorize != null) session = await authorize!(null);
    for (var attempt = 0; attempt < 2; attempt++) {
      final requestSession = session;
      final codec = notes ? NotesCodec() : null;
      final request =
          http.Request(
              body == null ? 'GET' : 'POST',
              Uri.parse('${requestSession.base}$path'),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer ${requestSession.token}',
              'AppName': 'WebClient',
              'AppVersion': '0',
              'ClientCode': requestSession.client,
              'Content-Type': 'application/json',
            });
      if (body != null) {
        request.body = notes
            ? codec!.encode(jsonEncode(body))
            : jsonEncode(body);
      }
      final response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 25));
      // Only a definite authentication rejection may replay a request. Network
      // timeouts and permission-denied 403 responses are never replayed here.
      if (response.statusCode == 401 && authorize != null) {
        if (attempt == 0) {
          session = await authorize!(requestSession.token);
          continue;
        }
        await onLoginRejected?.call();
        throw const LoginRequired('自动登录后仍被拒绝，请重新登录或在官方 App 完成验证');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        return unwrap(response.statusCode, {});
      }
      dynamic envelope;
      try {
        envelope = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        throw ApiFailure('服务器响应无法解析（HTTP ${response.statusCode}）');
      }
      return unwrap(response.statusCode, envelope, codec: codec);
    }
    throw const LoginRequired('请重新登录');
  }

  Future<List<Map<String, dynamic>>> allNotes({
    bool includeRecycled = false,
  }) async {
    final d = await call('/CloudNotes/api/Notes/GetAll', notes: true);
    if (d is! Map ||
        '${d['userId']}' != session.userId ||
        d['noteList'] is! List) {
      throw const ApiFailure('云笔记账号身份不匹配');
    }
    return (d['noteList'] as List)
        .map((e) => Map<String, dynamic>.from(e))
        .where(
          (e) =>
              includeRecycled ||
              (e['isRecycleBin'] != true && e['isRecycleBin'] != 1),
        )
        .toList();
  }

  Future<void> addFolder(String id, String parent, String title) async {
    await call(
      '/CloudNotes/api/Notes/AddOrUpdate',
      body: {
        'fileId': id,
        'fileName': title,
        'fileUrl': '',
        'parentId': parent,
        'type': '0',
      },
      notes: true,
    );
  }

  Future<List<String>> previews(String id) async =>
      (await noteContent(id)).images;

  /// First registration currently creates version 0. Tablet 1.13.6 only showed
  /// our diagnostic note after an unchanged index update advanced it to 1.
  /// Re-read before writing so retries cannot restore stale titles or parents.
  Future<Map<String, dynamic>> publishNativeNote(
    Map<String, dynamic> expected, {
    Future<void> Function()? checkpoint,
  }) async {
    Map<String, dynamic> verify(List<Map<String, dynamic>> notes) {
      final matches = notes.where((n) => n['fileId'] == expected['fileId']);
      if (matches.length != 1) {
        throw const ApiFailure('笔记已移走或删除，兼容登记已停止');
      }
      final n = matches.single;
      if ('${n['type']}' != '12' ||
          !(n['shared'] == false || n['shared'] == 0) ||
          ['fileName', 'parentId', 'fileUrl'].any((k) => n[k] != expected[k])) {
        throw const ApiFailure('笔记信息已变化，请重新同步后核对');
      }
      return n;
    }

    await checkpoint?.call();
    var n = verify(await allNotes());
    final version = int.tryParse('${n['version']}');
    if (version != null && version >= 1) return n;
    if (version != 0) throw const ApiFailure('笔记版本无法确认，兼容登记已停止');
    await checkpoint?.call();
    await call(
      '/CloudNotes/api/Notes/AddOrUpdate',
      body: {
        'fileId': n['fileId'],
        'fileName': n['fileName'],
        'fileUrl': n['fileUrl'],
        'parentId': n['parentId'],
        'type': '12',
      },
      notes: true,
    );
    await checkpoint?.call();
    n = verify(await allNotes());
    if ((int.tryParse('${n['version']}') ?? 0) < 1) {
      throw const ApiFailure('笔记兼容登记待确认，稍后自动核对');
    }
    return n;
  }

  Future<List<Map<String, dynamic>>> noteResources(String id) async {
    final query = NotesCodec().encode('fileId=$id');
    final d = await call(
      '/CloudNotes/api/Resources/GetByFileId?$query',
      notes: true,
    );
    if (d is! Map ||
        '${d['userId']}' != session.userId ||
        d['resourceList'] is! List) {
      throw const ApiFailure('笔记页面身份不匹配');
    }
    final resources = (d['resourceList'] as List)
        .where((r) => r['wasDeleted'] != true && r['wasDeleted'] != 1)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    for (final r in resources) {
      if ('${r['fileId']}' != id || '${r['userId']}' != session.userId) {
        throw const ApiFailure('笔记资源身份不匹配');
      }
    }
    return resources;
  }

  static String resourceDigest(List<Map<String, dynamic>> resources) {
    final fingerprints =
        resources
            .map(
              (r) =>
                  '${r['pageIndex']}|${r['resourceType']}|${r['md5'] ?? r['ossImageUrl']}',
            )
            .toList()
          ..sort();
    return sha256.convert(utf8.encode(jsonEncode(fingerprints))).toString();
  }

  Future<({List<String> images, String digest})> noteContent(String id) async =>
      pageContent(await noteResources(id));

  static ({List<String> images, String digest}) pageContent(
    List<Map<String, dynamic>> resources,
  ) {
    final rows = resources.where((e) => '${e['resourceType']}' == '2').toList()
      ..sort(
        (a, b) => (int.tryParse('${a['pageIndex']}') ?? 0).compareTo(
          int.tryParse('${b['pageIndex']}') ?? 0,
        ),
      );
    final images = <String>[];
    for (final r in rows) {
      final u = Uri.tryParse('${r['ossImageUrl']}');
      // Resource requests contain no school bearer token. Require an official OSS origin.
      if (u == null ||
          u.userInfo.isNotEmpty ||
          !RegExp(
            r'^ezy-[a-z0-9-]+\.oss-cn-[a-z0-9-]+\.aliyuncs\.com$',
          ).hasMatch(u.host)) {
        throw const ApiFailure('笔记图片地址不在已验证的存储范围');
      }
      images.add(u.replace(scheme: 'https', port: 443).toString());
    }
    return (images: images, digest: resourceDigest(resources));
  }

  Future<void> addNativeNote(
    Message message,
    String parent, {
    Future<void> Function()? checkpoint,
  }) async {
    final now = DateTime.now();
    final plan = await NativeNote.prepare(
      session.userId,
      message,
      now,
      pageImage: await pageRenderer?.call(message),
    );
    final root = await uploadPage(plan, now, checkpoint: checkpoint);
    await checkpoint?.call();
    await call(
      '/CloudNotes/api/Resources/AddOrUpdate',
      body: plan.resources(root, now),
      notes: true,
    );
    await checkpoint?.call();
    await call(
      '/CloudNotes/api/Notes/AddOrUpdate',
      body: {
        'fileId': plan.id,
        'fileName': letterTitle(message.role, message.text),
        'parentId': parent,
        'type': '12',
        'fileUrl': root.resolve(plan.prefix).toString(),
      },
      notes: true,
    );
  }

  Future<Uri> uploadPage(
    NativeNote plan,
    DateTime now, {
    Future<void> Function()? checkpoint,
  }) async {
    await checkpoint?.call();
    final sts = await call(
      '/api/services/app/ObjectStorage/GenerateTokenV2Async',
      body: plan.tokenRequest(now),
    );
    if (sts is! Map) throw const ApiFailure('服务器未返回上传凭据');
    if (plan.day != NativeNote.chinaDay(DateTime.now())) {
      throw const ApiFailure('已跨过北京时间午夜，请稍后重试');
    }
    await plan.upload(client, sts, checkpoint: checkpoint);
    // Match the successfully opened tablet probe's stored URL format.
    // Actual uploads and app preview downloads still use verified HTTPS.
    return NativeNote.endpoint(
      sts['endpoint'],
    ).replace(scheme: 'http', port: 80);
  }

  Future<int> columnPagesCount() async {
    final catalogs = await call(
      '/api/services/app/AppWebSite/GetSpecialCatalogAsync',
    );
    if (catalogs is! List) throw const ApiFailure('在线专栏目录格式尚未支持');
    var count = 0;
    for (final catalog in catalogs.take(5)) {
      final id = catalog['id'];
      if (id == null) continue;
      final pages = await call(
        '/api/services/app/AppWebSite/GetMyCatalogPagesAsync?catalogId=${Uri.encodeQueryComponent('$id')}&skipCount=0&maxResultCount=20',
      );
      if (pages is! Map || pages['items'] is! List) {
        throw const ApiFailure('在线专栏页面格式尚未支持');
      }
      count += (pages['items'] as List).length;
    }
    return count;
  }

  void close() => client.close();
}

/// Documented adapter boundary. Not enabled until a dedicated page's audience,
/// response schema and child reply route have been verified with a real sample.
class ColumnsAdapter {
  final SchoolApi api;
  ColumnsAdapter(this.api);
  Future<dynamic> read(int verifiedPageId, int skip) => api.call(
    '/api/services/app/AppWebSite/GetPagedCommentsAndRepliesAsync',
    body: {
      'pageId': verifiedPageId,
      'skipCount': skip,
      'maxResultCount': 50,
      'publicOnly': false,
      'myOnly': true,
    },
  );
  Future<void> send(
    int verifiedPageId,
    String content, {
    required bool audienceVerified,
  }) async {
    if (!audienceVerified) throw const ApiFailure('专栏接收范围尚未验证，消息保留在本机');
    await api.call(
      '/api/services/app/AppWebSite/CreateCommentAsync',
      body: {'specialPageId': verifiedPageId, 'content': content},
    );
  }
}
