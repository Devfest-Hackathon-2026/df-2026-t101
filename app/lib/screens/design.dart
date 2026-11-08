import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/viewer.dart';
import '../data/api.dart';
import '../data/files.dart';
import '../router.dart';
import '../widgets/ui.dart';

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
    this.recommendedAngle,
  });
  final String caseId;
  final String? designId;
  final bool autoStart;
  final int? recommendedAngle; // AIが選んだ角度（版をまたいで「おすすめ」を出すため）
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
  late int? _recommendedAngle = widget.recommendedAngle;
  String? _clarify;
  final _instruction = TextEditingController();
  final Map<String, num> _pending = {}; // スライダーで直した値（part_id.name → 値）
  Timer? _poll;
  int _pollCount = 0;

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
        if (st == 'generating') _startPolling();
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
      _recommendedAngle ??= _angleParam(d)?['source'] == 'ai'
          ? (_angleParam(d)?['value'] as num?)?.toInt()
          : null;
      _pending.clear();
    });
  }

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
        if (id == null) return;
        final r = await Api.instance.get('/v1/cases/$_cid/designs/$id');
        final d = Map<String, dynamic>.from(r['design'] ?? r);
        final p = Map<String, dynamic>.from(d['progress'] ?? {});
        if (!mounted) return;
        setState(() {
          _stage = p['step'] as String? ?? _stage;
          _round = (p['round'] as num?)?.toInt();
          _progressIso = _isoPath(d) ?? _progressIso;
        });
        if (d['status'] != 'generating' && !_generating) {
          _poll?.cancel();
          _setDesign(d);
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
      _poll?.cancel();
      setState(() {
        _error = e.code == 'AI_UNAVAILABLE'
            ? 'AIが混み合っています。少し待ってもう一度試してください。'
            : e.message;
        _errorRetry = true;
      });
    } finally {
      if (mounted) setState(() => _generating = false);
    }
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
        _setDesign(Map<String, dynamic>.from(r['design']));
        if (r['design']['design_id'] != d['design_id'] && mounted) {
          // 新しい版：パスも新しい版にする（戻るでケース一覧へ）
          final nid = r['design']['design_id'];
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              settings: RouteSettings(name: AppRouter.design(_cid, nid)),
              builder: (_) => DesignScreen(
                caseId: _cid,
                designId: nid,
                recommendedAngle: _recommendedAngle,
              ),
            ),
          );
        }
      }
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
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
    if (_generating || _design?['status'] == 'generating') {
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
        child: const Text('中止して戻る（作るのは続きます）'),
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
          child: Text('数分かかることがあります。画面を閉じても、作るのは続きます。'),
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
    final angle = (_angleParam(d)?['value'] as num?)?.toInt();
    final toolD =
        (_param('c_clip', 'tool_d_mm') ??
                _case?['requirements']?['tool_d_mm'] ??
                8.5)
            .toDouble();
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
              'AIの確認で解決しなかった点があります：\n${issues.map((i) => '・${i is Map ? (i['message_ja'] ?? i['issue_ja'] ?? i) : i}').join('\n')}',
            ),
          ),
        if (approval == 'rejected')
          InfoCard(
            tone: NoticeTone.error,
            icon: Icons.reply_rounded,
            child: Text('差し戻されました：${d['approval']?['comment_ja'] ?? ''}'),
          ),
        if (_busy != null) BusyCard(text: _busy!),
        if (_error != null) ErrorCard(message: _error!),
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
                    for (final e in parts.entries)
                      PartFile(e.key, '${e.value['preview_stl']}'),
                  ],
                  color: color,
                  toolDmm: toolD,
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
        _mainDims(d, toolD, angle),
        _summary(d),
        // クリップの角度（ADR-0013）
        const _Heading('クリップの角度'),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, a) in const [0, 20, 40].indexed) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  child: _AngleButton(
                    angle: a,
                    selected: a == angle,
                    recommended: a == _recommendedAngle,
                    position: i == 0
                        ? _GroupPos.first
                        : (i == 2 ? _GroupPos.last : _GroupPos.middle),
                    onTap: () {
                      if (a != angle && _busy == null) {
                        _refine({
                          'clip_angle_deg': a,
                        }, 'クリップを$a度で描き直しています（カバーはそのままです）');
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
                    : () => _refine({'instruction': t}, '「$t」に合わせて直しています'),
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
                  : () => _refine({
                      'instruction': _instruction.text.trim(),
                    }, '「${_instruction.text.trim()}」に合わせて直しています'),
            ),
          ],
        ),
        if (_clarify != null)
          InfoCard(
            tone: NoticeTone.info,
            icon: Icons.help_outline_rounded,
            child: Text(_clarify!),
          ),
        ..._sliders(d),
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
  Widget _mainDims(Map<String, dynamic> d, double toolD, int? angle) {
    final t = _param('cover', 'cover_thickness_mm');
    final inner = _param('c_clip', 'inner_d_mm');
    final tiles = [
      _DimTile('カバーの厚み', '${t ?? '—'} mm'),
      _DimTile('道具の太さ', '${toolD.toStringAsFixed(1)} mm'),
      if (inner != null) _DimTile('クリップの内径', '$inner mm'),
      _DimTile('クリップの角度', '${angle ?? '—'}度'),
    ];
    final estimated = _case?['requirements']?['tool_d_source'] == 'category';
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

  /// 数値のスライダー（範囲は版の params の range。クリップの内径・道具の太さ・角度は出さない）
  List<Widget> _sliders(Map<String, dynamic> d) {
    final ps = [
      for (final p in (d['params'] as List? ?? []))
        if (p['range'] is List &&
            (p['range'] as List).length == 2 &&
            !(p['part_id'] == 'c_clip' &&
                (p['name'] == 'tool_d_mm' ||
                    p['name'] == 'angle_deg' ||
                    p['name'] == 'inner_d_mm')))
          Map<String, dynamic>.from(p),
    ];
    if (ps.isEmpty) return const [];
    return [
      const _Heading('数値で直す'),
      for (final p in ps)
        Builder(
          builder: (context) {
            final key = '${p['part_id']}.${p['name']}';
            final lo = (p['range'][0] as num).toDouble(),
                hi = (p['range'][1] as num).toDouble();
            final v = (_pending[key] ?? p['value'] as num).toDouble().clamp(
              lo,
              hi,
            );
            final isInt = p['value'] is int && p['range'][0] is int;
            return MergeSemantics(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${p['label_ja'] ?? p['name']}',
                            style: AppText.bodyLarge.copyWith(
                              color: AppColors.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${isInt ? v.round() : v.toStringAsFixed(1)} ${p['unit'] ?? ''}',
                          style: AppText.titleMedium.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Slider(
                      min: lo,
                      max: hi,
                      divisions: isInt
                          ? (hi - lo).round().clamp(1, 100)
                          : ((hi - lo) * 10).round().clamp(1, 200),
                      value: v,
                      onChanged: (x) => setState(
                        () => _pending[key] = isInt
                            ? x.round()
                            : double.parse(x.toStringAsFixed(1)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      if (_pending.isNotEmpty)
        FilledButton(
          onPressed: _busy != null
              ? null
              : () => _refine({
                  'param_changes': [
                    for (final e in _pending.entries)
                      {
                        'part_id': e.key.split('.').first,
                        'name': e.key.split('.').last,
                        'value': e.value,
                      },
                  ],
                }, '値に合わせて作り直しています'),
          child: const Text('この値で作り直す'),
        ),
    ];
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
