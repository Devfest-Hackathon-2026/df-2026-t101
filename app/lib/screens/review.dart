import 'package:flutter/material.dart';

import '../bridge/viewer.dart';
import '../data/api.dart';
import '../data/session.dart';
import '../router.dart';
import '../widgets/ui.dart';

const _checks = {
  'dimensions_reviewed': '寸法を見た',
  'edges_safe': '角が安全（丸めてある）',
  'not_an_orthosis': '握った指を無理に開かせない形である（装具ではない）',
  'palm_open_wrist_free': '手のひら側が開いていて、手首を覆っていない',
  'no_mouth_contact': '口に入れない',
  'user_informed': '本人と家族に使い方と「痛みや赤みが出たらやめる」を伝える',
};

const _partJa = {
  'cover': 'カバー',
  'c_clip': 'クリップ',
  'strap_slits': 'ベルト穴',
  'air_holes': '空気穴',
  'rail': 'レール',
  'tpu_sleeve': 'TPUの筒',
};

const _sourceJa = {
  'measured': '採寸',
  'rule': 'ルール',
  'interview': '聞き取り',
  'ai': 'AI',
  'default': '既定',
  'user': '本人',
};

/// 採寸の警告（docs/measurement.md §7.5）。true は目立たせる（warning）、false はお知らせ（info）
const _warningJa = {
  'MESH_SCALE_INCONSISTENT': ('手の甲の点の長さの比がずれています', true),
  'ANGLE_DISAGREE': ('メッシュと比較用の角度の差が15度を超えています', true),
  'LENGTH_UNSTABLE': ('区間の長さのばらつきが大きく、点がずれている可能性があります', true),
  'ODD_PROPORTION': ('指の長さの並びが不自然です。点の取り違えの可能性があります', true),
  'FEW_FRAMES': ('使えたフレームが少なく、集計が不安定です', true),
  'VIEW_BIASED': ('見えていない向きがあります', true),
  'POINTS_MANUAL': ('手首と付け根の点を手で直しました', false),
  'COIN_MANUAL': ('1円玉を手で指定しました', false),
  'ABDUCTION_UNKNOWN': ('指の開きの向きが決まらず、0度にしました（比較用）', false),
  'FINGERS_SPREAD': ('指の間隔が広く、比較用の太さを仮の比で出しました', false),
};

const _fingerJa = {
  'thumb': '親指',
  'index': '人差し指',
  'middle': '中指',
  'ring': '薬指',
  'pinky': '小指',
};

/// 指の曲がり角の差がこれを超えたら目立たせる（ANGLE_DISAGREE）
const _angleDisagreeDeg = 15;

/// 横に並べる（ナビゲーションレール＋2つの枠）幅。これより狭いと1列
const _wideBreakpoint = 1200.0;

/// S9 OT確認（MVP は最小限：3D・引数の表・確認項目・コメント・確認済み／差し戻し）。docs/screens.md S9
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.caseId});
  final String caseId;
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Map<String, dynamic>? _case;
  Map<String, dynamic>? _design;
  final Map<String, bool> _checked = {for (final k in _checks.keys) k: false};
  final _comment = TextEditingController();
  bool _busy = false;
  bool _showHand = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = Map<String, dynamic>.from(
        await Api.instance.get('/v1/cases/${widget.caseId}'),
      );
      final id = c['current_design_id'];
      Map<String, dynamic>? d;
      if (id != null) {
        final r = await Api.instance.get(
          '/v1/cases/${widget.caseId}/designs/$id',
        );
        d = Map<String, dynamic>.from(r['design'] ?? r);
      }
      setState(() {
        _case = c;
        _design = d;
      });
    } on ApiError catch (e) {
      setState(
        () => _error = e.code == 'FORBIDDEN' ? 'このケースを見る権限がありません。' : e.message,
      );
    }
  }

  Future<void> _decide(String decision) async {
    final d = _design!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.instance.post(
        '/v1/cases/${widget.caseId}/designs/${d['design_id']}/approval',
        {
          'decision': decision,
          'geometry_hash': d['geometry_hash'],
          'comment_ja': _comment.text.trim(),
          'checklist': _checked,
        },
      );
      if (!mounted) return;
      if (r['case_status'] == 'approved') {
        Navigator.of(context)
            .pushNamed(AppRouter.print(widget.caseId, d['design_id']));
      } else {
        showError(context, '差し戻しました。');
        _load();
      }
    } on ApiError catch (e) {
      setState(
        () => _error = switch (e.code) {
          'STALE_DESIGN' => '確認対象が変わりました。最新の版を確認してください。',
          'CHECKLIST_INCOMPLETE' => '確認項目をすべて確かめてください。',
          _ => e.message,
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- 表示用の値 ----

  List<String> get _warnings => List<String>.from(
    _case?['measurement']?['quality']?['warnings'] as List? ?? const [],
  );

  List<Map<String, dynamic>> get _unresolved => [
    for (final v in (_design?['review']?['unresolved_issues'] as List? ?? []))
      if (v is Map) Map<String, dynamic>.from(v),
  ];

  bool get _approved => _design?['approval']?['status'] == 'approved';

  String get _title {
    final t = '${_case?['title'] ?? 'OT確認'}';
    final rev = _design?['revision'];
    return rev == null ? t : '$t・版$rev';
  }

  String get _meta {
    final parts = <String>[];
    final at = _fmtDate(_design?['approval']?['requested_at']);
    if (at != null) parts.add('依頼 $at');
    final toolD = _case?['requirements']?['tool_d_mm'];
    if (toolD != null) parts.add('道具の太さ ${toolD}mm');
    return parts.join(' ・ ');
  }

  Widget? _approvalLabel() => switch (_design?['approval']?['status']) {
    'requested' => const StatusLabel(label: '確認待ち', tone: StatusTone.warning),
    'approved' => const StatusLabel(label: '確認済み', tone: StatusTone.success),
    'rejected' => const StatusLabel(label: '差し戻し済み', tone: StatusTone.error),
    _ => null,
  };

  static String? _fmtDate(Object? v) {
    if (v == null) return null;
    final t = DateTime.tryParse('$v')?.toLocal();
    if (t == null) return '$v';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  bool get _canApprove => !_busy && !_checked.values.any((v) => !v);

  // ---- 部品（枠） ----

  Widget _viewerPanel(Map<String, dynamic> d) {
    final parts = Map<String, dynamic>.from(d['files']?['parts'] ?? {});
    return _Panel(
      icon: Icons.visibility_rounded,
      title: '3Dで確かめる',
      children: [
        SizedBox(
          height: 296,
          child: Stack(
            children: [
              Positioned.fill(
                child: Viewer3D(
                  handPath: d['hand_overlay']?['mesh_path'],
                  parts: [
                    for (final e in parts.entries)
                      PartFile(e.key, '${e.value['preview_stl']}'),
                  ],
                  color: '${d['style']?['color'] ?? '#2A9D8F'}',
                  tool: (d['tool'] as Map?)?.cast<String, dynamic>(),
                  handSide: _case?['requirements']?['hand_side'] as String?,
                  showHand: _showHand,
                ),
              ),
              if (d['hand_overlay']?['mesh_path'] != null && parts.isNotEmpty)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _HandToggle(
                    value: _showHand,
                    onChanged: (v) => setState(() => _showHand = v),
                  ),
                ),
            ],
          ),
        ),
        Text(
          '写真はありません。採寸の数値と手の3Dメッシュだけを表示しています。',
          style: AppText.bodySmall.copyWith(color: AppColors.onSurfaceVariant),
        ),
        if ('${d['summary_ja'] ?? ''}'.isNotEmpty)
          InfoCard(child: Text('${d['summary_ja']}')),
      ],
    );
  }

  Widget _warningsPanel() => _Panel(
    icon: Icons.warning_amber_rounded,
    title: '採寸の警告',
    children: [
      for (final w in _warnings)
        InfoCard(
          tone: (_warningJa[w]?.$2 ?? true)
              ? NoticeTone.warning
              : NoticeTone.info,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: w,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                if (_warningJa[w] != null)
                  TextSpan(text: '　${_warningJa[w]!.$1}'),
              ],
            ),
          ),
        ),
    ],
  );

  /// 指の曲がり角：メッシュ（flexion_deg）と比較用の MediaPipe（angles_alt_deg）
  List<(String, num, num)> _angleRows() {
    final fingers = _case?['measurement']?['fingers'];
    if (fingers is! Map) return const [];
    final rows = <(String, num, num)>[];
    for (final f in _fingerJa.keys) {
      final fd = fingers[f];
      if (fd is! Map) continue;
      final mesh = fd['flexion_deg'];
      final alt = fd['angles_alt_deg'];
      if (mesh is! Map || alt is! Map) continue;
      for (final j in const ['mcp', 'pip', 'dip']) {
        final a = mesh[j], b = alt[j];
        if (a is! num || b is! num) continue;
        final name = _fingerJa[f]!;
        final label = j == 'mcp' ? '$nameの付け根（MP）' : '$name ${j.toUpperCase()}';
        rows.add((label, a, b));
      }
    }
    return rows;
  }

  Widget _anglesPanel(List<(String, num, num)> rows) {
    // 関節の列は残りの幅（PCでは176くらい）、数値の列は固定幅
    const widths = [176.0, 72.0, 80.0, 64.0];
    Widget cell(int i, Widget child) {
      final box = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      );
      return i == 0
          ? Expanded(child: box)
          : SizedBox(width: widths[i], child: box);
    }

    final head = AppText.labelMedium.copyWith(
      color: AppColors.onSurfaceVariant,
    );
    return _Panel(
      icon: Icons.threed_rotation_rounded,
      title: '指の曲がり角（度）の比較',
      gap: 0,
      children: [
        Row(
          children: [
            cell(0, Text('関節', style: head)),
            cell(1, Text('メッシュ', style: head)),
            cell(2, Text('MediaPipe', style: head)),
            cell(3, Text('差', style: head)),
          ],
        ),
        for (final (label, a, b) in rows)
          Builder(
            builder: (context) {
              final diff = (a - b).abs();
              final bad = diff > _angleDisagreeDeg;
              final st = AppText.bodyMedium.copyWith(
                color: bad ? AppColors.onWarningContainer : AppColors.onSurface,
              );
              return Semantics(
                label: bad ? '注意：差が$_angleDisagreeDeg度を超えています' : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: bad ? AppColors.warningContainer : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      cell(
                        0,
                        Row(
                          children: [
                            if (bad) ...[
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 18,
                                color: AppColors.warning,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(child: Text(label, style: st)),
                          ],
                        ),
                      ),
                      cell(1, Text(a.round().toString(), style: st)),
                      cell(2, Text(b.round().toString(), style: st)),
                      cell(3, Text(diff.round().toString(), style: st)),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        Text.rich(
          TextSpan(
            style: AppText.bodySmall.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
            children: const [
              TextSpan(text: '差が15度を超える関節（'),
              TextSpan(
                text: 'ANGLE_DISAGREE',
                style: TextStyle(fontFamily: 'monospace'),
              ),
              TextSpan(text: '）を目立たせています。'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _paramsPanel(Map<String, dynamic> d) {
    final params = [
      for (final p in (d['params'] as List? ?? []))
        if (p is Map) Map<String, dynamic>.from(p),
    ];
    return _Panel(
      icon: Icons.edit_rounded,
      title: '寸法と理由の一覧',
      children: [
        LayoutBuilder(
          builder: (context, c) {
            const minWidth = 720.0;
            final table = _ParamTable(params: params);
            if (c.maxWidth >= minWidth) return table;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: minWidth, child: table),
            );
          },
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '印：',
              style: AppText.labelMedium.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const StatusLabel(label: '範囲で止めた', tone: StatusTone.warning),
            const _PrimaryLabel(label: '本人が変更'),
          ],
        ),
      ],
    );
  }

  Widget _unresolvedPanel(List<Map<String, dynamic>> issues) => _Panel(
    icon: Icons.auto_awesome_rounded,
    title: 'AIの確認で解決しなかった点',
    children: [
      for (final v in issues)
        InfoCard(
          tone: v['severity'] == 'high' ? NoticeTone.error : NoticeTone.warning,
          child: Text('${v['description_ja'] ?? ''}'),
        ),
    ],
  );

  List<Widget> _checklist() => [
    Column(
      children: [
        for (final e in _checks.entries)
          CheckboxListTile(
            value: _checked[e.key],
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text(e.value),
            onChanged: (v) => setState(() => _checked[e.key] = v ?? false),
          ),
      ],
    ),
    TextField(
      controller: _comment,
      maxLength: 500,
      decoration: const InputDecoration(
        labelText: 'コメント',
        helperText: '差し戻すときは理由を書いてください',
        border: OutlineInputBorder(),
      ),
    ),
  ];

  Widget _rejectButton() => OutlinedButton.icon(
    onPressed: _busy ? null : () => _decide('reject'),
    icon: const Icon(Icons.undo_rounded),
    label: const Text('差し戻す'),
  );

  Widget _approveButton() => FilledButton.icon(
    onPressed: _canApprove ? () => _decide('approve') : null,
    icon: const Icon(Icons.verified_user_rounded),
    label: const Text('確認済みにする'),
  );

  /// 状態の表示（エラー・読み込み中・空）
  List<Widget> _notices(Map<String, dynamic>? d) => [
    if (_error != null) ErrorCard(message: _error!),
    if (_case == null && _error == null) const BusyCard(text: '読み込んでいます'),
    if (_case != null && d == null)
      const InfoCard(child: Text('確認を頼まれている版はありません。')),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) =>
          c.maxWidth >= _wideBreakpoint ? _wide(context) : _narrow(context),
    );
  }

  // ---- PC：ナビゲーションレール＋左右2つの枠（Figma S9 OT確認（PC）） ----

  Widget _wide(BuildContext context) {
    final d = _design;
    final angles = _angleRows();
    final status = _approvalLabel();
    final meta = _meta;
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _rail(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(8, 24, 32, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 見出し
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 12,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Semantics(
                                    header: true,
                                    child: Text(
                                      _title,
                                      style: AppText.headlineMedium,
                                    ),
                                  ),
                                  ?status,
                                ],
                              ),
                              if (meta.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(meta, style: AppText.supporting),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Icon(
                          Icons.account_circle_rounded,
                          size: 32,
                          color: AppColors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          Session.instance.displayName,
                          style: AppText.bodyLarge.copyWith(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ..._notices(d),
                    if (d != null)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 440,
                            child: _Column(
                              children: [
                                _viewerPanel(d),
                                if (_warnings.isNotEmpty) _warningsPanel(),
                                if (angles.isNotEmpty) _anglesPanel(angles),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: _Column(
                              children: [
                                _paramsPanel(d),
                                if (_unresolved.isNotEmpty)
                                  _unresolvedPanel(_unresolved),
                                _Panel(
                                  icon: Icons.check_circle_outline_rounded,
                                  title: '確認項目',
                                  children: [
                                    ..._checklist(),
                                    Wrap(
                                      alignment: WrapAlignment.end,
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        _rejectButton(),
                                        _approveButton(),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rail(BuildContext context) {
    final d = _design;
    return NavigationRail(
      minWidth: 96,
      backgroundColor: AppColors.surface,
      labelType: NavigationRailLabelType.all,
      groupAlignment: -1,
      selectedIndex: 1,
      indicatorColor: AppColors.secondaryContainer,
      selectedLabelTextStyle: AppText.labelMedium.copyWith(
        color: AppColors.onSurface,
      ),
      unselectedLabelTextStyle: AppText.labelMedium.copyWith(
        color: AppColors.onSurfaceVariant,
      ),
      leading: Padding(
        padding: const EdgeInsets.only(top: 0, bottom: 16),
        child: ExcludeSemantics(
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.back_hand_rounded,
              color: AppColors.onPrimaryContainer,
            ),
          ),
        ),
      ),
      destinations: [
        const NavigationRailDestination(
          icon: Icon(Icons.account_circle_rounded),
          label: Text('ホーム'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.verified_user_rounded),
          label: Text('確認依頼'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.print_rounded),
          label: const Text('印刷'),
          disabled: !_approved,
        ),
      ],
      onDestinationSelected: (i) {
        final nav = Navigator.of(context);
        if (i == 0) {
          nav.pushNamedAndRemoveUntil('/', (r) => false);
        } else if (i == 2 && _approved && d != null) {
          nav.pushNamed(AppRouter.print(widget.caseId, '${d['design_id']}'));
        }
      },
    );
  }

  // ---- スマホ・狭い画面：1列 ----

  Widget _narrow(BuildContext context) {
    final d = _design;
    final angles = _angleRows();
    final status = _approvalLabel();
    final meta = _meta;
    return AppPage(
      title: 'OT確認',
      bottom: d == null
          ? null
          : Row(
              children: [
                Expanded(child: _rejectButton()),
                const SizedBox(width: 8),
                Expanded(child: _approveButton()),
              ],
            ),
      children: [
        ..._notices(d),
        if (d != null)
          _Column(
            gap: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(_title, style: AppText.titleLarge),
                      ?status,
                    ],
                  ),
                  if (meta.isNotEmpty) Text(meta, style: AppText.supporting),
                ],
              ),
              _viewerPanel(d),
              if (_warnings.isNotEmpty) _warningsPanel(),
              if (angles.isNotEmpty) _anglesPanel(angles),
              _paramsPanel(d),
              if (_unresolved.isNotEmpty) _unresolvedPanel(_unresolved),
              _Panel(
                icon: Icons.check_circle_outline_rounded,
                title: '確認項目',
                children: _checklist(),
              ),
            ],
          ),
      ],
    );
  }
}

/// 縦に並べて、間をあける
class _Column extends StatelessWidget {
  const _Column({required this.children, this.gap = 16});
  final List<Widget> children;
  final double gap;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ],
  );
}

/// 見出し付きの枠（Figma の各カード：surfaceContainerLow・角丸16・余白24・見出しは Title Large＋アイコン）
class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.children,
    this.gap = 16,
  });
  final IconData icon;
  final String title;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Row(
              children: [
                Icon(icon, size: 22, color: AppColors.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: AppText.titleLarge)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 3Dの上に重ねる「手を半透明で重ねる」スイッチ（白い丸い札）
class _HandToggle extends StatelessWidget {
  const _HandToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceContainerLowest,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Semantics(
          toggled: value,
          label: '手を半透明で重ねる',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '手を半透明で重ねる',
                  style: AppText.labelLarge.copyWith(
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Switch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 状態の札の primary 版（Figma の M3/Status label Tone=Primary）。ui.dart の StatusLabel にない色のため
class _PrimaryLabel extends StatelessWidget {
  const _PrimaryLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
    decoration: BoxDecoration(
      color: AppColors.primaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.person_rounded,
          size: 16,
          color: AppColors.onPrimaryContainer,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: AppText.labelMedium.copyWith(
            color: AppColors.onPrimaryContainer,
          ),
        ),
      ],
    ),
  );
}

/// 引数（寸法）の一覧表。clamped は warningContainer＋「範囲で止めた」、override_by_user は primaryContainer＋「本人が変更」。
/// 色だけで伝えないよう、必ず札（アイコンと文字）を添える
class _ParamTable extends StatelessWidget {
  const _ParamTable({required this.params});
  final List<Map<String, dynamic>> params;

  // 部品・名前・値・範囲・基準値・決め方 は固定幅、理由は残り
  static const _w = [72.0, 184.0, 124.0, 96.0, 64.0, 76.0];

  static Widget _cell(int i, Widget child) {
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: child,
    );
    return i < _w.length
        ? SizedBox(width: _w[i], child: padded)
        : Expanded(child: padded);
  }

  static String _num(Object? v) => v == null ? '—' : '$v';

  static String _range(Map<String, dynamic> p) {
    final ch = p['choices'];
    if (ch is List && ch.isNotEmpty) return ch.join('／');
    final r = p['range'];
    if (r is List && r.length == 2 && r[0] != null) {
      return '${_num(r[0])}〜${_num(r[1])}';
    }
    if (r != null && r is! List) return '$r';
    return '—';
  }

  static String _unit(Object? u) => switch (u) {
    null => '',
    'deg' => ' 度',
    _ => ' $u',
  };

  @override
  Widget build(BuildContext context) {
    final head = AppText.labelMedium.copyWith(
      color: AppColors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              for (final (i, t) in const [
                '部品',
                '名前（専門用語）',
                '値',
                '範囲',
                '基準値',
                '決め方',
                '理由',
              ].indexed)
                _cell(i, Text(t, style: head)),
            ],
          ),
        ),
        for (final p in params) _row(p),
      ],
    );
  }

  Widget _row(Map<String, dynamic> p) {
    final clamped = p['clamped'] == true;
    final override = p['override_by_user'] == true;
    final Color? bg = clamped
        ? AppColors.warningContainer
        : override
        ? AppColors.primaryContainer
        : null;
    final fg = clamped
        ? AppColors.onWarningContainer
        : override
        ? AppColors.onPrimaryContainer
        : AppColors.onSurface;
    final st = AppText.bodyMedium.copyWith(color: fg);
    final label = p['label_ja'];
    final partId = '${p['part_id'] ?? ''}';
    return Container(
      decoration: bg != null
          ? BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8))
          : const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.outlineVariant),
              ),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cell(0, Text(_partJa[partId] ?? partId, style: st)),
          _cell(
            1,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label != null) Text('$label', style: st),
                Text(
                  '${p['name'] ?? ''}',
                  style: label != null
                      ? AppText.bodySmall.copyWith(
                          color: clamped || override
                              ? fg
                              : AppColors.onSurfaceVariant,
                        )
                      : st,
                ),
              ],
            ),
          ),
          _cell(
            2,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_num(p['value'])}${_unit(p['unit'])}',
                  style: AppText.labelLarge.copyWith(color: fg),
                ),
                if (clamped) ...[
                  const SizedBox(height: 4),
                  const StatusLabel(label: '範囲で止めた', tone: StatusTone.warning),
                ],
                if (override) ...[
                  const SizedBox(height: 4),
                  const _PrimaryLabel(label: '本人が変更'),
                ],
              ],
            ),
          ),
          _cell(3, Text(_range(p), style: st)),
          _cell(4, Text(_num(p['baseline']), style: st)),
          _cell(
            5,
            Text(_sourceJa[p['source']] ?? '${p['source'] ?? ''}', style: st),
          ),
          _cell(6, Text('${p['reason_ja'] ?? ''}', style: st)),
        ],
      ),
    );
  }
}
