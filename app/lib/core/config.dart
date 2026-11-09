/// ビルド時の設定（`--dart-define`）。docs/architecture.md §4、impl の受け渡しの決まり §2
class Config {
  Config._();

  /// 生成API（Cloud Run）。開発では localhost:8080
  static const apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:8080',
  );

  /// 手のメッシュ復元（hand-mesh、Cloud Run GPU）。開発では localhost:8081
  static const handMeshBase = String.fromEnvironment(
    'HAND_MESH_BASE',
    defaultValue: 'http://localhost:8081',
  );

  /// `dev`：名前を入れるだけの簡易ログイン（X-User ヘッダー）。`firebase`：Googleでログイン（IDトークン）
  static const authMode = String.fromEnvironment(
    'AUTH_MODE',
    defaultValue: 'dev',
  );
  static bool get isFirebase => authMode == 'firebase';

  /// true なら、生成APIと hand-mesh の代わりに、api.md の例の応答を返すモックを使う（画面だけ通すとき）
  static const mockApi = bool.fromEnvironment('MOCK_API');

  /// Firebase の設定値（env/example.json の値を `--dart-define` で渡す。秘密情報ではないがリポジトリには入れない）
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAuthDomain = String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
  );
  static const firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseStorageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const firebaseMessagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
}
