import 'package:firebase_storage/firebase_storage.dart';

import 'package:jijogu_app/core/config.dart';
import 'package:jijogu_app/core/session.dart';

/// Storage のファイル（手のメッシュ GLB・STL・画像）の読み先。
/// dev は生成APIの `GET /v1/files/{path}`（X-User を付ける）、firebase は Storage SDK のダウンロードURL、
/// モックは `web/demo/` の見本（impl の受け渡しの決まり §2）
class FileRef {
  const FileRef(this.url, [this.headers = const {}]);
  final String url;
  final Map<String, String> headers;
}

class Files {
  Files._();

  /// ダウンロードURL（Firebase）を覚えておく。前は3D表示を描き直すたびに、部品ごとに問い合わせていた（2026-11-24）。
  /// 覚えるのは、置いたあと書き換えないファイルだけ：手のメッシュ（採寸ごとの ID）と、版ごとのプレビュー用STL。
  /// 確認用の画像（views/*.png、確認の回ごとに上書き）と印刷用STL（print/、準備のたびに上書き）は覚えない
  /// （上書きでURLの鍵が変わると、覚えた古いURLでは読めなくなる）
  static final _urls = <String, String>{};
  static bool _immutable(String path) =>
      (path.contains('/hand/') && path.endsWith('.glb')) || path.endsWith('.preview.stl');

  static Future<FileRef> resolve(String path) async {
    if (path.startsWith('demo/') || Config.mockApi) {
      return FileRef(path.startsWith('demo/') ? path : 'demo/missing');
    }
    if (Config.isFirebase) {
      final hit = _urls[path];
      if (hit != null) return FileRef(hit);
      final url = await FirebaseStorage.instance.ref(path).getDownloadURL();
      if (_immutable(path)) _urls[path] = url;
      return FileRef(url);
    }
    final (k, v) = await Session.instance.authHeader();
    return FileRef('${Config.apiBase}/v1/files/$path', {k: v});
  }
}
