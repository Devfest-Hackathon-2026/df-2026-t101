import 'package:flutter/material.dart';

import '../config.dart';
import '../data/session.dart';
import '../widgets/ui.dart';

/// S0 ログイン（docs/screens.md S0）。本番は Google、開発は名前だけの簡易ログイン
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.redirect});
  final String redirect;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController(text: 'demo-user');
  bool _busy = false;
  String? _error;

  void _go() {
    final to = widget.redirect == '/login' ? '/' : widget.redirect;
    Navigator.of(context).pushNamedAndRemoveUntil(to, (r) => false);
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Session.instance.signInGoogle();
      if (mounted) _go();
    } catch (e) {
      setState(
        () => _error =
            'ログインできませんでした。ポップアップがブロックされた場合は、ブラウザのアドレス欄の右の表示から、このサイトのポップアップを許可してください。（$e）',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: '自助具ジェネレーター',
      bottom: Config.isFirebase
          ? FilledButton.icon(
              onPressed: _busy ? null : _google,
              icon: const Icon(Icons.login),
              label: const Text('Googleでログイン'),
            )
          : FilledButton(
              onPressed: () {
                Session.instance.signInDev(_name.text);
                _go();
              },
              child: const Text('はじめる（開発用のログイン）'),
            ),
      children: [
        const SizedBox(height: 8),
        const Text(
          'こぶしの形に合わせて、筆やペンを付けるカバーを作ります。',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const InfoCard(
          icon: Icons.privacy_tip_outlined,
          child: Text(
            '手の動画は保存しません。手の3Dの形を作るために、手の部分を切り抜いた画像を最大8枚だけ送ります'
            '（画像は保存しません。作った手の3Dの形は保存します）。',
          ),
        ),
        if (!Config.isFirebase) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名前（英数字。開発用）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (_error != null) ErrorCard(message: _error!),
      ],
    );
  }
}
