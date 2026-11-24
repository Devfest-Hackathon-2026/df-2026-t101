import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/ui.dart';

/// S3 録画中に閉じようとしたとき（左上の「×」・ブラウザの戻る）に確かめる。
/// 片手でスマホを回していると、持ち直したときに「×」に触れ、撮った分が消えていたため（2026-11-22）。
/// やめるなら true、撮影を続けるなら false（外を押して閉じたときも続ける）
Future<bool> confirmStopRecording(BuildContext context) async {
  final stop = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('撮影をやめますか？'),
      content: const Text('ここまで撮った分は消えます。'),
      // ボタンは縦に並べて幅いっぱいにする（主なボタンの決まり。小さな文字のボタンを横に並べない）
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('撮影を続ける'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(c).pop(true),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
              child: const Text('やめる'),
            ),
          ],
        ),
      ],
    ),
  );
  return stop ?? false;
}
