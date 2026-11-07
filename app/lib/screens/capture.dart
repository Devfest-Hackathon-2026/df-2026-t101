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
      return AppPage(
        title: '撮影の前に',
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: _busy ? null : _consent,
              child: const Text('同意して進む'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('やめる'),
            ),
          ],
        ),
        children: [
          const InfoCard(
            icon: Icons.privacy_tip_outlined,
            child: Text(
              '手の3Dの形を作るため、手の部分を切り抜いた画像を最大8枚、計算のためだけにシンガポールのサーバーに送ります。'
              '画像は保存しません。\n\n作った手の3Dの形（写真ではありません）は、作った形を確かめるために保存します。ケースを消すと消えます。\n\n'
              '動画そのものは、この端末から外に出しません。同意しない場合は、撮影に進めません。',
            ),
          ),
          if (_error != null) ErrorCard(message: _error!),
        ],
      );
    }
    return AppPage(
      title: '手を撮る',
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
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
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('カメラで撮る'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _pick(video: true),
                  child: const Text('撮った動画を選ぶ'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _pick(video: false),
                  child: const Text('写真2枚で測る'),
                ),
              ),
            ],
          ),
        ],
      ),
      children: [
        if (_status != null) BusyCard(text: _status!),
        const InfoCard(
          icon: Icons.people_outline,
          child: Text('家族や支援者に撮ってもらうのがおすすめです。'),
        ),
        InfoCard(
          icon: Icons.back_hand_outlined,
          child: Text(
            _fingerState == 'straight'
                ? '軽く握った形で撮ってください。指を無理に動かさないでください。'
                : '指を無理に開かないでください。いつもの握った形のまま撮ります。',
          ),
        ),
        for (final (i, s) in const [
          '暗い色の布か紙を机に敷き、その上に、いつもの握った形のまま、手の甲を上にしてこぶしを置きます。',
          '1円玉を、こぶしの前（指の付け根の関節の前）3〜5cmに平らに置きます。',
          '手と1円玉が画面いっぱいに写るくらい近づけます（1円玉が小さすぎると測れません）。',
          '親指側の低い所から、手の上を通って小指側まで、5〜10秒かけてゆっくり半周します。途中で、こぶしの前（指の背と関節の出っ張り）も写します。',
          'PCのカメラで撮るときは、手は机に置いたまま、カメラ（ノートPCなど）の方を動かしてください。',
        ].indexed)
          InfoCard(child: Text('${i + 1}. $s')),
      ],
    );
  }
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

class _CoinScreenState extends State<CoinScreen> {
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
    return AppPage(
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
        Semantics(liveRegion: true, child: Text(msg)),
        const SizedBox(height: 8),
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          dataUrlBytes(_image),
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      ),
                      if (_busy)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const HelperNote(),
      ],
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

class _AnalyzeScreenState extends State<AnalyzeScreen> {
  String _stage = 'フレームを選んでいます';
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
    });
    final eng = MeasureEngine.instance;
    try {
      final a = await eng.analyze(
        (stage, i, n) => setState(() {
          _stage = '$stage（$i/$n）';
          _value = n == 0 ? null : i / n;
        }),
      );
      setState(() {
        _stage = '手の3Dの形を作っています';
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
      setState(() => _stage = '手の3Dを実寸にしています');
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

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: '手を調べています',
      bottom: _error == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_retake)
                  FilledButton(onPressed: _run, child: const Text('もう一度試す')),
                if (!_retake) const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('撮り直す'),
                ),
              ],
            ),
      children: [
        if (_error == null)
          BusyCard(text: _stage, value: _value)
        else
          ErrorCard(message: _error!),
        const InfoCard(
          child: Text(
            '動画はこの端末の中だけで調べています。外に送るのは、手の3Dを作るための手の部分の画像（最大8枚）だけで、画像は保存しません。',
          ),
        ),
      ],
    );
  }
}
