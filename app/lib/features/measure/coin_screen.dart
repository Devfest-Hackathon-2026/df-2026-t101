import 'dart:async';

import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/measure/analyze_screen.dart';
import 'package:jijogu_app/features/measure/keep_recording.dart';
import 'package:jijogu_app/features/measure/measure_engine.dart';

/// S4 1円玉の確認（自動で見つけた輪を確かめ、違うときだけタップ）。docs/screens.md S4
class CoinScreen extends StatefulWidget {
  const CoinScreen({
    super.key,
    required this.caseId,
    required this.hand,
    required this.first,
  });
  final String caseId;
  final String hand;
  final Map<String, dynamic> first;
  @override
  State<CoinScreen> createState() => _CoinScreenState();
}

class _CoinScreenState extends State<CoinScreen> with KeepRecording {
  late String _image = widget.first['first'];
  late final double _w = (widget.first['width'] as num).toDouble();
  late final double _h = (widget.first['height'] as num).toDouble();
  bool? _ok;
  bool _tooSmall = false;
  bool _busy = false;
  bool _auto = true;

  @override
  void initState() {
    super.initState();
    _autoFind();
  }

  Future<void> _autoFind() async {
    setState(() => _busy = true);
    try {
      final r = await MeasureEngine.instance.autoCoin();
      if (!mounted) return;
      setState(() {
        _image = r['image'];
        _ok = r['ok'] == true;
        _tooSmall = r['too_small'] == true;
        _auto = true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tap(TapUpDetails d, Size size) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await MeasureEngine.instance.setCoin(
        d.localPosition.dx / size.width,
        d.localPosition.dy / size.height,
      );
      setState(() {
        _image = r['image'];
        _ok = r['ok'] == true;
        _tooSmall = r['too_small'] == true;
        _auto = false;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = _busy
        ? '1円玉を探しています'
        : _ok == null
        ? '写真の中の1円玉をタップ（PCはクリック）してください。'
        : _ok! && _auto
        ? '1円玉を自動で見つけました。黄色い輪が1円玉に重なっていれば進みます。違う所に輪があるときは、1円玉をタップしてください。'
        : _ok!
        ? '黄色い輪が1円玉に重なっていれば進みます。ずれていたら、もう一度タップします。'
        : _tooSmall
        ? '1円玉が小さく写りすぎています。カメラを手と1円玉に近づけて（またはズームして）撮り直してください。'
        : _auto
        ? '1円玉を自動では見つけられませんでした。写真の中の1円玉をタップ（PCはクリック）してください。'
        : 'うまく見つかりませんでした（赤い十字がタップした所です）。1円玉の上をもう一度タップしてください。';
    // Figma S4「1円玉の確認」（23:1176）。色だけで伝えないよう、お知らせのアイコンも状態で変える
    final tone = _busy
        ? NoticeTone.progress
        : _ok == false
        ? NoticeTone.warning
        : NoticeTone.info;
    return keepRecording(
      AppPage(
        title: '1円玉の確認',
        bottom: FilledButton(
          onPressed: _ok == true && !_busy
              ? () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => AnalyzeScreen(
                      caseId: widget.caseId,
                      hand: widget.hand,
                    ),
                  ),
                )
              : null,
          child: const Text('この1円玉で解析する'),
        ),
        children: [
          if (_ok == true) ...[
            Semantics(
              header: true,
              child: Text('黄色い輪が1円玉に重なっていますか？', style: AppText.headlineSmall),
            ),
            const SizedBox(height: 16),
          ],
          AspectRatio(
            aspectRatio: _w / _h,
            child: LayoutBuilder(
              builder: (context, c) => Semantics(
                label: '写真。黄色い輪が1円玉でなければ、1円玉をタップしてください',
                image: true,
                child: GestureDetector(
                  excludeFromSemantics: true,
                  onTapUp: (d) => _tap(d, Size(c.maxWidth, c.maxHeight)),
                  child: MouseRegion(
                    cursor: _busy
                        ? SystemMouseCursors.wait
                        : SystemMouseCursors.click,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            dataUrlBytes(_image),
                            fit: BoxFit.fill,
                            gaplessPlayback: true,
                          ),
                          if (_busy)
                            Center(
                              child: Container(
                                width: 56,
                                height: 56,
                                padding: const EdgeInsets.all(14),
                                decoration: const BoxDecoration(
                                  color: AppColors.primaryContainer,
                                  shape: BoxShape.circle,
                                ),
                                child: const CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: AppColors.onPrimaryContainer,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          InfoCard(
            tone: tone,
            child: Semantics(liveRegion: true, child: Text(msg)),
          ),
          const SizedBox(height: 8),
          const HelperNote(),
        ],
      ),
    );
  }
}
