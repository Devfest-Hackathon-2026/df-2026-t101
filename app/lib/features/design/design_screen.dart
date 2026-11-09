import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:jijogu_app/app/router.dart';
import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/models/attachments.dart';
import 'package:jijogu_app/core/models/requirements.dart' show ToolAnswer;
import 'package:jijogu_app/core/storage/files.dart';
import 'package:jijogu_app/core/ui/tool_fields.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/core/viewer/viewer_3d.dart';

const _stepJa = {
  'selecting': '部品を選んでいます',
  'dimensioning': '寸法を決めています',
  'shelling': 'カバーの形を作っています（こぶしに沿った殻とクリップ）',
  'rendering': 'カバーの形を作っています（こぶしに沿った殻とクリップ）',
  'reviewing': '画像で確認しています',
};
const _steps = ['selecting', 'dimensioning', 'shelling', 'reviewing'];

const _colors = {
  '#2A9D8F': 'ティール',
  '#E76F51': 'コーラル',
  '#264653': '紺',
  '#E9C46A': '黄色',
  '#F4F1EA': '白',
  '#5A666B': '灰色',
};
const _vibes = {'目立たない': '#F4F1EA', '明るい': '#E76F51', '落ち着いた': '#264653'};

/// 版の確認用画像（views/iso.png）のパス。まだなければ null
String? _isoPath(Map<String, dynamic>? d) {
  final files = d?['files'];
  final views = files is Map ? files['views'] : null;
  final v = views is Map ? views['iso'] : null;
  return v is String && v.isNotEmpty ? v : null;
}

/// S6 生成中・S7 プレビューと微調整・S8 OTに確認を頼む（docs/screens.md S6〜S8、api.md §3.4〜§3.6）
class DesignScreen extends StatefulWidget {
  const DesignScreen({
    super.key,
    required this.caseId,
    this.designId,
    this.autoStart = false,
    this.recommendedAngles = const {},
    this.attachmentId,
  });
  final String caseId;
  final String? designId;
  final bool autoStart;
  final Map<String, int> recommendedAngles; // 取り付け具ごとにAIが選んだ角度（版をまたいで「おすすめ」を出すため）
  final String? attachmentId; // 選んでいる取り付け具（新しい版でも同じものを見せるため）
  @override
  State<DesignScreen> createState() => _DesignScreenState();
}

class _DesignScreenState extends State<DesignScreen> {
  Map<String, dynamic>? _case;
  Map<String, dynamic>? _design;
  bool _generating = false;
  String? _stage;
  int? _round;
  String? _progressIso; // 生成中に読めた確認用画像（S6「AIが確認している画像」）
  String? _error;
  bool _errorRetry = false;
  String? _busy; // 微調整中の文
  bool _showHand = true;
  late Map<String, int> _recommended = {...widget.recommendedAngles};
  late String? _attId = widget.attachmentId; // 選んでいる取り付け具（最初は主な取り付け具）
  String? _clarify;
  final _instruction = TextEditingController();
  Timer? _poll;
  int _pollCount = 0;
  // 通信が切れたあと、サーバーで続いている作業を進み具合から追いかけている。スマホを裏に回したり画面を消したりすると、
  // 待っている通信が切れ、「通信できませんでした」で止まって見えた。サーバーは最後まで作っていた（2026-11-09）
  bool _detached = false;

  String get _cid => widget.caseId;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await Api.instance.post('/v1/cases/$_cid/recover');
    } catch (_) {}
    try {
      final c = Map<String, dynamic>.from(
        await Api.instance.get('/v1/cases/$_cid'),
      );
      setState(() => _case = c);
      final id = widget.designId ?? c['current_design_id'] as String?;
      if (id != null) {
        await _loadDesign(id);
        final st = _design?['status'];
        if (_inProgress(st)) _startPolling();
      } else if (widget.autoStart) {
        await _generate();
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _errorRetry = true;
      });
    }
  }

  Future<void> _loadDesign(String id) async {
    final r = await Api.instance.get('/v1/cases/$_cid/designs/$id');
    final d = Map<String, dynamic>.from(r['design'] ?? r);
    _setDesign(d);
  }

  void _setDesign(Map<String, dynamic> d) {
    setState(() {
      _design = d;
      _recommended = recommendedAngles(d, _recommended);
      _attId = selectAttachment(_attachments(d), _attId);
    });
  }

  /// 版の取り付け具（古い版は1つ。道具の名前はケースの要求から）
  List<Map<String, dynamic>> _attachments(Map<String, dynamic> d) =>
      viewAttachments(d, (_case?['requirements'] as Map?)?.cast<String, dynamic>());

  /// 版が処理中か（APIの status は `queued` → `running`。data-model.md §2.5）
  static bool _inProgress(Object? status) =>
      status == 'running' || status == 'queued';

  Map<String, dynamic>? _angleParam(Map<String, dynamic> d) {
    for (final p in (d['params'] as List? ?? [])) {
      if (p['part_id'] == 'c_clip' && p['name'] == 'angle_deg') {
        return Map<String, dynamic>.from(p);
      }
    }
    return null;
  }

  num? _param(String part, String name) {
    for (final p in (_design?['params'] as List? ?? [])) {
      if (p['part_id'] == part && p['name'] == name) return p['value'] as num?;
    }
    return null;
  }

  /// 進み具合を読む（dev は GET designs を2秒おき。15秒ごとに recover）
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      _pollCount++;
      try {
        if (_pollCount % 8 == 0) {
          await Api.instance.post('/v1/cases/$_cid/recover');
        }
        final c = await Api.instance.get('/v1/cases/$_cid');
        final id = c['current_design_id'];
        final busy = c['active_operation'] != null;
        if (id == null) {
          // 版ができる前に切れた（サーバーに届かなかった）：作業がなければ、通信のエラーとして見せる
          if (_detached && !busy && mounted) _detachedFailed();
          return;
        }
        final r = await Api.instance.get('/v1/cases/$_cid/designs/$id');
        final d = Map<String, dynamic>.from(r['design'] ?? r);
        final p = Map<String, dynamic>.from(d['progress'] ?? {});
        if (!mounted) return;
        setState(() {
          _stage = p['step'] as String? ?? _stage;
          _round = (p['round'] as num?)?.toInt();
          _progressIso = _isoPath(d) ?? _progressIso;
        });
        if (!_inProgress(d['status']) && !busy && (!_generating || _detached)) {
          _poll?.cancel();
          final shown = _design?['design_id'];
          final wasDetached = _detached;
          setState(() {
            _detached = false;
            _generating = false;
            _busy = null;
          });
          if (wasDetached && shown != null && id != shown) {
            _openVersion(id as String); // 微調整で新しい版ができていた
          } else {
            _setDesign(d);
          }
        }
      } catch (_) {
        /* 接続が切れても失敗と決めない（screens.md S6 復旧） */
      }
    });
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
      _stage = 'selecting';
      _round = null;
      _progressIso = null;
    });
    _startPolling();
    try {
      final r = await Api.instance.post('/v1/cases/$_cid/designs', {
        'style': {
          'color': _design?['style']?['color'] ?? '#2A9D8F',
          'pattern': 'none',
        },
      });
      _poll?.cancel();
      _setDesign(Map<String, dynamic>.from(r['design']));
      final c = await Api.instance.get('/v1/cases/$_cid');
      setState(() => _case = Map<String, dynamic>.from(c));
    } on ApiError catch (e) {
      if (e.code == 'NETWORK') {
        _followServer();
        return;
      }
      _poll?.cancel();
      setState(() {
        _error = e.code == 'AI_UNAVAILABLE'
            ? 'AIが混み合っています。少し待ってもう一度試してください。'
            : e.message;
        _errorRetry = true;
      });
    } finally {
      if (mounted && !_detached) setState(() => _generating = false);
    }
  }

  /// 待っていた通信が切れた。サーバーでは作業が続いているので、エラーにせず進み具合を読み続ける
  void _followServer() {
    if (!mounted) return;
    setState(() {
      _detached = true;
      _error = null;
    });
    _startPolling();
  }

  void _detachedFailed() {
    _poll?.cancel();
    setState(() {
      _detached = false;
      _generating = false;
      _busy = null;
      _error = '通信できませんでした。インターネットの接続を確かめて、もう一度試してください。';
      _errorRetry = true;
    });
  }

  /// 新しい版を開く（パスも新しい版にする。戻るでケース一覧へ）
  void _openVersion(String nid) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        settings: RouteSettings(name: AppRouter.design(_cid, nid)),
        builder: (_) => DesignScreen(
          caseId: _cid,
          designId: nid,
          recommendedAngles: _recommended,
          attachmentId: _attId,
        ),
      ),
    );
  }

  Future<void> _refine(Map<String, dynamic> body, String busyText) async {
    final d = _design;
    if (d == null) return;
    setState(() {
      _busy = busyText;
      _error = null;
      _clarify = null;
    });
    try {
      final r = await Api.instance.post(
        '/v1/cases/$_cid/designs/${d['design_id']}/refine',
        body,
      );
      if (r['clarify_ja'] != null) {
        setState(() => _clarify = '${r['clarify_ja']}');
      } else {
        final before = _attachments(d);
        final nd = Map<String, dynamic>.from(r['design']);
        // 足したときは足した取り付け具を、それ以外は今の取り付け具を選んだままにする
        _attId = selectionAfter(before, _attachments(nd), _attId);
        _setDesign(nd);
        if (r['design']['design_id'] != d['design_id'] && mounted) {
          _openVersion(r['design']['design_id'] as String); // 新しい版
        }
      }
    } on ApiError catch (e) {
      if (e.code == 'NETWORK') {
        _followServer();
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted && !_detached) setState(() => _busy = null);
    }
  }

  Future<void> _prepareDemo() async {
    final d = _design!;
    setState(() => _busy = '印刷用のデータを作っています（20〜60秒）');
    try {
      await Api.instance.post(
        '/v1/cases/$_cid/designs/${d['design_id']}/prepare-print',
      );
      if (mounted) {
        Navigator.of(context).pushNamed(AppRouter.print(_cid, d['design_id']));
      }
    } on ApiError catch (e) {
      setState(
        () => _error = e.code == 'RENDER_FAILED'
            ? 'このままでは刷れない形でした。形を直してから、もう一度試してください。（${e.message}）'
            : e.message,
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// S8 を下から出す（Figma：モーダルのボトムシート）
  void _openReview(Map<String, dynamic> d) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.surfaceContainerLow,
      builder: (_) => ReviewRequestDialog(caseId: _cid, design: d),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_generating || _inProgress(_design?['status'])) {
      return _progressPage();
    }
    final d = _design;
    if (d == null) return _emptyPage();
    if (d['status'] == 'failed') {
      return AppPage(
        title: '形を作れませんでした',
        bottom: FilledButton.icon(
          onPressed: _generate,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('もう一度作る'),
        ),
        children: [
          ErrorCard(
            message: '${d['error']?['message'] ?? _error ?? '形を作る途中で失敗しました。'}',
          ),
        ],
      );
    }
    return _previewPage(d);
  }

  Widget _emptyPage() => AppPage(
    title: '形を作る',
    bottom: _case == null
        ? null
        : FilledButton(onPressed: _generate, child: const Text('形を作る')),
    children: [
      if (_case == null && _error == null) const BusyCard(text: '読み込んでいます'),
      if (_error != null)
        ErrorCard(message: _error!, onRetry: _errorRetry ? _open : null),
      if (_case != null)
        const InfoCard(
          tone: NoticeTone.info,
          child: Text('まだ形がありません。「形を作る」を押すと、カバーとクリップの形を作ります（1〜3分）。'),
        ),
    ],
  );

  // ───────────────────────── S6 生成中 ─────────────────────────

  Widget _progressPage() {
    final cur = _steps.indexOf(
      _stage == 'rendering' ? 'shelling' : (_stage ?? 'selecting'),
    );
    String label(int i, String s) =>
        '${_stepJa[s]}${s == 'reviewing' && i == cur && _round != null ? '（$_round/3回目）' : ''}';
    final iso = _progressIso;
    return AppPage(
      title: '形を作っています',
      bottom: OutlinedButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('中止して戻る（作業は続きます）'),
      ),
      children: _spaced(16, [
        if (iso != null) _CheckImage(path: iso),
        // いまの段階（読み込みの印＋文。くるくるだけにしない）
        Row(
          children: [
            const ExcludeSemantics(
              child: SizedBox.square(
                dimension: 48,
                child: Center(
                  child: SizedBox.square(
                    dimension: 36,
                    child: CircularProgressIndicator(),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  label(cur < 0 ? 0 : cur, _steps[cur < 0 ? 0 : cur]),
                  style: AppText.titleLarge.copyWith(
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, s) in _steps.indexed) ...[
                if (i > 0) const SizedBox(height: 4),
                _StepItem(
                  label: label(i, s),
                  state: i < cur
                      ? _StepState.done
                      : (i == cur ? _StepState.current : _StepState.upcoming),
                ),
              ],
            ],
          ),
        ),
        const InfoCard(
          tone: NoticeTone.info,
          child: Text('数分かかることがあります。画面を閉じても、作業は続きます。'),
        ),
        if (_error != null) ErrorCard(message: _error!, onRetry: _generate),
      ]),
    );
  }

  // ───────────────────────── S7 プレビューと微調整 ─────────────────────────

  Widget _previewPage(Map<String, dynamic> d) {
    final demo = _case?['demo'] == true;
    final color = '${d['style']?['color'] ?? '#2A9D8F'}';
    final parts = Map<String, dynamic>.from(d['files']?['parts'] ?? {});
    // 選んでいる取り付け具。角度・寸法・3D表示のクリップと道具の棒はこの取り付け具のもの
    final atts = _attachments(d);
    final att = atts.firstWhere((a) => a['id'] == _attId, orElse: () => atts.first);
    final multi = atts.length > 1;
    final label = attachmentLabel(att, atts);
    final attId = att['id'] as String?;
    final angle =
        (att['angle_deg'] as num?)?.toInt() ??
        (_angleParam(d)?['value'] as num?)?.toInt();
    final toolD =
        ((att['tool_d_mm'] as num?) ??
                _param('c_clip', 'tool_d_mm') ??
                _case?['requirements']?['tool_d_mm'] ??
                8.5)
            .toDouble();
    final clipPath = (att['files'] as Map?)?['preview_stl'];
    final tool = (att['tool'] as Map?) ?? (att['primary'] == true ? d['tool'] as Map? : null);
    final addBlocked = addBlockedReason(d, (_case?['requirements'] as Map?)?.cast<String, dynamic>());
    final approval = '${d['approval']?['status'] ?? 'none'}';
    final issues = (d['review']?['unresolved_issues'] as List? ?? []);
    final locked = approval == 'requested';
    final idle = _busy == null;
    return AppPage(
      title: '形を確かめる（${d['revision'] ?? 1}版）',
      onBack: () =>
          Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (approval == 'approved')
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context)
                      .pushNamed(AppRouter.print(_cid, d['design_id'])),
              icon: const Icon(Icons.print_rounded),
              label: const Text('印刷へ進む'),
            )
          else ...[
            FilledButton.icon(
              onPressed: !idle || (locked && !demo)
                  ? null
                  : () => _openReview(d),
              icon: Icon(
                locked && !demo
                    ? Icons.hourglass_top_rounded
                    : Icons.verified_user_rounded,
              ),
              label: Text(locked && !demo ? '確認を待っています' : 'OTに確認を頼む'),
            ),
            if (demo) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: idle ? _prepareDemo : null,
                icon: const Icon(Icons.print_rounded),
                label: const Text('印刷用データを作る（デモ）'),
              ),
            ],
          ],
        ],
      ),
      children: _spaced(12, [
        if (demo) const DemoBanner(),
        if (d['status'] == 'needs_attention')
          InfoCard(
            tone: NoticeTone.warning,
            child: Text(
              // API は未解決の点を {severity, description_ja} で返す（pipeline.py・review.dart と同じ）
              '確かめてほしい点があります：\n${issues.map((i) => '・${i is Map ? (i['description_ja'] ?? i['message_ja'] ?? i['issue_ja'] ?? '') : i}').join('\n')}',
            ),
          ),
        if (approval == 'rejected')
          InfoCard(
            tone: NoticeTone.error,
            icon: Icons.reply_rounded,
            child: Text('差し戻されました：${d['approval']?['comment_ja'] ?? ''}'),
          ),
        // 取り付け具を足した・太さを直した版（ADR-0014 §4）
        if (coverKept(d))
          const InfoCard(
            tone: NoticeTone.success,
            icon: Icons.check_circle_outline_rounded,
            child: Text('カバーは前の版と同じです。刷ってあるカバーをそのまま使えます'),
          ),
        if (_busy != null) BusyCard(text: _busy!),
        if (_error != null) ErrorCard(message: _error!),
        // 取り付け具の切り替え（2つ以上のときだけ。ADR-0014 §5）
        if (multi) _attachmentTabs(atts, attId),
        // 3D表示（three.js）
        SizedBox(
          height: 326,
          child: parts.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(16),
                  child: const InfoCard(
                    tone: NoticeTone.info,
                    child: Text('3Dのデータがありません。'),
                  ),
                )
              : Viewer3D(
                  handPath: d['hand_overlay']?['mesh_path'],
                  parts: [
                    // クリップは選んでいる取り付け具のもの
                    for (final e in parts.entries)
                      PartFile(
                        e.key,
                        e.key == 'c_clip' && clipPath != null
                            ? '$clipPath'
                            : '${e.value['preview_stl']}',
                      ),
                  ],
                  color: color,
                  toolDmm: toolD,
                  tool: tool?.cast<String, dynamic>(),
                  handSide: _case?['requirements']?['hand_side'] as String?,
                  showHand: _showHand,
                  label: '3Dの表示。カバーとクリップと道具を、手に着けた形で見られます。ドラッグで回せます',
                ),
        ),
        // 手を重ねる（3D表示の上に重ねると、Webでは押せないことがあるので下に置く）
        Material(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: SwitchListTile(
            title: Text(
              '手を重ねる',
              style: AppText.titleMedium.copyWith(color: AppColors.onSurface),
            ),
            subtitle: const Text('カバーが手の甲と関節に沿っているか、手のひら側と手首が開いているかを見ます'),
            value: _showHand,
            onChanged: (v) => setState(() => _showHand = v),
          ),
        ),
        _mainDims(d, toolD, angle, att),
        _summary(d),
        // クリップの角度（ADR-0013）。取り付け具が2つ以上なら、選んでいる取り付け具の角度
        _Heading(multi ? 'クリップの角度（$label）' : 'クリップの角度'),
        if (multi && '${att['reason_ja'] ?? ''}'.isNotEmpty)
          Text('${att['reason_ja']}', style: _noteStyle),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 道具の立て具合（机に対する傾き。ADR-0013、2026-11-08 に 0/20/40 から変えた）
              for (final (i, a) in const [60, 70, 80].indexed) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  child: _AngleButton(
                    angle: a,
                    selected: a == angle,
                    recommended: a == _recommended[attId],
                    position: i == 0
                        ? _GroupPos.first
                        : (i == 2 ? _GroupPos.last : _GroupPos.middle),
                    onTap: () {
                      if (a != angle && _busy == null) {
                        _refine(
                          withAttachment({'clip_angle_deg': a}, d, attId),
                          '${multi ? '$labelの' : ''}クリップを$a度で描き直しています（カバーはそのままです）',
                        );
                      }
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        if (locked)
          Text('OTに頼んだあとに角度を変えると、新しい版になり、もう一度確認を頼みます。', style: _noteStyle),
        // 取り付け具（道具ごとのクリップ）の太さを直す・足す（ADR-0014 §4）
        OutlinedButton.icon(
          onPressed: idle ? () => _openToolSheet(d, fix: att, label: label) : null,
          icon: const Icon(Icons.straighten_rounded),
          label: Text('$labelの柄の太さを直す'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        OutlinedButton.icon(
          onPressed: idle && addBlocked == null ? () => _openToolSheet(d) : null,
          icon: const Icon(Icons.add_rounded),
          label: const Text('取り付け具を足す'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        Text(
          addBlocked ?? 'カバーはそのままで、別の道具のクリップを足せます。足すと新しい版になります。',
          style: _noteStyle,
        ),
        const _Heading('言葉で直す'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in const [
              'もう少しゆるく',
              'もう少しきつく',
              'カバーを薄く',
              '空気穴を増やす',
              'クリップを外しやすく',
            ])
              SuggestButton(
                label: t,
                onPressed: !idle
                    ? null
                    : () => _refine(
                        withAttachment({'instruction': t}, d, attId),
                        '「$t」に合わせて直しています',
                      ),
              ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _instruction,
                maxLength: 300,
                minLines: 1,
                maxLines: 4,
                style: AppText.bodyLarge.copyWith(color: AppColors.onSurface),
                decoration: InputDecoration(
                  labelText: '直したいこと',
                  hintText: '例：人差し指の関節のところをゆったり',
                  hintMaxLines: 2,
                  filled: true,
                  fillColor: AppColors.surfaceContainerHigh,
                  counterText: '',
                  contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  border: _pillBorder,
                  enabledBorder: _pillBorder,
                  focusedBorder: _pillBorder,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '送る',
              style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
              icon: const Icon(Icons.send_rounded),
              onPressed: !idle || _instruction.text.trim().isEmpty
                  ? null
                  : () => _refine(
                      withAttachment({'instruction': _instruction.text.trim()}, d, attId),
                      '「${_instruction.text.trim()}」に合わせて直しています',
                    ),
            ),
          ],
        ),
        if (_clarify != null)
          InfoCard(
            tone: NoticeTone.info,
            icon: Icons.help_outline_rounded,
            child: Text(_clarify!),
          ),
        if (_numberParams(d).isNotEmpty) ...[
          const _Heading('数値で細かく直す'),
          OutlinedButton.icon(
            onPressed: idle ? () => _openNumbers(d, attId) : null,
            icon: const Icon(Icons.tune_rounded),
            label: const Text('カバーの厚み・空気穴などを直す'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],
        const _Heading('見た目'),
        const _SubLabel('雰囲気'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _vibes.entries)
              FilterChip(
                label: Text(e.key),
                selected: e.value.toUpperCase() == color.toUpperCase(),
                onSelected: !idle
                    ? null
                    : (_) => _refine({
                        'style': {'color': e.value},
                      }, '色を変えています'),
              ),
          ],
        ),
        const _SubLabel('色'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final e in _colors.entries)
              _Swatch(
                hex: e.key,
                name: e.value,
                selected: e.key.toUpperCase() == color.toUpperCase(),
                onTap: !idle
                    ? null
                    : () => _refine({
                        'style': {'color': e.key},
                      }, '色を変えています'),
              ),
          ],
        ),
        Text('色は形に関係ないので、確認を頼んだあとでも変えられます。', style: _noteStyle),
        const InfoCard(
          tone: NoticeTone.info,
          child: Text('手のひら側を開ける・手首を覆わない・角を丸める・厚みの下限は、見た目のためでも変えられません。'),
        ),
      ]),
    );
  }

  static final _noteStyle = AppText.bodyLarge.copyWith(
    color: AppColors.onSurfaceVariant,
  );

  static final _pillBorder = UnderlineInputBorder(
    borderRadius: BorderRadius.circular(28),
    borderSide: BorderSide.none,
  );

  /// 主な寸法（Figma：2列のタイル）
  Widget _mainDims(Map<String, dynamic> d, double toolD, int? angle, Map<String, dynamic> att) {
    final t = _param('cover', 'cover_thickness_mm');
    // params の c_clip は主な取り付け具の値なので、主でないときは内径を出さない
    final inner = att['primary'] == false ? null : _param('c_clip', 'inner_d_mm');
    final tiles = [
      _DimTile('カバーの厚み', '${t ?? '—'} mm'),
      _DimTile('道具の太さ', '${toolD.toStringAsFixed(1)} mm'),
      if (inner != null) _DimTile('クリップの内径', '$inner mm'),
      _DimTile('クリップの角度', '${angle ?? '—'}度'),
    ];
    final estimated = att['tool_d_source'] == 'category';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < tiles.length
                      ? tiles[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
        if (estimated) ...[
          const SizedBox(height: 8),
          const InfoCard(
            tone: NoticeTone.warning,
            child: Text('道具の太さは推定です。刷る前に、定規で確かめてください。'),
          ),
        ],
      ],
    );
  }

  /// AIが決めた理由（Figma：tertiaryContainer のカード）
  Widget _summary(Map<String, dynamic> d) {
    const fg = AppColors.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 20, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'AIが決めた理由',
                    style: AppText.titleSmall.copyWith(color: fg),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${d['summary_ja'] ?? ''}',
            style: AppText.bodyLarge.copyWith(color: fg),
          ),
        ],
      ),
    );
  }

  /// 数値で直せる引数（日本語の名前があるものだけ。範囲は版の params の range）
  List<Map<String, dynamic>> _numberParams(Map<String, dynamic> d) => [
    for (final p in (d['params'] as List? ?? []))
      if (p['range'] is List &&
          (p['range'] as List).length == 2 &&
          _paramLabels.containsKey('${p['part_id']}.${p['name']}'))
        Map<String, dynamic>.from(p),
  ];

  /// 数値で直す画面を下から出す（いつも出しておくと画面が長くなるので、開いたときだけ。2026-11-08）
  Future<void> _openNumbers(Map<String, dynamic> d, String? attId) async {
    final changes = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.surfaceContainerLow,
      builder: (_) => _NumberSheet(params: _numberParams(d)),
    );
    if (changes == null || changes.isEmpty || !mounted) return;
    await _refine(
      withAttachment({'param_changes': changes}, d, attId),
      '値に合わせて作り直しています',
    );
  }

  /// 取り付け具の切り替え（道具の名前のボタン）。押しても版は変わらず、3D表示と角度の表示だけが変わる
  Widget _attachmentTabs(List<Map<String, dynamic>> atts, String? selected) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SubLabel('見るクリップ（道具ごと）'),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final a in atts)
            ChoiceChip(
              label: Text(attachmentLabel(a, atts), style: AppText.titleMedium),
              selected: a['id'] == selected,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              tooltip: '${attachmentLabel(a, atts)}のクリップを見る',
              onSelected: (_) => setState(() => _attId = a['id'] as String?),
            ),
        ],
      ),
    ],
  );

  /// 取り付け具を足す／太さを直す画面を下から出す（fix があれば、その取り付け具の太さを直す）
  Future<void> _openToolSheet(
    Map<String, dynamic> d, {
    Map<String, dynamic>? fix,
    String? label,
  }) async {
    final t = await showModalBottomSheet<ToolAnswer>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.surfaceContainerLow,
      builder: (_) => _ToolSheet(
        fixLabel: fix == null ? null : label,
        fixToolType: fix?['tool_type'] as String?,
        fixToolD: (fix?['tool_d_mm'] as num?)?.toDouble(),
      ),
    );
    if (t == null || !mounted) return;
    if (fix == null) {
      await _refine(
        {'add_attachment': t.toJson()},
        '${toolJa[t.toolType] ?? '道具'}のクリップを足しています（カバーはそのままです）',
      );
    } else {
      final v = toolDOf(t);
      await _refine(
        withAttachment({'tool_d_mm': v}, d, fix['id'] as String?),
        '$labelのクリップを太さ${v.toStringAsFixed(1)}mmで描き直しています（カバーはそのままです）',
      );
    }
  }
}

/// 取り付け具を足す画面（道具・太さ・形）／太さを直す画面（太さだけ）。決めた答えを返す（送るのは呼び出し側）
class _ToolSheet extends StatefulWidget {
  const _ToolSheet({this.fixLabel, this.fixToolType, this.fixToolD});
  final String? fixLabel; // 太さを直す取り付け具の呼び名（null なら足す）
  final String? fixToolType;
  final double? fixToolD;
  bool get fix => fixLabel != null;
  @override
  State<_ToolSheet> createState() => _ToolSheetState();
}

class _ToolSheetState extends State<_ToolSheet> {
  late final ToolAnswer _t = widget.fix
      ? (ToolAnswer()
          ..toolType = widget.fixToolType
          ..toolDmm = widget.fixToolD ?? 8.5)
      : ToolAnswer();
  late bool _mmInput = widget.fix;

  bool get _ok {
    if (!canSubmitTool(_t, fixOnly: widget.fix)) return false;
    // 太さを直すときは、今の太さから変えたときだけ押せる
    return !widget.fix || widget.fixToolD == null || (toolDOf(_t) - widget.fixToolD!).abs() > 1e-9;
  }

  @override
  Widget build(BuildContext context) {
    final flat = flatNotice(_t);
    Widget choice(String label, bool sel, VoidCallback f, [String? sub]) =>
        ChoiceButton(label: label, sub: sub, selected: sel, onTap: () => setState(f));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    widget.fix ? '${widget.fixLabel}の柄の太さを直す' : '取り付け具を足す',
                    style: AppText.titleLarge,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.fix
                      ? 'このクリップだけを描き直します。カバーはそのままです。新しい版になります'
                      : 'カバーはそのままで、別の道具のクリップを足します。新しい版になります',
                  style: AppText.bodyMedium.copyWith(color: AppColors.onSurfaceVariant),
                ),
                if (!widget.fix) ...[
                  const SectionLabel('道具'),
                  for (final (type, label) in const [('brush', '筆'), ('pen', 'ペン'), ('spoon', 'スプーン')])
                    choice(label, _t.toolType == type, () {
                      _t.toolType = type;
                      _t.activity = toolActivity[type];
                    }),
                ],
                const SectionLabel('柄の太さ（挟む所）'),
                // 太さを直すときは mm だけ（区分の目安を送ると、推定の太さを人が入れた値として残してしまう）
                if (!widget.fix)
                  for (final e in shaftRows.entries)
                    choice(
                      e.value.$1,
                      _t.toolDmm == null && _t.shaftSize == e.key,
                      () {
                        _mmInput = false;
                        _t.shaftSize = e.key;
                        _t.toolDmm = null;
                      },
                      e.value.$2,
                    ),
                if (_mmInput)
                  ToolDmmCard(
                    value: _t.toolDmm ?? 8.5,
                    onChanged: (v) => setState(() => _t.toolDmm = v),
                  )
                else
                  choice('mmで入れる', _t.toolDmm != null, () {
                    _mmInput = true;
                    _t.toolDmm ??= 8.5;
                    _t.shaftSize = null;
                  }, 'おすすめ。定規で測った太さを入れます'),
                if (!widget.fix) ...[
                  const SectionLabel('柄の形'),
                  choice('丸い', _t.shaftShape == 'round', () => _t.shaftShape = 'round'),
                  choice('平たい', _t.shaftShape == 'flat', () => _t.shaftShape = 'flat'),
                  if (flat != null) ...[
                    const SizedBox(height: 8),
                    InfoCard(tone: NoticeTone.warning, child: Text(flat)),
                  ],
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: const Text('やめる'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _ok ? () => Navigator.of(context).pop(_t) : null,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: Text(widget.fix ? 'この太さで直す' : '足す'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 引数の日本語の名前・説明・単位（API の名前は利用者に分かりにくいので、画面ではこちらを出す）
class _ParamLabel {
  const _ParamLabel(this.title, this.help, {this.unit = 'mm', this.lowJa, this.highJa});
  final String title;
  final String help;
  final String unit;
  final String? lowJa; // スライダーの左端の意味
  final String? highJa; // 右端の意味
}

const Map<String, _ParamLabel> _paramLabels = {
  'cover.cover_thickness_mm': _ParamLabel('カバーの厚み', '厚いほど丈夫で、薄いほど軽くなります', lowJa: '軽い', highJa: '丈夫'),
  'cover.palm_cut_offset_mm': _ParamLabel('手のひら側をどこまで覆うか', 'プラスにするとカバーが手のひら側へ深くなり、マイナスにすると浅く小さくなります。手のひらは覆いません', lowJa: '浅い', highJa: '深い'),
  'cover.wrist_cut_mm': _ParamLabel('手首からカバーまでの長さ', '大きくするとカバーが短くなり、手首が動かしやすくなります', lowJa: '長いカバー', highJa: '短いカバー'),
  'cover.edge_radius_mm': _ParamLabel('ふちの丸み', '大きいほど、ふちが手に当たったときにやわらかく感じます', lowJa: '小さい', highJa: '丸い'),
  'air_holes.count': _ParamLabel('空気穴の数', '多いほど蒸れにくくなります', unit: '個', lowJa: '少ない', highJa: '多い'),
  'air_holes.diameter_mm': _ParamLabel('空気穴の大きさ', '大きいほど蒸れにくく、小さいほどカバーが丈夫です', lowJa: '小さい', highJa: '大きい'),
  'strap_slits.strap_thickness_mm': _ParamLabel('ベルトの厚み', '使うベルト（面ファスナー）の厚みに合わせます。穴の大きさが変わります', lowJa: '薄い', highJa: '厚い'),
};

/// 数値で直す画面（ボトムシート）。変えた値を返す（作り直すのは呼び出し側）
class _NumberSheet extends StatefulWidget {
  const _NumberSheet({required this.params});
  final List<Map<String, dynamic>> params;
  @override
  State<_NumberSheet> createState() => _NumberSheetState();
}

class _NumberSheetState extends State<_NumberSheet> {
  final Map<String, num> _pending = {}; // part_id.name → 変えた値

  String _fmt(num v, bool isInt) => isInt ? '${v.round()}' : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Semantics(
                  header: true,
                  child: Text('数値で細かく直す', style: AppText.titleLarge),
                ),
                const SizedBox(height: 4),
                Text(
                  '動かしたあと「この値で作り直す」を押すと、新しい版を作ります。クリップの角度は前の画面のボタンで変えられます',
                  style: AppText.bodyMedium.copyWith(color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                for (final p in widget.params) ...[
                  _row(p),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: const Text('やめる'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _pending.isEmpty
                          ? null
                          : () => Navigator.of(context).pop([
                              for (final e in _pending.entries)
                                {
                                  'part_id': e.key.split('.').first,
                                  'name': e.key.split('.').last,
                                  'value': e.value,
                                },
                            ]),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: Text(_pending.isEmpty ? 'この値で作り直す' : 'この値で作り直す（${_pending.length}か所）'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> p) {
    final key = '${p['part_id']}.${p['name']}';
    final label = _paramLabels[key]!;
    final lo = (p['range'][0] as num).toDouble(), hi = (p['range'][1] as num).toDouble();
    final isInt = p['value'] is int && p['range'][0] is int ||
        label.unit == '個' || label.unit == '本';
    final orig = (p['value'] as num).toDouble().clamp(lo, hi);
    final v = (_pending[key] ?? orig).toDouble().clamp(lo, hi);
    final changed = _pending.containsKey(key);
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        decoration: BoxDecoration(
          color: changed ? AppColors.secondaryContainer : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(label.title, style: AppText.titleMedium.copyWith(color: AppColors.onSurface)),
                ),
                const SizedBox(width: 8),
                Text('${_fmt(v, isInt)} ${label.unit}', style: AppText.titleMedium.copyWith(color: AppColors.primary)),
              ],
            ),
            const SizedBox(height: 2),
            Text(label.help, style: AppText.bodyMedium.copyWith(color: AppColors.onSurfaceVariant)),
            Slider(
              min: lo,
              max: hi,
              divisions: isInt ? (hi - lo).round().clamp(1, 100) : ((hi - lo) * 10).round().clamp(1, 200),
              value: v,
              label: '${_fmt(v, isInt)} ${label.unit}',
              semanticFormatterCallback: (x) => '${label.title} ${_fmt(x, isInt)} ${label.unit}',
              onChanged: (x) => setState(() {
                final nv = isInt ? x.round() : double.parse(x.toStringAsFixed(1));
                if ((nv - orig).abs() < 1e-9) {
                  _pending.remove(key); // 元の値に戻したら、変えていない扱い
                } else {
                  _pending[key] = nv;
                }
              }),
            ),
            if (label.lowJa != null || label.highJa != null)
              Row(
                children: [
                  Text(label.lowJa ?? '', style: AppText.bodySmall.copyWith(color: AppColors.onSurfaceVariant)),
                  const Spacer(),
                  Text(label.highJa ?? '', style: AppText.bodySmall.copyWith(color: AppColors.onSurfaceVariant)),
                ],
              ),
            Row(
              children: [
                Text('元の値：${_fmt(orig, isInt)} ${label.unit}', style: AppText.bodySmall.copyWith(color: AppColors.onSurfaceVariant)),
                const Spacer(),
                if (changed)
                  TextButton(
                    onPressed: () => setState(() => _pending.remove(key)),
                    child: const Text('元に戻す'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 子のあいだに縦のすき間を入れる（Figma の Body の gap）
List<Widget> _spaced(double gap, List<Widget> children) => [
  for (final (i, c) in children.indexed) ...[
    if (i > 0) SizedBox(height: gap),
    c,
  ],
];

/// 本文の見出し（Figma：Title Medium・onSurface、上に16のすき間）
class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: AppText.titleMedium.copyWith(color: AppColors.onSurface),
      ),
    ),
  );
}

/// 見出しの下の小さなラベル（Figma：Title Small・onSurfaceVariant）
class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: AppText.titleSmall.copyWith(color: AppColors.onSurfaceVariant),
  );
}

/// 段階の1行（Figma の M3/Step item：済み／いま／これから）。色だけでなくアイコンと読み上げの文でも伝える
enum _StepState { done, current, upcoming }

class _StepItem extends StatelessWidget {
  const _StepItem({required this.label, required this.state});
  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final (
      Color bg,
      IconData? icon,
      Color iconColor,
      BoxBorder? border,
    ) = switch (state) {
      _StepState.done => (
        AppColors.primary,
        Icons.check_circle_outline_rounded,
        AppColors.onPrimary,
        null,
      ),
      _StepState.current => (
        AppColors.primaryContainer,
        Icons.hourglass_top_rounded,
        AppColors.onPrimaryContainer,
        null,
      ),
      _StepState.upcoming => (
        Colors.transparent,
        null,
        AppColors.outline,
        Border.all(color: AppColors.outlineVariant, width: 2),
      ),
    };
    final stateText = switch (state) {
      _StepState.done => '済み',
      _StepState.current => 'いまここ',
      _StepState.upcoming => 'これから',
    };
    final style = switch (state) {
      _StepState.current => AppText.titleMedium.copyWith(
        color: AppColors.onSurface,
      ),
      _StepState.done => AppText.bodyLarge.copyWith(color: AppColors.onSurface),
      _StepState.upcoming => AppText.bodyLarge.copyWith(
        color: AppColors.onSurfaceVariant,
      ),
    };
    return Semantics(
      label: '$label（$stateText）',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: border,
              ),
              child: icon == null
                  ? null
                  : Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: style)),
          ],
        ),
      ),
    );
  }
}

/// S6「AIが確認している画像」（views/iso.png。生成中に読めたときだけ出す）
class _CheckImage extends StatelessWidget {
  const _CheckImage({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 268,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _StorageImage(path: path, semanticLabel: 'AIが確認している、いまの形の画像'),
          Positioned(
            left: 12,
            top: 12,
            child: ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.visibility_outlined,
                      size: 18,
                      color: AppColors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'AIが確認している画像',
                      style: AppText.labelLarge.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Storage の画像を出す（読めなければ何も出さない）
class _StorageImage extends StatefulWidget {
  const _StorageImage({required this.path, this.semanticLabel, this.fallback});
  final String path;
  final String? semanticLabel;

  /// 読み込み中・読めなかったときに出すもの（なければ何も出さない）
  final Widget? fallback;
  @override
  State<_StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<_StorageImage> {
  FileRef? _ref;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_StorageImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _resolve();
  }

  Future<void> _resolve() async {
    try {
      final r = await Files.resolve(widget.path);
      if (mounted) setState(() => _ref = r);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final r = _ref;
    final none = widget.fallback ?? const SizedBox.shrink();
    if (r == null) return none;
    return Image.network(
      r.url,
      headers: r.headers,
      fit: BoxFit.contain,
      semanticLabel: widget.semanticLabel,
      errorBuilder: (_, _, _) => none,
    );
  }
}

/// 主な寸法の1枚（Figma：surfaceContainerLow・角丸16、ラベル Body Small／値 Title Large）
class _DimTile extends StatelessWidget {
  const _DimTile(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppText.bodySmall.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: AppText.titleLarge.copyWith(color: AppColors.onSurface),
          ),
        ],
      ),
    ),
  );
}

/// クリップの角度のボタン（Figma：つながったボタンの並び。選んだものは丸く・secondaryContainer・チェック付き）
enum _GroupPos { first, middle, last }

class _AngleButton extends StatelessWidget {
  const _AngleButton({
    required this.angle,
    required this.selected,
    required this.recommended,
    required this.position,
    required this.onTap,
  });
  final int angle;
  final bool selected;
  final bool recommended;
  final _GroupPos position;
  final VoidCallback onTap;

  BorderRadius get _radius {
    const big = Radius.circular(28), small = Radius.circular(8);
    if (selected) return const BorderRadius.all(big);
    return switch (position) {
      _GroupPos.first => const BorderRadius.horizontal(left: big, right: small),
      _GroupPos.last => const BorderRadius.horizontal(left: small, right: big),
      _GroupPos.middle => const BorderRadius.all(small),
    };
  }

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.onSecondaryContainer : AppColors.onSurface;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: 'クリップの角度 $angle度${recommended ? '（おすすめ）' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected
            ? AppColors.secondaryContainer
            : AppColors.surfaceContainerHigh,
        borderRadius: _radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CustomPaint(
                  size: const Size(48, 36),
                  painter: _AnglePainter(
                    angle: angle,
                    color: selected
                        ? AppColors.onSecondaryContainer
                        : AppColors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(
                        Icons.check_circle_outline_rounded,
                        size: 18,
                        color: fg,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      '$angle度',
                      style: AppText.titleMedium.copyWith(color: fg),
                    ),
                  ],
                ),
                if (recommended)
                  Text('おすすめ', style: AppText.labelMedium.copyWith(color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 角度の絵（Figma の 48×36 の絵と同じ：下の線と、その角度に傾いた棒）。角度ごとに傾きが変わるので描く
class _AnglePainter extends CustomPainter {
  const _AnglePainter({required this.angle, required this.color});
  final int angle;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 48, sy = size.height / 36;
    canvas.drawLine(
      Offset(6 * sx, 32 * sy),
      Offset(42 * sx, 32 * sy),
      Paint()
        ..color = AppColors.outline
        ..strokeWidth = 2,
    );
    final r = angle * math.pi / 180;
    canvas.drawLine(
      Offset(24 * sx, 32 * sy),
      Offset((24 + 26 * math.sin(r)) * sx, (32 - 26 * math.cos(r)) * sy),
      Paint()
        ..color = color
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_AnglePainter old) =>
      old.angle != angle || old.color != color;
}

/// 色の丸（Figma：48の丸。選んだものは primary の太い輪。色だけで伝えないようチェックも付ける）
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.hex,
    required this.name,
    required this.selected,
    required this.onTap,
  });
  final String hex;
  final String name;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Color(int.parse('FF${hex.substring(1)}', radix: 16));
    final light = c.computeLuminance() > 0.5;
    return Semantics(
      button: true,
      selected: selected,
      label: '色：$name',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Container(
            width: selected ? 36 : 40,
            height: selected ? 36 : 40,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            child: selected
                ? Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: light ? AppColors.onSurface : Colors.white,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── S8 OTに確認を頼む ─────────────────────────

/// S8 OTに確認を頼む（Figma：モーダルのボトムシート。showModalBottomSheet の中身）
class ReviewRequestDialog extends StatefulWidget {
  const ReviewRequestDialog({
    super.key,
    required this.caseId,
    required this.design,
  });
  final String caseId;
  final Map<String, dynamic> design;
  @override
  State<ReviewRequestDialog> createState() => _ReviewRequestDialogState();
}

class _ReviewRequestDialogState extends State<ReviewRequestDialog> {
  List<Map<String, dynamic>> _list = [];
  String? _email;
  final _other = TextEditingController();
  final _msg = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _url;

  @override
  void initState() {
    super.initState();
    Api.instance
        .get('/v1/therapists')
        .then((r) {
          final l = (r is Map ? r['therapists'] : r) as List? ?? [];
          if (mounted) {
            setState(
              () => _list = [for (final t in l) Map<String, dynamic>.from(t)],
            );
          }
        })
        .catchError((e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  Future<void> _send() async {
    final email = _email ?? _other.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.instance.post(
        '/v1/cases/${widget.caseId}/review-request',
        {
          'reviewer_email': email,
          'design_id': widget.design['design_id'],
          'message_ja': _msg.text.trim(),
        },
      );
      setState(() => _url = '${r['review_url']}');
    } on ApiError catch (e) {
      setState(
        () => _error = switch (e.code) {
          'REVIEWER_NOT_ALLOWED' => 'このアドレスはOTとして登録されていません。',
          'RENDER_FAILED' => 'このままでは刷れない形でした。形を直してから、もう一度頼んでください。',
          _ => e.message,
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  num? _param(String part, String name) {
    for (final p in (widget.design['params'] as List? ?? [])) {
      if (p['part_id'] == part && p['name'] == name) return p['value'] as num?;
    }
    return null;
  }

  /// 頼む版の画像と番号（Figma：surfaceContainerHighest の箱）
  Widget _versionBox() {
    final t = _param('cover', 'cover_thickness_mm');
    final a = _param('c_clip', 'angle_deg');
    final sub = [
      if (t != null) 'カバー ${t}mm',
      if (a != null) 'クリップ ${a.toInt()}度',
    ].join('・');
    final iso = _isoPath(widget.design);
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: iso == null
                    ? const Icon(
                        Icons.view_in_ar_rounded,
                        color: AppColors.onSurfaceVariant,
                      )
                    : _StorageImage(
                        path: iso,
                        fallback: const Icon(
                          Icons.view_in_ar_rounded,
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.design['revision'] ?? 1}版',
                    style: AppText.titleMedium.copyWith(
                      color: AppColors.onSurface,
                    ),
                  ),
                  if (sub.isNotEmpty) Text(sub, style: AppText.supporting),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _spaced(16, [
            Semantics(
              header: true,
              child: Text(
                'OTに確認を頼む（${widget.design['revision'] ?? 1}版）',
                style: AppText.headlineSmall.copyWith(
                  color: AppColors.onSurface,
                ),
              ),
            ),
            if (_url != null) ...[
              const InfoCard(
                tone: NoticeTone.success,
                child: Text('頼みました。確認用のURLをOTに伝えてください。'),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SelectableText(
                  _url!,
                  style: AppText.bodyLarge.copyWith(color: AppColors.onSurface),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: _url!)),
                icon: const Icon(Icons.content_copy_rounded),
                label: const Text('コピー'),
              ),
            ] else ...[
              _versionBox(),
              if (_list.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SubLabel('確認してほしいOT'),
                    const SizedBox(height: 2),
                    for (final t in _list)
                      ChoiceButton(
                        label: '${t['display_name'] ?? t['email']}',
                        sub: '${t['email']}',
                        selected: _email == t['email'],
                        onTap: () => setState(() => _email = '${t['email']}'),
                      ),
                  ],
                ),
              TextField(
                controller: _other,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: '一覧にないときだけ：メールアドレス',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _email = null),
              ),
              TextField(
                controller: _msg,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'ひとこと（任意）',
                  border: OutlineInputBorder(),
                ),
              ),
              const InfoCard(
                tone: NoticeTone.info,
                child: Text('頼むと、形（模様を含む）はこの版で固定されます。色はあとでも変えられます。'),
              ),
              if (_busy) const BusyCard(text: '印刷用のデータを準備しています（20〜60秒）'),
              if (_error != null) ErrorCard(message: _error!),
              FilledButton.icon(
                onPressed:
                    _busy || (_email == null && _other.text.trim().isEmpty)
                    ? null
                    : _send,
                icon: const Icon(Icons.send_rounded),
                label: const Text('頼む'),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ]),
        ),
      ),
    );
  }
}
