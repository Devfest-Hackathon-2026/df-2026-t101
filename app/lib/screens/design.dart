import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/viewer.dart';
import '../data/api.dart';
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
        bottom: FilledButton(onPressed: _generate, child: const Text('もう一度作る')),
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
          child: Text('まだ形がありません。「形を作る」を押すと、カバーとクリップの形を作ります（1〜3分）。'),
        ),
    ],
  );

  Widget _progressPage() {
    final cur = _steps.indexOf(
      _stage == 'rendering' ? 'shelling' : (_stage ?? 'selecting'),
    );
    return AppPage(
      title: '形を作っています',
      bottom: OutlinedButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('中止して戻る（作るのは続きます）'),
      ),
      children: [
        for (final (i, s) in _steps.indexed)
          ListTile(
            leading: Icon(
              i < cur
                  ? Icons.check_circle
                  : (i == cur
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
              color: i <= cur ? AppColors.primary : AppColors.line,
            ),
            title: Text(
              '${_stepJa[s]}${s == 'reviewing' && i == cur && _round != null ? '（$_round/3回目）' : ''}',
            ),
          ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: LinearProgressIndicator(),
        ),
        if (_error != null) ErrorCard(message: _error!, onRetry: _generate),
      ],
    );
  }

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
    return AppPage(
      title: '形を確かめる（${d['revision'] ?? 1}版）',
      onBack: () =>
          Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (approval == 'approved')
            FilledButton(
              onPressed: () =>
                  Navigator.of(context)
                      .pushNamed(AppRouter.print(_cid, d['design_id'])),
              child: const Text('印刷へ進む'),
            )
          else if (demo)
            FilledButton(
              onPressed: _busy != null ? null : _prepareDemo,
              child: const Text('印刷用データを作る（デモ）'),
            )
          else
            FilledButton(
              onPressed: _busy != null || locked
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          ReviewRequestDialog(caseId: _cid, design: d),
                    ),
              child: Text(locked ? '確認を待っています' : 'OTに確認を頼む'),
            ),
          if (demo) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy != null
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          ReviewRequestDialog(caseId: _cid, design: d),
                    ),
              child: const Text('OTに確認を頼む'),
            ),
          ],
        ],
      ),
      children: [
        if (demo) const DemoBanner(),
        if (d['status'] == 'needs_attention')
          InfoCard(
            color: const Color(0xFFFFF4E0),
            icon: Icons.warning_amber_outlined,
            child: Text(
              'AIの確認で解決しなかった点があります：\n${issues.map((i) => '・${i is Map ? (i['message_ja'] ?? i['issue_ja'] ?? i) : i}').join('\n')}',
            ),
          ),
        if (approval == 'rejected')
          InfoCard(
            color: const Color(0xFFFDECEA),
            icon: Icons.reply,
            child: Text('差し戻されました：${d['approval']?['comment_ja'] ?? ''}'),
          ),
        if (_busy != null) BusyCard(text: _busy!),
        if (_error != null) ErrorCard(message: _error!),
        SizedBox(
          height: 380,
          child: parts.isEmpty
              ? const InfoCard(child: Text('3Dのデータがありません。'))
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
        SwitchListTile(
          title: const Text('手を重ねる'),
          subtitle: const Text('カバーが手の甲と関節に沿っているか、手のひら側と手首が開いているかを見ます'),
          value: _showHand,
          onChanged: (v) => setState(() => _showHand = v),
        ),
        // クリップの角度（ADR-0013）
        const Text(
          'クリップの角度',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final a in const [0, 20, 40])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceButton(
                    label: '$a度',
                    sub: a == _recommendedAngle ? 'おすすめ' : null,
                    selected: a == angle,
                    onTap: () {
                      if (a != angle && _busy == null) {
                        _refine({
                          'clip_angle_deg': a,
                        }, 'クリップを$a度で描き直しています（カバーはそのままです）');
                      }
                    },
                  ),
                ),
              ),
          ],
        ),
        if (locked)
          const Text(
            'OTに頼んだあとに角度を変えると、新しい版になり、もう一度確認を頼みます。',
            style: TextStyle(color: AppColors.sub),
          ),
        const SizedBox(height: 8),
        InfoCard(
          icon: Icons.auto_awesome_outlined,
          child: Text('${d['summary_ja'] ?? ''}'),
        ),
        _mainDims(d, toolD, angle),
        const SizedBox(height: 8),
        const Text(
          '言葉で直す',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
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
                onPressed: _busy != null
                    ? null
                    : () => _refine({'instruction': t}, '「$t」に合わせて直しています'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _instruction,
          maxLength: 300,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: '直したいこと（例：人差し指の関節のところをゆったり）',
            suffixIcon: IconButton(
              tooltip: '送る',
              icon: const Icon(Icons.send),
              onPressed: _busy != null || _instruction.text.trim().isEmpty
                  ? null
                  : () => _refine({
                      'instruction': _instruction.text.trim(),
                    }, '「${_instruction.text.trim()}」に合わせて直しています'),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_clarify != null)
          InfoCard(icon: Icons.help_outline, child: Text(_clarify!)),
        _sliders(d),
        const SizedBox(height: 8),
        const Text(
          '見た目',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _vibes.entries)
              SuggestButton(
                label: e.key,
                onPressed: _busy != null
                    ? null
                    : () => _refine({
                        'style': {'color': e.value},
                      }, '色を変えています'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _colors.entries)
              Semantics(
                button: true,
                selected: e.key.toUpperCase() == color.toUpperCase(),
                label: '色：${e.value}',
                excludeSemantics: true,
                onTap: _busy != null
                    ? null
                    : () => _refine({
                        'style': {'color': e.key},
                      }, '色を変えています'),
                child: InkWell(
                  onTap: _busy != null
                      ? null
                      : () => _refine({
                          'style': {'color': e.key},
                        }, '色を変えています'),
                  borderRadius: BorderRadius.circular(28),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Color(
                        int.parse('FF${e.key.substring(1)}', radix: 16),
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: e.key.toUpperCase() == color.toUpperCase()
                            ? AppColors.ink
                            : AppColors.line,
                        width: 3,
                      ),
                    ),
                    child: e.key.toUpperCase() == color.toUpperCase()
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                ),
              ),
          ],
        ),
        const Text(
          '色は形に関係ないので、確認を頼んだあとでも変えられます。',
          style: TextStyle(color: AppColors.sub),
        ),
      ],
    );
  }

  Widget _mainDims(Map<String, dynamic> d, double toolD, int? angle) {
    final t = _param('cover', 'cover_thickness_mm');
    return InfoCard(
      icon: Icons.straighten,
      child: Text(
        '主な寸法：カバーの厚み ${t ?? '—'} mm ／ 道具の太さ ${toolD.toStringAsFixed(1)} mm ／ クリップの角度 ${angle ?? '—'}度'
        '${_case?['requirements']?['tool_d_source'] == 'category' ? '\n道具の太さは推定です。刷る前に、定規で確かめてください。' : ''}',
      ),
    );
  }

  /// 数値のスライダー（範囲は版の params の range。クリップの内径・道具の太さ・角度は出さない）
  Widget _sliders(Map<String, dynamic> d) {
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
    if (ps.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      title: const Text('数値で直す'),
      children: [
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
              return ListTile(
                title: Text(
                  '${p['label_ja'] ?? p['name']}：${isInt ? v.round() : v.toStringAsFixed(1)} ${p['unit'] ?? ''}',
                ),
                subtitle: Slider(
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
              );
            },
          ),
        if (_pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
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
          ),
      ],
    );
  }
}

/// S8 OTに確認を頼む（ダイアログ）
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('OTに確認を頼む（${widget.design['revision'] ?? 1}版）'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_url != null) ...[
                const Text('頼みました。確認用のURLをOTに伝えてください。'),
                const SizedBox(height: 8),
                SelectableText(_url!),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _url!)),
                  icon: const Icon(Icons.copy),
                  label: const Text('コピー'),
                ),
              ] else ...[
                const Text('頼むと、形（模様を含む）はこの版で固定されます。色はあとでも変えられます。'),
                const SizedBox(height: 8),
                for (final t in _list)
                  ChoiceButton(
                    label: '${t['display_name'] ?? t['email']}',
                    sub: '${t['email']}',
                    selected: _email == t['email'],
                    onTap: () => setState(() => _email = '${t['email']}'),
                  ),
                TextField(
                  controller: _other,
                  decoration: const InputDecoration(
                    labelText: '一覧にないときだけ：メールアドレス',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() => _email = null),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _msg,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'ひとこと（任意）',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_busy) const BusyCard(text: '印刷用のデータを準備しています（20〜60秒）'),
                if (_error != null) ErrorCard(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
        if (_url == null)
          FilledButton(
            onPressed: _busy || (_email == null && _other.text.trim().isEmpty)
                ? null
                : _send,
            child: const Text('頼む'),
          ),
      ],
    );
  }
}
