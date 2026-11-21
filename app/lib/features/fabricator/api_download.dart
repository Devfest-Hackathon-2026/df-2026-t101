import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'package:jijogu_app/core/config.dart';
import 'package:jijogu_app/core/session.dart';
import 'package:jijogu_app/features/print/download.dart';

/// 生成APIの入口（受託者のSTLなど）から、認証ヘッダー付きで読んで保存する。
/// 受託者は Storage のルールでは読めないので、`/v1/fabricator/orders/{o}/files/{key}` を通す（設計 §4 案A）。
/// モックでは [mockPath]（`demo/…` の見本）を開く
Future<void> downloadFromApi(String apiPath, String filename, {String? mockPath}) async {
  if (Config.mockApi) {
    await downloadFile(mockPath ?? 'demo/cover.print.stl', filename);
    return;
  }
  final (k, v) = await Session.instance.authHeader();
  final r = await http.get(Uri.parse('${Config.apiBase}$apiPath'), headers: {k: v});
  if (r.statusCode >= 400) {
    throw StateError('ダウンロードできませんでした（${r.statusCode}）');
  }
  final blob = web.Blob([r.bodyBytes.toJS].toJS, web.BlobPropertyBag(type: 'model/stl'));
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement;
  a.href = url;
  a.download = filename;
  web.document.body!.append(a);
  a.click();
  a.remove();
  Future<void>.delayed(const Duration(seconds: 5), () => web.URL.revokeObjectURL(url));
}
