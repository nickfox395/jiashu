import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jiashu/api.dart';
import 'package:jiashu/data.dart';
import 'package:jiashu/protocol.dart';

/// Simulates independently observable OSS and school-service behavior, including
/// the common "server saved, response lost" failure at final note registration.
class NativeFixture {
  final notes = <Map<String, dynamic>>[
    {
      'fileId': 'root',
      'parentId': '0',
      'fileName': '家书',
      'type': 0,
      'shared': false,
    },
  ];
  final resources = <Map<String, dynamic>>[];
  final objects = <String, Uint8List>{};
  final order = <String>[];
  int registrations = 0, tokens = 0;
  bool loseFinalResponse = false, failOneUpload = false;
  bool losePublicationResponse = false, rejectPublication = false;
  bool loseResourceResponse = false, stalePreview = false;
  void Function()? beforeNoteRead;
  SchoolApi api(Session session) => SchoolApi(
    session,
    pageRenderer: (_) async =>
        File('test/fixtures/native-page.png').readAsBytes(),
    client: MockClient((request) async {
      final codec = NotesCodec();
      http.Response cloud(Object? value) => http.Response(
        jsonEncode({
          'code': 0,
          'data': value == null ? null : codec.encode(jsonEncode(value)),
        }),
        200,
      );
      if (request.method == 'GET' &&
          request.url.host == 'ezy-test.oss-cn-hangzhou.aliyuncs.com') {
        final bytes = stalePreview
            ? Uint8List.fromList([0])
            : objects[request.url.path];
        return bytes == null
            ? http.Response('', 404)
            : http.Response.bytes(bytes, 200);
      }
      if (request.method == 'PUT') {
        expect(request.url.scheme, 'https');
        expect(request.followRedirects, false);
        expect(request.headers['Authorization'], startsWith('OSS '));
        expect(
          request.headers.values.any((v) => v.contains(session.token)),
          false,
        );
        // Independently recompute canonical signature, using received HTTP fields.
        final canonical =
            'PUT\n\n${request.headers['Content-Type']}\n${request.headers['Date']}\nx-oss-security-token:fixture-sts\n/ezy-test${request.url.path}';
        final signature = base64Encode(
          Hmac(
            sha1,
            utf8.encode('fixture-sk'),
          ).convert(utf8.encode(canonical)).bytes,
        );
        expect(request.headers['Authorization'], 'OSS fixture-ak:$signature');
        if (failOneUpload && objects.length == 2) {
          failOneUpload = false;
          throw http.ClientException('connection interrupted');
        }
        objects[request.url.path] = request.bodyBytes;
        order.add('put');
        return http.Response('', 200);
      }
      if (request.url.path.endsWith('GenerateTokenV2Async')) {
        tokens++;
        final body = jsonDecode(request.body);
        expect(body['ft'], 2);
        expect(
          body['sign'],
          md5
              .convert(
                utf8.encode(
                  '${session.userId}+note_v2+res+2++0+${body['nonce']}+${body['ts']}',
                ),
              )
              .toString()
              .toUpperCase(),
        );
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {
              'bucket': 'ezy-test',
              'endpoint': 'http://ezy-test.oss-cn-hangzhou.aliyuncs.com',
              'accessKeyId': 'fixture-ak',
              'accessKeySecret': 'fixture-sk',
              'securityToken': 'fixture-sts',
            },
          }),
          200,
        );
      }
      if (request.url.path.endsWith('Resources/AddOrUpdate')) {
        final rows = (codec.decode(request.body) as List).cast<Map>();
        for (final r in rows) {
          resources.removeWhere(
            (old) => old['id'] == r['id'] && old['fileId'] == r['fileId'],
          );
          resources.add(
            Map<String, dynamic>.from(r)..['userId'] = session.userId,
          );
          if (r['wasDeleted'] == true) continue;
          expect(r['fileId'], matches(RegExp(r'^[a-f0-9]{32}$')));
          expect(Uri.parse(r['ossImageUrl']).scheme, 'http');
          final bytes = objects[Uri.parse(r['ossImageUrl']).path];
          expect(bytes, isNotNull);
          expect(r['md5'], md5.convert(bytes!).toString().toUpperCase());
        }
        order.add('resources');
        if (loseResourceResponse) {
          loseResourceResponse = false;
          throw http.ClientException('resource response lost');
        }
        return cloud(null);
      }
      if (request.url.path.endsWith('Notes/AddOrUpdate')) {
        registrations++;
        expect(resources.length, greaterThanOrEqualTo(9));
        final n = Map<String, dynamic>.from(codec.decode(request.body));
        expect(n['type'], '12');
        expect(n['fileId'], matches(RegExp(r'^[a-f0-9]{32}$')));
        expect(Uri.parse(n['fileUrl']).scheme, 'http');
        final existing = notes.where((e) => e['fileId'] == n['fileId']);
        final updating = existing.isNotEmpty;
        if (updating && rejectPublication) return http.Response('{}', 403);
        final version = updating ? (existing.single['version'] as int) + 1 : 0;
        notes.removeWhere((e) => e['fileId'] == n['fileId']);
        notes.add(n..addAll({'version': version, 'shared': false}));
        order.add('note');
        if (loseFinalResponse || (updating && losePublicationResponse)) {
          loseFinalResponse = false;
          losePublicationResponse = false;
          throw http.ClientException('response lost');
        }
        return cloud(null);
      }
      if (request.url.path.endsWith('Resources/GetByFileId')) {
        return cloud({'userId': session.userId, 'resourceList': resources});
      }
      expect(request.url.path, '/CloudNotes/api/Notes/GetAll');
      beforeNoteRead?.call();
      return cloud({'userId': session.userId, 'noteList': notes});
    }),
  );
}
