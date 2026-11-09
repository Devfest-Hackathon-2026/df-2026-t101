import 'dart:async';

import 'package:flutter/material.dart';

import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/measure/coin_screen.dart';
import 'package:jijogu_app/features/measure/live_capture_screen.dart';
import 'package:jijogu_app/features/measure/measure_engine.dart';

/// 手の3Dを作るための撮影への同意の版。変えたら、同意を取り直す
const consentVersion = 'mesh-consent-2';

/// S3 撮影と解析（同意 → 撮り方 → アプリの中のカメラ／撮った動画）。docs/screens.md S3
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.caseId});
  final String caseId;
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  bool? _consented;
  bool _busy = false;
  String? _status;
  String? _error;
  // 動画を選ぶ画面を開いている間（「やめる」を出す）。iPhone では、選ばずに閉じたことがページに伝わらず、
  // 「動画を選んでください」のまま進めなくなった（2026-11-09）。やめたら番号を進め、あとから届いた結果は捨てる
  bool _waitingPick = false;
  int _pickGen = 0;
  String _hand = 'right';
  String _fingerState = 'fist';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await Api.instance.get('/v1/cases/${widget.caseId}');
      setState(() {
        _hand = c['requirements']?['hand_side'] ?? 'right';
        _fingerState = c['requirements']?['finger_state'] ?? 'fist';
        _consented =
            c['mesh_consent_at'] != null &&
            c['consent_text_version'] == consentVersion;
      });
      if (_consented == true) {
        unawaited(MeasureEngine.instance.init());
        MeasureEngine.instance.warmHandMesh(); // 撮っている間に GPU の起動を終わらせる
      }
    } catch (e) {
      setState(() {
        _consented = false;
        _error = '$e';
      });
    }
  }

  Future<void> _consent() async {
    setState(() => _busy = true);
    try {
      await Api.instance.post('/v1/cases/${widget.caseId}/consent', {
        'mesh_consent': true,
        'consent_text_version': consentVersion,
      });
      setState(() => _consented = true);
      unawaited(MeasureEngine.instance.init()); // 裏で MediaPipe を読み込んでおく
      MeasureEngine.instance.warmHandMesh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancelPick() => setState(() {
    _pickGen++;
    _busy = false;
    _waitingPick = false;
    _status = null;
  });

  Future<void> _pickVideo() async {
    final gen = ++_pickGen;
    setState(() {
      _busy = true;
      _status = 'カメラを準備しています（初回は少し時間がかかります）';
    });
    try {
      final eng = MeasureEngine.instance;
      await eng.init();
      if (gen != _pickGen || !mounted) return;
      setState(() {
        _waitingPick = true;
        _status = '動画を選んでください';
      });
      final r = await eng.pickVideo((stage, i, n) {
        if (gen != _pickGen || !mounted) return;
        setState(() {
          _waitingPick = false; // 選んだ動画を読み始めた
          _status = '$stage（$i/$n）';
        });
      });
      if (gen != _pickGen) return; // 「やめる」を押したあとに届いた
      if (r['cancelled'] == true) {
        if (r['message'] != null && mounted) showError(context, r['message']);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CoinScreen(
            caseId: widget.caseId,
            hand: _hand,
            first: r,
          ),
        ),
      );
    } on EngineError catch (e) {
      if (mounted && gen == _pickGen) {
        showError(
          context,
          'この動画は読めませんでした。カメラの設定を「互換性優先」にして撮り直すか、「カメラで撮る」で撮ってください。（${e.message}）',
        );
      }
    } catch (e) {
      if (mounted && gen == _pickGen) showError(context, e);
    } finally {
      if (mounted && gen == _pickGen) {
        setState(() {
          _busy = false;
          _waitingPick = false;
          _status = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_consented == null) {
      return const AppPage(
        title: '撮影の前に',
        children: [BusyCard(text: '読み込んでいます')],
      );
    }
    if (_consented == false) {
      // Figma S3「撮影の前の同意」（22:948）
      return AppPage(
        title: '撮影の前に',
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: _busy ? null : _consent,
              child: const Text('同意して進む'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                minimumSize: const Size(64, 56),
                textStyle: AppText.titleMedium,
              ),
              child: const Text('やめる'),
            ),
          ],
        ),
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: _IconBox(icon: Icons.verified_user_rounded),
          ),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text('手の3Dの形を作るための同意', style: AppText.headlineSmall),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              children: [
                _ConsentRow(
                  icon: Icons.image_rounded,
                  label: '送るもの',
                  text: '手の3Dの形を作るため、手の部分を切り抜いた画像を最大8枚',
                ),
                _ConsentRow(
                  icon: Icons.monitor_rounded,
                  label: 'どこで',
                  text: 'シンガポールのサーバーに送り、計算のためだけに使います',
                ),
                _ConsentRow(
                  icon: Icons.lock_rounded,
                  label: '保存しないもの',
                  text: '送った画像は保存しません。動画そのものは、この端末から外に出しません',
                ),
                _ConsentRow(
                  icon: Icons.back_hand_rounded,
                  label: '保存するもの',
                  text: '作った手の3Dの形（写真ではありません）。作った形を確かめるために保存します',
                ),
                _ConsentRow(
                  icon: Icons.close_rounded,
                  label: '消すとき',
                  text: 'ケースを消すと、手の3Dの形も消えます',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '同意しない場合は、撮影に進めません。',
            style: AppText.bodyLarge.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '同意の文の版：$consentVersion',
            style: AppText.bodySmall.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorCard(message: _error!),
          ],
        ],
      );
    }
    // Figma S3「撮り方の案内」（22:1032）
    final smallOutline = OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: AppText.labelLarge,
      iconSize: 18,
    );
    return AppPage(
      title: '手を撮る',
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          LiveCaptureScreen(caseId: widget.caseId, hand: _hand),
                    ),
                  ),
            icon: const Icon(Icons.photo_camera_rounded),
            label: const Text('カメラで撮る'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickVideo,
            style: smallOutline,
            icon: const Icon(Icons.videocam_rounded),
            label: const Text('撮った動画を選ぶ'),
          ),
        ],
      ),
      children: [
        if (_status != null) ...[
          BusyCard(text: _status!),
          if (_waitingPick)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _cancelPick,
                child: const Text('やめる'),
              ),
            ),
          const SizedBox(height: 12),
        ],
        // 撮り方の図はやめた（2026-11-08、チームの決定。手順の文だけで足りるため）。
        // 撮り方（2026-11-09 に変えた）：1円玉は手の甲のまん中に置き、手は動かさず、カメラのほうを半周させる。
        // 机の上の1円玉はこぶしの高さの分だけカメラから遠く、手が1.2〜1.5倍に大きく測られた。手の甲なら測る点と同じ高さ。
        // 手を回すと1円玉が落ちるので、カメラを動かす（1円玉は手と一緒に写るので、画面から出る心配もない）
        Semantics(
          header: true,
          child: Text(
            'カメラをこぶしのまわりで動かして撮ります（15〜20秒）',
            style: AppText.titleLarge,
          ),
        ),
        const SizedBox(height: 16),
        for (final (i, s) in const [
          '机の上に、いつもの握った形のまま、手の甲を上にしてこぶしを置きます。',
          '1円玉を、手の甲のまん中（手首と指の付け根の間）に平らに置きます。指の付け根の出っ張りの上は避けます。',
          '撮っているあいだ、手は動かしません。スマホを持って、こぶし全体（指の側も手首も）がいつも画面に入る近さで構えます。家族や支援者に撮ってもらってもかまいません。',
          '15〜20秒かけて、スマホを親指側から手の甲の上、小指側へと、こぶしのまわりを半周させます。途中で、こぶしの前（指の背と関節の出っ張り）が写る所も通ります。',
          'PCで撮るときは、ノートPCを持って同じように動かします。動かしにくいときは、スマホで撮るのがおすすめです。',
        ].indexed)
          _StepRow(number: i + 1, text: s),
        const SizedBox(height: 4),
        InfoCard(
          tone: NoticeTone.warning,
          child: Text(
            _fingerState == 'straight'
                ? '軽く握った形で撮ってください。指を無理に動かさないでください。'
                : '指を無理に開かないでください。いつもの握った形のまま撮ります。',
          ),
        ),
        const SizedBox(height: 8),
        const InfoCard(
          tone: NoticeTone.helper,
          child: Text('家族や支援者に撮ってもらうのがおすすめです。'),
        ),
      ],
    );
  }
}

/// 色の付いた角丸の箱に入れたアイコン（Figma の同意画面の上の飾り）
class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(
      color: AppColors.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Icon(icon, size: 28, color: AppColors.onSecondaryContainer),
  );
}

/// 同意の1行（アイコン＋小さな見出し＋本文）
class _ConsentRow extends StatelessWidget {
  const _ConsentRow({
    required this.icon,
    required this.label,
    required this.text,
  });
  final IconData icon;
  final String label;
  final String text;
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 24, color: AppColors.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.bodySmall.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                Text(text, style: AppText.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// 撮り方の手順の1行（丸の中の番号＋本文）
class _StepRow extends StatelessWidget {
  const _StepRow({required this.number, required this.text});
  final int number;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: AppText.titleSmall.copyWith(
                color: AppColors.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: AppText.bodyLarge)),
        ],
      ),
    ),
  );
}
