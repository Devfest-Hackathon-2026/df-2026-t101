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
  static const maxSec = 10.0;
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
        _status = '手と1円玉が画面に入るように構えてください';
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

  @override
  Widget build(BuildContext context) {
    final left = (maxSec - _sec).clamp(0, maxSec).ceil();
    return AppPage(
      title: _recording ? '撮っています（あと$left秒）' : 'カメラで撮る',
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_recording)
            FilledButton.icon(
              onPressed: _ready && _error == null ? _record : null,
              icon: const Icon(
                Icons.fiber_manual_record,
                color: Color(0xFFE5484D),
              ),
              label: const Text('撮り始める（10秒）'),
            )
          else
            FilledButton.icon(
              onPressed: _sec >= 5 ? () => _eng.stopRecording() : null,
              icon: const Icon(Icons.stop),
              label: Text(_sec >= 5 ? '撮り終える' : '5秒以上撮ってください'),
            ),
          if (_cameras > 1 && !_recording) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _eng.switchCamera(),
              icon: const Icon(Icons.cameraswitch_outlined),
              label: const Text('カメラを切り替える'),
            ),
          ],
        ],
      ),
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                HtmlElementView.fromTagName(
                  tagName: 'div',
                  onElementCreated: (Object el) {
                    final div = el as web.HTMLDivElement;
                    div.style.width = '100%';
                    div.style.height = '100%';
                    unawaited(_open(div));
                  },
                ),
                if (_recording)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: LinearProgressIndicator(
                      value: _sec / maxSec,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_error != null)
          InfoCard(
            color: const Color(0xFFFDECEA),
            icon: Icons.error_outline,
            child: Text(_error!),
          )
        else
          InfoCard(
            icon: _recording
                ? (_handVisible ? Icons.check_circle : Icons.pan_tool_outlined)
                : Icons.info_outline,
            color: _recording && !_handVisible
                ? const Color(0xFFFFF4E0)
                : AppColors.card,
            child: Text(
              _recording
                  ? (_handVisible
                        ? '手が見えています。そのまま、ゆっくり半周してください。'
                        : '手が見えません。手と1円玉が画面に入るようにしてください。')
                  : _status,
            ),
          ),
        const InfoCard(
          child: Text(
            'いつもの握った形のまま、手の甲を上にしてこぶしを置きます。指を無理に開かないでください。'
            '1円玉はこぶしの前（指の付け根の関節の前）3〜5cmに平らに置き、手と1円玉が画面いっぱいに写るくらい近づけます。'
            '親指側の低い所から、手の上を通って小指側まで、ゆっくり半周し、途中でこぶしの前（指の背と関節の出っ張り）も写します。'
            'PCのカメラで撮るときは、手は机に置いたまま、カメラ（ノートPCなど）の方を動かしてください。',
          ),
        ),
      ],
    );
  }
}
