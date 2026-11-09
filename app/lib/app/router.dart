import 'package:flutter/material.dart';

import 'package:jijogu_app/app/paths.dart';
import 'package:jijogu_app/core/session.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/design/design_screen.dart';
import 'package:jijogu_app/features/home/home_screen.dart';
import 'package:jijogu_app/features/interview/interview_screen.dart';
import 'package:jijogu_app/features/login/login_screen.dart';
import 'package:jijogu_app/features/measure/capture_screen.dart';
import 'package:jijogu_app/features/print/print_screen.dart';
import 'package:jijogu_app/features/review/review_screen.dart';

/// 画面のパス（docs/screens.md §1）。ログインしていなければ S0 に移し、ログイン後に元のパスへ戻す
class AppRouter {
  AppRouter._();

  static String interview(String c) => Paths.interview(c);
  static String capture(String c) => Paths.capture(c);
  static String design(String c, String? d) => Paths.design(c, d);
  static String print(String c, String d) => Paths.print(c, d);
  static String review(String c) => Paths.review(c);

  static Route<dynamic> onGenerateRoute(RouteSettings s) {
    final name = s.name ?? '/';
    return MaterialPageRoute(
      settings: s,
      builder: (_) => ListenableBuilder(
        listenable: Session.instance,
        builder: (context, _) {
          if (!Session.instance.signedIn && name != '/login') {
            return LoginScreen(redirect: name);
          }
          return _build(name);
        },
      ),
    );
  }

  static Widget _build(String name) {
    final seg = Uri.parse(name).pathSegments;
    if (name == '/login') return const LoginScreen(redirect: '/');
    if (seg.isEmpty) return const HomeScreen();
    if (seg.length >= 3 && seg[0] == 'cases') {
      final c = seg[1];
      switch (seg[2]) {
        case 'interview':
          return InterviewScreen(caseId: c);
        case 'capture':
          return CaptureScreen(caseId: c);
        case 'designs' when seg.length >= 4:
          if (seg.length >= 5 && seg[4] == 'print') {
            return PrintScreen(caseId: c, designId: seg[3]);
          }
          return DesignScreen(
            caseId: c,
            designId: seg[3] == 'new' ? null : seg[3],
          );
      }
    }
    if (seg.length == 2 && seg[0] == 'review') {
      return ReviewScreen(caseId: seg[1]);
    }
    return const _NotFound();
  }
}

class _NotFound extends StatelessWidget {
  const _NotFound();
  @override
  Widget build(BuildContext context) => AppPage(
    title: 'ページがありません',
    bottom: FilledButton(
      onPressed: () =>
          Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false),
      child: const Text('ホームへ'),
    ),
    children: const [InfoCard(child: Text('このページは見つかりませんでした。'))],
  );
}
