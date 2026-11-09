import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'package:jijogu_app/core/storage/files.dart';

/// Storage のファイルをダウンロードする。dev はヘッダーが要るので、読み込んでから Blob にして保存する
Future<void> downloadFile(String path, String filename) async {
  final ref = await Files.resolve(path);
  var href = ref.url;
  String? blobUrl;
  if (ref.headers.isNotEmpty) {
    final r = await http.get(Uri.parse(ref.url), headers: ref.headers);
    if (r.statusCode >= 400) {
      throw StateError('ダウンロードできませんでした（${r.statusCode}）');
    }
    final blob = web.Blob(
      [r.bodyBytes.toJS].toJS,
      web.BlobPropertyBag(type: 'model/stl'),
    );
    blobUrl = web.URL.createObjectURL(blob);
    href = blobUrl;
  }
  final a = web.document.createElement('a') as web.HTMLAnchorElement;
  a.href = href;
  a.download = filename;
  web.document.body!.append(a);
  a.click();
  a.remove();
  if (blobUrl != null) {
    Future<void>.delayed(
      const Duration(seconds: 5),
      () => web.URL.revokeObjectURL(blobUrl!),
    );
  }
}
