import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../bridge/measure_engine.dart';
import '../widgets/ui.dart';
import 'capture.dart';

/// アプリの中でカメラを開いて撮る（スマホは背面カメラ、PCはWebカメラ）。
/// 映像に手の骨組みを重ね、撮っている間は残り時間と「手が見えているか」を出す。
class LiveCaptureScreen extends StatefulWidget {
  const LiveCaptureScreen({
    super.key,
    required this.caseId,
    required this.hand,
  });
  final String caseId;
  final String hand;
  @override
  State<LiveCaptureScreen> createState() => _LiveCaptureScreenState();
}

class _LiveCaptureScreenState extends State<LiveCaptureScreen> {
  static const maxSec = 20.0; // 撮影の目安は15〜20秒（2026-11-08 に10秒から。短いという声があった）
  static const minSec = 15.0; // これより前には止められない（前は5秒）
  final _eng = MeasureEngine.instance;
  String _status = 'カメラを準備しています（初回は少し時間がかかります）';
  bool _ready = false;
  bool _recording = false;
  bool _handVisible = false;
  double _sec = 0;
  int _cameras = 0;
  String? _error;

  Future<void> _open(web.HTMLElement el) async {
    try {
      final r = await _eng.startCamera(el);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _cameras = (r['cameras'] as num?)?.toInt() ?? 1;
        _status = '1円玉を手の甲に置き、こぶし全体が画面に入るように構えてください';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _record() async {
    setState(() {
      _recording = true;
      _sec = 0;
    });
    try {
      final first = await _eng.record(maxSec, (sec, hand) {
        if (mounted) {
          setState(() {
            _sec = sec;
            _handVisible = hand;
          });
        }
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CoinScreen(
            caseId: widget.caseId,
            hand: widget.hand,
            first: first,
            video: true,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    if (_recording) unawaited(_eng.stopRecording());
    unawaited(_eng.stopCamera());
    super.dispose();
  }

  // Figma S3「撮影中（カメラ）」（22:1124）。黒い背景のカメラの画面
  @override
  Widget build(BuildContext context) {
    final left = (maxSec - _sec).clamp(0, maxSec).ceil();
    const fg = AppColors.inverseOnSurface;
    final title = _recording ? '撮っています（あと$left秒）' : 'カメラで撮る';
    final shutterLabel = _recording
        ? (_sec >= minSec ? '撮り終える' : '${minSec.round()}秒以上撮ってください')
        : '撮り始める（20秒）';
    final VoidCallback? onShutter = _recording
        ? (_sec >= minSec ? () => _eng.stopRecording() : null)
        : (_ready && _error == null ? _record : null);

    final (statusTone, statusText) = _error != null
        ? (_Tone.error, _error!)
        : _recording
        ? (_handVisible
              ? (_Tone.success, '手が見えています。手は動かさずに、スマホをこぶしのまわりでゆっくり半周させてください。')
              : (_Tone.warning, '手が見えません。こぶし全体が画面に入るようにしてください。'))
        : (_Tone.info, _status);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppPage.maxWidth),
            child: Column(
              children: [
                // 上：閉じる・録画中の札・残り秒数
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close_rounded),
                        color: fg,
                        tooltip: '閉じる',
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Semantics(
                          header: true,
                          label: title,
                          child: ExcludeSemantics(
                            child: _recording
                                ? Row(
                                    children: [
                                      const _RecBadge(),
                                      const Spacer(),
                                      Text(
                                        'あと$left秒',
                                        style: AppText.titleLarge.copyWith(
                                          color: fg,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    title,
                                    style: AppText.titleLarge.copyWith(
                                      color: fg,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  // ListView だと、下まで送ったときにカメラの部品が作り直されるので使わない
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                            ),
                            child: AspectRatio(
                              aspectRatio: 3 / 4,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(28),
                                child: ColoredBox(
                                  color: AppColors.inverseSurface,
                                  child: HtmlElementView.fromTagName(
                                    tagName: 'div',
                                    onElementCreated: (Object el) {
                                      final div = el as web.HTMLDivElement;
                                      div.style.width = '100%';
                                      div.style.height = '100%';
                                      unawaited(_open(div));
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 手が見えているか・進み具合の棒
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                          child: Column(
                            children: [
                              _StatusChip(tone: statusTone, text: statusText),
                              if (_recording) ...[
                                const SizedBox(height: 12),
                                LinearProgressIndicator(value: _sec / maxSec),
                              ],
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(0, 8, 0, 16),
                          child: InfoCard(
                            icon: Icons.info_outline_rounded,
                            child: Text(
                              'いつもの握った形のまま、手の甲を上にしてこぶしを置きます。指を無理に開かないでください。'
                              '1円玉は手の甲のまん中（手首と指の付け根の間）に平らに置きます。'
                              '手は動かさずに、スマホのほうを親指側から手の甲の上、小指側へと、こぶしのまわりを半周させます。途中でこぶしの前（指の背と関節の出っ張り）が写る所も通ります。こぶし全体がいつも画面に入るようにします。'
                              '家族や支援者に撮ってもらってもかまいません。',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 下：カメラの切り替え・撮る／撮り終えるボタン
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: _cameras > 1 && !_recording
                            ? IconButton.filled(
                                onPressed: () => _eng.switchCamera(),
                                icon: const Icon(Icons.cameraswitch_rounded),
                                tooltip: 'カメラを切り替える',
                                style: IconButton.styleFrom(
                                  backgroundColor: AppColors.inverseSurface,
                                  foregroundColor: fg,
                                  fixedSize: const Size(56, 56),
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 40),
                      _Shutter(
                        recording: _recording,
                        label: shutterLabel,
                        onPressed: onShutter,
                      ),
                      const SizedBox(width: 40),
                      const SizedBox(width: 56, height: 56),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: ExcludeSemantics(
                    child: Text(
                      shutterLabel,
                      textAlign: TextAlign.center,
                      style: AppText.titleMedium.copyWith(color: fg),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「録画中」の札（赤い地に白い点と文字）
class _RecBadge extends StatelessWidget {
  const _RecBadge();
  @override
  Widget build(BuildContext context) {
    final onError = Theme.of(context).colorScheme.onError;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
      decoration: BoxDecoration(
        color: AppColors.error,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: onError, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('録画中', style: AppText.labelLarge.copyWith(color: onError)),
        ],
      ),
    );
  }
}

enum _Tone { info, success, warning, error }

/// カメラの下の状態の札（Figma の「手が見えています」）。色だけで伝えないよう、アイコンも変える
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.tone, required this.text});
  final _Tone tone;
  final String text;
  @override
  Widget build(BuildContext context) {
    final (bg, fg, ic, icon) = switch (tone) {
      _Tone.info => (
        AppColors.surfaceContainerHigh,
        AppColors.onSurface,
        AppColors.primary,
        Icons.info_outline_rounded,
      ),
      _Tone.success => (
        AppColors.successContainer,
        AppColors.onSuccessContainer,
        AppColors.success,
        Icons.check_circle_rounded,
      ),
      _Tone.warning => (
        AppColors.warningContainer,
        AppColors.onWarningContainer,
        AppColors.warning,
        Icons.pan_tool_rounded,
      ),
      _Tone.error => (
        AppColors.errorContainer,
        AppColors.onErrorContainer,
        AppColors.error,
        Icons.error_outline_rounded,
      ),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(icon, size: 20, color: ic),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text, style: AppText.bodyLarge.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}

/// 撮る／撮り終えるの丸いボタン（白い輪の中に、撮る前は赤い丸、撮っている間は赤い四角）。
/// 押せないときは薄くし、ボタンの下の文で理由を出す
class _Shutter extends StatelessWidget {
  const _Shutter({
    required this.recording,
    required this.label,
    required this.onPressed,
  });
  final bool recording;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final size = recording ? 32.0 : 60.0;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: Opacity(
        opacity: onPressed == null ? 0.38 : 1,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(
            side: BorderSide(color: AppColors.inverseOnSurface, width: 4),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 80,
              height: 80,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: AppColors.error,
                    borderRadius: BorderRadius.circular(recording ? 8 : 30),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
