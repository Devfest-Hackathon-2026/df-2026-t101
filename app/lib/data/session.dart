import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../config.dart';

/// ログインの状態。dev では名前を X-User に、firebase では Google のログインと IDトークンを使う（docs/screens.md S0）
class Session extends ChangeNotifier {
  Session._();
  static final instance = Session._();

  String? _devUser;
  bool _firebaseReady = false;

  bool get signedIn => Config.isFirebase
      ? FirebaseAuth.instance.currentUser != null
      : _devUser != null;
  String get displayName => Config.isFirebase
      ? (FirebaseAuth.instance.currentUser?.displayName ?? '')
      : (_devUser ?? '');
  String? get email => Config.isFirebase
      ? FirebaseAuth.instance.currentUser?.email
      : (_devUser == null ? null : '$_devUser@dev.local');

  /// 起動時に1回呼ぶ。dev は前回の名前を読む
  Future<void> init() async {
    if (Config.isFirebase) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: Config.firebaseApiKey,
          appId: Config.firebaseAppId,
          messagingSenderId: Config.firebaseMessagingSenderId,
          projectId: Config.firebaseProjectId,
          authDomain: Config.firebaseAuthDomain,
          storageBucket: Config.firebaseStorageBucket,
        ),
      );
      _firebaseReady = true;
      FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
    } else {
      try {
        _devUser = web.window.localStorage.getItem('jijogu.devUser');
      } catch (_) {
        _devUser = null;
      }
    }
  }

  /// dev の簡易ログイン（名前だけ）
  void signInDev(String name) {
    final n = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '');
    _devUser = n.isEmpty ? 'demo-user' : n;
    try {
      web.window.localStorage.setItem('jijogu.devUser', _devUser!);
    } catch (_) {}
    notifyListeners();
  }

  /// Googleでログイン（ポップアップ）
  Future<void> signInGoogle() async {
    if (!_firebaseReady) throw StateError('Firebase の準備ができていません');
    await FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider());
    notifyListeners();
  }

  Future<void> signOut() async {
    if (Config.isFirebase) {
      await FirebaseAuth.instance.signOut();
    } else {
      _devUser = null;
      try {
        web.window.localStorage.removeItem('jijogu.devUser');
      } catch (_) {}
    }
    notifyListeners();
  }

  /// API と hand-mesh に付けるヘッダー（名前, 値）
  Future<(String, String)> authHeader() async {
    if (Config.isFirebase) {
      final t = await FirebaseAuth.instance.currentUser?.getIdToken();
      return ('Authorization', 'Bearer ${t ?? ''}');
    }
    return ('X-User', _devUser ?? 'demo-user');
  }
}
