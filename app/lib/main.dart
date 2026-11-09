import 'package:flutter/material.dart';

import 'package:jijogu_app/app/router.dart';
import 'package:jijogu_app/core/session.dart';
import 'package:jijogu_app/core/ui/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 読み上げ用の情報は、起動時には作らない（2026-11-09 にやめた）。常に作ると、画面が変わるたびに読み上げ用の部品も
  // 作り直し、スマホが重かった（計算が約25%増えた）。読み上げ（VoiceOver など）を使う人は、Flutter Web が出す
  // 「読み上げを有効にする」のボタン（Enable accessibility）を1回押すと有効になる（docs/screens.md §2）
  await Session.instance.init();
  runApp(const JijoguApp());
}

class JijoguApp extends StatelessWidget {
  const JijoguApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hand-Some-Fit',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      initialRoute: '/',
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
