import 'package:flutter/material.dart';

/// 撮影のあとの画面で、うっかり戻って撮った動画を失わないようにする（iPhone の Safari のスワイプなど。2026-11-09）。
/// 戻る操作が働いたら確かめ、「撮り直す」を選んだときだけ戻る
mixin KeepRecording<T extends StatefulWidget> on State<T> {
  bool _leaving = false;

  /// 撮り直す（確かめずに戻る）
  void leaveToRetake() {
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Widget keepRecording(Widget child) => PopScope(
    canPop: _leaving,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final retake = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('撮り直しますか？'),
          content: const Text('撮った動画は消えます。続けるときは「続ける」を押してください。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('続ける'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('撮り直す'),
            ),
          ],
        ),
      );
      if (retake == true && mounted) leaveToRetake();
    },
    child: child,
  );
}
