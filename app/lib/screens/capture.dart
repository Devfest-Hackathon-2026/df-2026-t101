import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/measure_engine.dart';
import '../data/api.dart';
import '../widgets/ui.dart';
import 'live_capture.dart';
import 'measure_confirm.dart';

const consentVersion = 'mesh-consent-2';

/// S3 撮影と解析（同意 → 撮り方 → アプリの中のカメラ／動画／写真2枚）。docs/screens.md S3
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

  Future<void> _pick({required bool video}) async {
    setState(() {
      _busy = true;
      _status = 'カメラを準備しています（初回は少し時間がかかります）';
    });
    try {
      final eng = MeasureEngine.instance;
      await eng.init();
      setState(
        () => _status = video ? '動画を選んでください' : '写真を2枚選んでください（上から・親指側の横から）',
      );
      final r = video
          ? await eng.pickVideo(
              (stage, i, n) => setState(() => _status = '$stage（$i/$n）'),
            )
          : await eng.pickPhotos();
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
            video: video,
          ),
        ),
      );
    } on EngineError catch (e) {
      if (mounted) {
        showError(
          context,
          video
              ? 'この動画は読めませんでした。カメラの設定を「互換性優先」にして撮り直すか、「写真2枚で測る」を使ってください。（${e.message}）'
              : e,
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
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
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(video: true),
                  style: smallOutline,
                  icon: const Icon(Icons.videocam_rounded),
                  label: const Text('撮った動画を選ぶ'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(video: false),
                  style: smallOutline,
                  icon: const Icon(Icons.image_rounded),
                  label: const Text('写真2枚で測る'),
                ),
              ),
            ],
          ),
        ],
      ),
      children: [
        if (_status != null) ...[
          BusyCard(text: _status!),
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

/// 撮影のあとの画面で、うっかり戻って撮った動画を失わないようにする（iPhone の Safari のスワイプなど。2026-11-09）。
/// 戻る操作が働いたら確かめ、「撮り直す」を選んだときだけ戻る
mixin _KeepRecording<T extends StatefulWidget> on State<T> {
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

/// S4 1円玉の確認（自動で見つけた輪を確かめ、違うときだけタップ）。docs/screens.md S4
class CoinScreen extends StatefulWidget {
  const CoinScreen({
    super.key,
    required this.caseId,
    required this.hand,
    required this.first,
    required this.video,
  });
  final String caseId;
  final String hand;
  final Map<String, dynamic> first;
  final bool video;
  @override
  State<CoinScreen> createState() => _CoinScreenState();
}

class _CoinScreenState extends State<CoinScreen> with _KeepRecording {
  late String _image = widget.first['first'];
  late double _w = (widget.first['width'] as num).toDouble();
  late double _h = (widget.first['height'] as num).toDouble();
  late final int _count = widget.video
      ? 1
      : (widget.first['frames'] as num).toInt();
  int _index = 0; // 写真モードでは、写真ごとに1円玉を確かめる
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
      final r = await MeasureEngine.instance.autoCoin(_index);
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

  Future<void> _nextPhoto() async {
    setState(() => _busy = true);
    try {
      final r = await MeasureEngine.instance.frameImage(_index + 1);
      setState(() {
        _index++;
        _image = r['first'];
        _w = (r['width'] as num).toDouble();
        _h = (r['height'] as num).toDouble();
        _ok = null;
        _tooSmall = false;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _autoFind();
  }

  Future<void> _tap(TapUpDetails d, Size size) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await MeasureEngine.instance.setCoin(
        d.localPosition.dx / size.width,
        d.localPosition.dy / size.height,
        _index,
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
    final last = _index >= _count - 1;
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
        title: _count > 1 ? '1円玉の確認（${_index + 1}/$_count枚目）' : '1円玉の確認',
        bottom: FilledButton(
          onPressed: _ok == true && !_busy
              ? (last
                    ? () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => AnalyzeScreen(
                            caseId: widget.caseId,
                            hand: widget.hand,
                            video: widget.video,
                          ),
                        ),
                      )
                    : _nextPhoto)
              : null,
          child: Text(!last ? '次の写真へ' : 'この1円玉で解析する'),
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

/// 解析 → 手の3D（hand-mesh）→ 採寸の保存（PUT measurement）。docs/screens.md S3「手の3Dの計算」
class AnalyzeScreen extends StatefulWidget {
  const AnalyzeScreen({
    super.key,
    required this.caseId,
    required this.hand,
    required this.video,
  });
  final String caseId;
  final String hand;
  final bool video;
  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> with _KeepRecording {
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
