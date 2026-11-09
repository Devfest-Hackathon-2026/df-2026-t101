import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:jijogu_app/core/config.dart';
import 'package:jijogu_app/core/session.dart';
import 'package:jijogu_app/core/ui/ui.dart';

/// S0 ログイン（docs/screens.md S0、Figma「S0 ログイン」）。本番は Google、開発は名前だけの簡易ログイン
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
      title: 'Hand-Some-Fit',
      showAppBar: false,
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (Config.isFirebase)
            _GoogleSignInButton(onPressed: _busy ? null : _google)
          else
            FilledButton(
              onPressed: () {
                Session.instance.signInDev(_name.text);
                _go();
              },
              child: const Text('はじめる（開発用のログイン）'),
            ),
          const SizedBox(height: 8),
          Text(
            '作業療法士（OT）の確認を通してから印刷できます',
            textAlign: TextAlign.center,
            style: AppText.bodySmall.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ],
      ),
      children: [
        const SizedBox(height: 48),
        Center(
          child: Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(48),
            ),
            child: const Icon(
              Icons.back_hand_outlined,
              size: 72,
              color: AppColors.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Semantics(
          header: true,
          child: Text(
            'Hand-Some-Fit',
            textAlign: TextAlign.center,
            style: AppText.headlineMedium,
          ),
        ),
        const SizedBox(height: 24),
        const _GoogleColorBar(),
        const SizedBox(height: 24),
        Text(
          'スマホで撮ったこぶしの形から、筆やペンを持つためのカバーを作ります',
          textAlign: TextAlign.center,
          style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Step(
                color: AppColors.googleBlue,
                icon: Icons.chat_outlined,
                label: '1. 聞く',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: _Step(
                color: AppColors.googleRed,
                icon: Icons.photo_camera_outlined,
                label: '2. 撮る',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: _Step(
                color: AppColors.googleGreen,
                icon: Icons.print_outlined,
                label: '3. 刷る',
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline_rounded, color: AppColors.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('手の動画は保存しません', style: AppText.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '手の3Dの形を作るために、手の部分を切り抜いた画像を最大8枚だけ送ります'
                      '（画像は保存しません。作った手の3Dの形は保存します）',
                      style: AppText.supporting,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!Config.isFirebase) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名前（英数字。開発用）'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          ErrorCard(message: _error!),
        ],
      ],
    );
  }
}

/// アプリ名の下のGoogleの4色の線（飾り）
class _GoogleColorBar extends StatelessWidget {
  const _GoogleColorBar();
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (i, c) in const [
          AppColors.googleBlue,
          AppColors.googleRed,
          AppColors.googleYellow,
          AppColors.googleGreen,
        ].indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          Container(
            width: 28,
            height: 6,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 「聞く・撮る・刷る」の1つ
class _Step extends StatelessWidget {
  const _Step({required this.color, required this.icon, required this.label});
  final Color color;
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
    decoration: BoxDecoration(
      color: AppColors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
        const SizedBox(height: 8),
        Text(label, textAlign: TextAlign.center, style: AppText.titleSmall),
      ],
    ),
  );
}

/// 「Googleでログイン」（Googleのサインインボタンの見た目：白地・枠線・Gのロゴ）
class _GoogleSignInButton extends StatelessWidget {
  const _GoogleSignInButton({required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      backgroundColor: AppColors.surfaceContainerLowest,
      foregroundColor: AppColors.onSurface,
      side: const BorderSide(color: AppColors.outline),
      minimumSize: const Size.fromHeight(56),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset('assets/images/google_g.svg', width: 20, height: 20),
        const SizedBox(width: 12),
        const Text('Googleでログイン'),
      ],
    ),
  );
}
