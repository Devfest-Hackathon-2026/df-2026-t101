import 'dart:convert';

/// 生成APIの応答を読む。エラーは docs/api.md §5 の形 `{"error": {...}}`（FastAPI の detail に包まれていても読む）
dynamic parseApiBody(int status, String text) {
  dynamic body;
  try {
    body = text.isEmpty ? null : jsonDecode(text);
  } catch (_) {
    body = null;
  }
  if (status >= 400) {
    Map? e;
    if (body is Map && body['error'] is Map) e = body['error'];
    if (body is Map &&
        body['detail'] is Map &&
        body['detail']['error'] is Map) {
      e = body['detail']['error'];
    }
    throw ApiError(
      e?['message'] ?? 'エラーが起きました（$status）',
      code: e?['code'] ?? 'HTTP_$status',
      retryable: e?['retryable'] == true || status >= 500,
      details: e?['details'],
    );
  }
  return body;
}

class ApiError implements Exception {
  ApiError(
    this.message, {
    this.code = 'INTERNAL',
    this.retryable = false,
    this.details,
  });
  final String message;
  final String code;
  final bool retryable;
  final Object? details;
  @override
  String toString() => message;
}
