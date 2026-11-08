import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'api_error.dart';
import 'mock_backend.dart';

export 'api_error.dart';
import 'session.dart';

/// 生成APIの呼び出し（docs/api.md）。エラーは §5 の形 `{"error": {...}}` を ApiError にする
class Api {
  Api._();
  static final Api instance = Api._();

  Future<Map<String, String>> _headers() async {
    final (k, v) = await Session.instance.authHeader();
    return {'Content-Type': 'application/json; charset=utf-8', k: v};
  }

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) =>
      _send('POST', path, body ?? {});
  Future<dynamic> put(String path, Object body) => _send('PUT', path, body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    if (Config.mockApi) return MockBackend.instance.handle(method, path, body);
    final uri = Uri.parse('${Config.apiBase}$path');
    final h = await _headers();
    final http.Response r;
    try {
      r = switch (method) {
        'GET' => await http.get(uri, headers: h),
        'PUT' => await http.put(uri, headers: h, body: jsonEncode(body)),
        'DELETE' => await http.delete(uri, headers: h),
        _ => await http.post(uri, headers: h, body: jsonEncode(body)),
      };
    } catch (_) {
      throw ApiError(
        '通信できませんでした。インターネットの接続を確かめて、もう一度試してください。',
        code: 'NETWORK',
        retryable: true,
      );
    }
    return parse(r.statusCode, utf8.decode(r.bodyBytes));
  }

  static dynamic parse(int status, String text) => parseApiBody(status, text);
}
