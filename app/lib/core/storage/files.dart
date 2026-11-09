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

  static Future<FileRef> resolve(String path) async {
    if (path.startsWith('demo/') || Config.mockApi) {
      return FileRef(path.startsWith('demo/') ? path : 'demo/missing');
    }
    if (Config.isFirebase) {
      final url = await FirebaseStorage.instance.ref(path).getDownloadURL();
      return FileRef(url);
    }
    final (k, v) = await Session.instance.authHeader();
    return FileRef('${Config.apiBase}/v1/files/$path', {k: v});
  }
}
