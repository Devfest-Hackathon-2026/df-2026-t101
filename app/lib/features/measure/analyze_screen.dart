import 'dart:async';

import 'package:flutter/material.dart';

import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/measure/keep_recording.dart';
import 'package:jijogu_app/features/measure/measure_confirm_screen.dart';
import 'package:jijogu_app/features/measure/measure_engine.dart';

/// 解析 → 手の3D（hand-mesh）→ 採寸の保存（PUT measurement）。docs/screens.md S3「手の3Dの計算」
class AnalyzeScreen extends StatefulWidget {
  const AnalyzeScreen({
    super.key,
    required this.caseId,
    required this.hand,
  });
  final String caseId;
  final String hand;
  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> with KeepRecording {
  /// 段階の一覧（Figma の M3/Step item の並び）。先頭3つは解析エンジンが出す段階の名前と同じ
  static const _steps = [
    'フレームを選んでいます',
    '手の形を調べています',
    'まとめています',
    '手の3Dの形を作っています',
    '手の3Dを実寸にしています',
  ];
  String _stage = 'フレームを選んでいます';
  int _step = 0;
  int _i = 0;
  int _n = 0;
  double? _value;
  String? _error;
  bool _retake = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _error = null;
      _retake = false;
      _stage = _steps[0];
      _step = 0;
      _n = 0;
      _value = null;
    });
    final eng = MeasureEngine.instance;
    try {
      final a = await eng.analyze(
        (stage, i, n) => setState(() {
          _stage = stage;
          final k = _steps.indexOf(stage);
          if (k >= 0) _step = k;
          _i = i;
          _n = n;
          _value = n == 0 ? null : i / n;
        }),
      );
      setState(() {
        _stage = '手の3Dの形を作っています';
        _step = 3;
        _n = 0;
        _value = null;
      });
      // 起動待ち・混雑は自動で最大3回、合わせて5分まで（RATE_LIMITED・GENERATION_DISABLED はやり直さない）
      Map<String, dynamic>? mesh;
      final started = DateTime.now();
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          mesh = await eng.callHandMesh(widget.caseId, widget.hand);
          break;
        } on EngineError catch (e) {
          final noRetry = const {
            'RATE_LIMITED',
            'GENERATION_DISABLED',
            'CONSENT_REQUIRED',
            'NO_HAND_DETECTED',
          }.contains(e.code);
          if (noRetry ||
              !e.retryable ||
              attempt == 3 ||
              DateTime.now().difference(started).inMinutes >= 5) {
            rethrow;
          }
          setState(() => _stage = '手の3Dを作る準備をしています（1〜3分。$attempt/3回目）');
          await Future<void>.delayed(Duration(seconds: 10 * attempt));
        }
      }
      setState(() {
        _stage = '手の3Dを実寸にしています';
        _step = 4;
      });
      final m = Map<String, dynamic>.from(mesh!['measurement']);
      final r = await Api.instance.put(
        '/v1/cases/${widget.caseId}/measurement',
        m,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MeasureConfirmScreen(
            caseId: widget.caseId,
            measurement: m,
            saved: Map<String, dynamic>.from(r),
            repFrames: [
              for (final f in a['rep_frames'] as List)
                Map<String, dynamic>.from(f),
            ],
            stats: Map<String, dynamic>.from(a['stats']),
          ),
        ),
      );
    } on EngineError catch (e) {
      setState(() {
        _error = switch (e.code) {
          'ENGINE_ERROR' => e.message,
          'RATE_LIMITED' => '本日の利用上限に達しました。明日もう一度試してください。',
          'GENERATION_DISABLED' => 'いまは計算を停止しています。',
          'CONSENT_REQUIRED' => '同意の記録がありません。撮影の画面からやり直してください。',
          'NO_HAND_DETECTED' => '手の3Dを作れませんでした。手と1円玉がよく写るように撮り直してください。',
          _ =>
            'いまは手の3Dを作れません。動画は保存していないので、少し時間をおいて、もう一度撮影してください（約1分）。\n（${e.message}）',
        };
        _retake = !e.retryable;
      });
    } on ApiError catch (e) {
      setState(() {
        _error = e.message;
        _retake = !e.retryable;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  // Figma S3「解析中」（22:1217）
  @override
  Widget build(BuildContext context) {
    final sub = AppText.labelLarge.copyWith(color: AppColors.onSurfaceVariant);
    return keepRecording(
      AppPage(
        title: '手を調べています',
        bottom: _error == null
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_retake)
                    FilledButton.icon(
                      onPressed: _run,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('もう一度試す'),
                    ),
                  if (!_retake) const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: leaveToRetake,
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('撮り直す'),
                  ),
                ],
              ),
        children: [
          if (_error == null) ...[
            Row(
              children: [
                const _LoadingMark(),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Text(_stage, style: AppText.headlineSmall),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '画面を閉じると、撮影からやり直しになります。',
                        style: AppText.bodyLarge.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: Text(_steps[_step], style: sub)),
                if (_n > 0) Text('$_i / $_n枚', style: sub),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _value),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  for (final (k, label) in _steps.indexed)
                    _StageRow(
                      label: label,
                      state: k < _step
                          ? _StageState.done
                          : k == _step
                          ? _StageState.current
                          : _StageState.todo,
                    ),
                ],
              ),
            ),
          ] else
            ErrorCard(message: _error!),
          const SizedBox(height: 12),
          const InfoCard(
            tone: NoticeTone.info,
            icon: Icons.lock_rounded,
            child: Text(
              '動画はこの端末の中だけで調べています。外に送るのは、手の3Dを作るための手の部分の画像（最大8枚）だけで、画像は保存しません。',
            ),
          ),
        ],
      ),
    );
  }
}

/// 処理中の印（M3 の Loading indicator の代わり。色の付いた丸の中で回る）。
/// 必ず「いま何をしているか」の文と一緒に出す
class _LoadingMark extends StatelessWidget {
  const _LoadingMark();
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 48,
      height: 48,
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppColors.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: const CircularProgressIndicator(
        strokeWidth: 3,
        color: AppColors.onPrimaryContainer,
      ),
    ),
  );
}

enum _StageState { done, current, todo }

/// 処理の段階の1行（Figma の M3/Step item：済み／いま／これから）。
/// 色だけで伝えないよう、印のアイコンと文字の太さも変え、読み上げにも状態を添える
class _StageRow extends StatelessWidget {
  const _StageRow({required this.label, required this.state});
  final String label;
  final _StageState state;
  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon, style, said) = switch (state) {
      _StageState.done => (
        AppColors.primary,
        AppColors.onPrimary,
        Icons.check_circle_rounded,
        AppText.bodyLarge,
        '済み',
      ),
      _StageState.current => (
        AppColors.primaryContainer,
        AppColors.onPrimaryContainer,
        Icons.hourglass_top_rounded,
        AppText.titleMedium,
        'いま',
      ),
      _StageState.todo => (
        AppColors.surfaceContainerHighest,
        AppColors.onSurfaceVariant,
        Icons.remove_rounded,
        AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
        'これから',
      ),
    };
    return Semantics(
      label: '$label（$said）',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: fg),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(label, style: style)),
            ],
          ),
        ),
      ),
    );
  }
}
