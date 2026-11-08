import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/measure_engine.dart';
import '../bridge/viewer.dart';
import '../data/api.dart';
import '../router.dart';
import '../widgets/point_editor.dart';
import '../widgets/ui.dart';
import 'design.dart';

const _viewJa = {'top': '上から', 'thumb_side': '親指側', 'pinky_side': '小指側'};
const _fingerJa = {
  'index': '人差し指',
  'middle': '中指',
  'ring': '薬指',
  'pinky': '小指',
};

/// S5 採寸結果の確認と点の修正（docs/screens.md S5、measurement.md §13）。
/// 採寸は解析の直後に保存してある（PUT measurement）。点を直したら同じAPIで送り直し、大きさだけが変わる
class MeasureConfirmScreen extends StatefulWidget {
  const MeasureConfirmScreen({
    super.key,
    required this.caseId,
    required this.measurement,
    required this.saved,
    this.repFrames = const [],
    this.stats,
  });
  final String caseId;
  final Map<String, dynamic> measurement;
  final Map<String, dynamic> saved; // PUT measurement の応答
  final List<Map<String, dynamic>> repFrames;
  final Map<String, dynamic>? stats;
  @override
  State<MeasureConfirmScreen> createState() => _MeasureConfirmScreenState();
}

class _MeasureConfirmScreenState extends State<MeasureConfirmScreen> {
  late Map<String, dynamic> _m = widget.measurement;
  late Map<String, dynamic> _saved = widget.saved;
  bool _editing = false;
  bool _busy = false;
  String? _busyText;
  String? _error;
  // 直している点（フレームのpx）。フレームの番号 → 点の番号 → 位置
  late final Map<int, Map<String, Offset>> _pts = {
    for (final f in widget.repFrames)
      f['frame_index'] as int: {
        for (final e in Map<String, dynamic>.from(f['points']).entries)
          e.key: Offset(
            (e.value[0] as num).toDouble(),
            (e.value[1] as num).toDouble(),
          ),
      },
  };
  final Map<int, Set<int>> _moved = {};
  int _frameIdx = 0; // 点を直す画面で出している写真の番号

  Map<String, dynamic> get _hm =>
      Map<String, dynamic>.from(_saved['hand_model'] ?? {});

  double? _baseline(String part, String name) {
    for (final b in (_saved['baseline'] as List? ?? [])) {
      if (b['part_id'] == part && b['name'] == name) {
        return (b['value'] as num?)?.toDouble();
      }
    }
    return null;
  }

  Future<void> _recompute({required bool reset}) async {
    setState(() {
      _busy = true;
      _error = null;
      _busyText = '直した点で大きさを計算し直しています';
    });
    try {
      final frames = reset
          ? <Map<String, dynamic>>[]
          : [
              for (final f in widget.repFrames)
                if ((_moved[f['frame_index']] ?? {}).isNotEmpty)
                  {
                    'frame_index': f['frame_index'],
                    'view': f['view'],
                    'points': {
                      for (final e in _pts[f['frame_index']]!.entries)
                        e.key: [e.value.dx, e.value.dy],
                    },
                    'moved': _moved[f['frame_index']]!.toList(),
                  },
            ];
      final r = await MeasureEngine.instance.applyManualPoints(frames);
      final m = Map<String, dynamic>.from(r['measurement']);
      final saved = await Api.instance.put(
        '/v1/cases/${widget.caseId}/measurement',
        m,
      );
      setState(() {
        _m = m;
        _saved = Map<String, dynamic>.from(saved);
        _editing = false;
        if (reset) {
          _moved.clear();
          for (final f in widget.repFrames) {
            _pts[f['frame_index'] as int] = {
              for (final e in Map<String, dynamic>.from(f['points']).entries)
                e.key: Offset(
                  (e.value[0] as num).toDouble(),
                  (e.value[1] as num).toDouble(),
                ),
            };
          }
        }
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  void _toDesign() {
    unawaited(MeasureEngine.instance.reset()); // 動画とフレームを捨てる
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        settings: RouteSettings(name: AppRouter.design(widget.caseId, null)),
        builder: (_) => DesignScreen(
          caseId: widget.caseId,
          designId: null,
          autoStart: true,
        ),
      ),
      (r) => r.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) => _editing ? _editPage() : _viewPage();

  Widget _viewPage() {
    final warnings = {
      ...List<String>.from(_saved['warnings'] ?? []),
      ...List<String>.from(_m['quality']?['warnings'] ?? []),
    };
    final lm = Map<String, dynamic>.from(_hm['cover_landmarks'] ?? {});
    final palm = Map<String, dynamic>.from(_m['palm'] ?? {});
    final fingers = Map<String, dynamic>.from(_m['fingers'] ?? {});
    const gap = SizedBox(height: 16);
    return AppPage(
      title: '手の形を確かめる',
      // Figma S5：下には主な操作（保存して形を作る）だけを置く
      bottom: FilledButton.icon(
        onPressed: _busy ? null : _toDesign,
        icon: const Icon(Icons.auto_awesome_rounded),
        label: const Text('合っている（保存して形を作る）'),
      ),
      children: [
        Semantics(
          header: true,
          child: Text('手の形は合っていますか？', style: AppText.headlineSmall),
        ),
        gap,
        if (_busyText != null) BusyCard(text: _busyText!),
        if (_error != null) ErrorCard(message: _error!),
        if (_hm['mesh_path'] == null)
          const InfoCard(
            tone: NoticeTone.error,
            child: Text('手の3Dを読み込めませんでした。'),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: ColoredBox(
              color: AppColors.surfaceContainerHigh,
              child: SizedBox(
                height: 300,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Viewer3D(
                        handPath: _hm['mesh_path'],
                        handSide: _m['hand_side'] as String?,
                        landmarks: {
                          // palm_cut_base_mm は正準形（手のひら側が +z）の高さ。表示している手は実際の座標で、
                          // 右手は手のひら側が −z なので、手のひらの向き（palm_normal の z）を掛ける（11/8 のレビュー）
                          if (lm['palm_cut_base_mm'] is num)
                            'palm_cut_z': (lm['palm_cut_base_mm'] as num) *
                                (((lm['palm_normal'] as List?)?[2] as num?) ??
                                    (_m['hand_side'] == 'left' ? 1 : -1)),
                          if (_baseline('cover', 'wrist_cut_mm') != null)
                            'wrist_cut_y': _baseline('cover', 'wrist_cut_mm'),
                        },
                      ),
                    ),
                    // 回せることの手がかり（読み上げは Viewer3D の説明で伝える）
                    const Positioned(left: 12, top: 12, child: _RotateHint()),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '測った手を、1円玉で実寸にした3Dの形で表しました。薄い板より手の甲側をカバーで覆います。手のひら側と手首は開けておきます。',
          style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
        if (widget.repFrames.isNotEmpty) ...[
          gap,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < widget.repFrames.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _FrameThumb(frame: widget.repFrames[i])),
              ],
            ],
          ),
        ],
        gap,
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                style: _smallButton,
                onPressed: _busy || widget.repFrames.isEmpty
                    ? null
                    : () => setState(() {
                        _editing = true;
                        _frameIdx = 0;
                      }),
                icon: const Icon(Icons.open_with_rounded),
                label: const Text('点を直す'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                style: _smallButton,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('撮り直す'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 警告が変わったら作り直す（点を直したあと、新しいお知らせが読み上げに出ないことがあったため）
        KeyedSubtree(
          key: ValueKey((warnings.toList()..sort()).join(',')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (warnings.contains('MESH_SCALE_INCONSISTENT'))
                const InfoCard(
                  tone: NoticeTone.warning,
                  child: Text('手の甲の点がずれているかもしれません。「点を直す」で確かめてください。'),
                ),
              if (warnings.contains('POINTS_MANUAL'))
                const InfoCard(
                  tone: NoticeTone.info,
                  icon: Icons.edit_rounded,
                  child: Text('点を手で直しました。'),
                ),
              if (warnings.contains('ANGLE_DISAGREE'))
                const InfoCard(
                  tone: NoticeTone.info,
                  child: Text(
                    '手の3Dの曲がり角と、画像からの見積もりが15度以上違う関節があります。作業療法士に確かめてもらいます。',
                  ),
                ),
              if (warnings.contains('FEW_FRAMES') ||
                  warnings.contains('VIEW_BIASED'))
                const InfoCard(
                  tone: NoticeTone.info,
                  child: Text('使えたフレームが少ないか、見えた向きが片寄っています。ずれていたら撮り直してください。'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _DetailsCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '手の甲の長さは、大きさを合わせるのに使った値です。',
                style: AppText.supporting,
              ),
            ),
            _DetailRow(
              label: '手首から人差し指の付け根',
              value: '${palm['wrist_to_index_mcp_mm']} mm',
            ),
            _DetailRow(
              label: '手首から中指の付け根',
              value: '${palm['wrist_to_middle_mcp_mm']} mm',
            ),
            _DetailRow(
              label: '手首から小指の付け根',
              value: '${palm['wrist_to_pinky_mcp_mm']} mm',
            ),
            _DetailRow(
              label: '人差し指〜小指の付け根',
              value: '${palm['hand_width_mcp_mm']} mm',
            ),
            _DetailRow(
              label: '手の甲の点',
              value: palm['segments_source'] == 'manual' ? '直した点' : '自動の点',
            ),
            _DetailRow(
              label: '大きさを合わせた倍率',
              value: _hm['scale_factor'] == null
                  ? '—'
                  : '${_hm['scale_factor']} 倍',
              sub: 'ばらつき ${_hm['scale_spread_ratio'] ?? '—'}',
              status: warnings.contains('MESH_SCALE_INCONSISTENT')
                  ? const StatusLabel(label: 'ばらつきあり', tone: StatusTone.warning)
                  : null,
            ),
            _DetailRow(
              label: '縮尺',
              value: '${_m['scale']?['px_per_mm_median']} px/mm',
            ),
            _DetailRow(
              label: '警告',
              value: warnings.isEmpty ? 'なし' : '${warnings.length}件',
              sub: warnings.isEmpty ? null : warnings.join('、'),
            ),
            if (widget.stats != null)
              _DetailRow(
                label: 'フレーム（候補 → 残した → 使えた）',
                value:
                    '${widget.stats!['candidates']} → ${widget.stats!['kept']} → ${widget.stats!['used']}',
                sub: '使わなかった理由：${widget.stats!['rejected']}',
              ),
            for (final f in _fingerJa.keys)
              if (fingers[f] != null)
                _DetailRow(
                  label: '${_fingerJa[f]}の曲がり（手の3D）',
                  value:
                      '${fingers[f]['flexion_deg']['mcp']}°・${fingers[f]['flexion_deg']['pip']}°・${fingers[f]['flexion_deg']['dip']}°',
                  sub:
                      '長さ ${(fingers[f]['lengths_mm'] as List).join('・')} mm（確認用）',
                ),
          ],
        ),
      ],
    );
  }

  /// Figma の Button – tonal（Small）。押せる範囲は48px（docs/screens.md §2）
  static final _smallButton = FilledButton.styleFrom(
    minimumSize: const Size(48, 48),
    padding: const EdgeInsets.symmetric(horizontal: 16),
  );

  Widget _editPage() {
    final frames = widget.repFrames;
    final idx = _frameIdx.clamp(0, frames.length - 1);
    final f = frames[idx];
    final fi = f['frame_index'] as int;
    return AppPage(
      title: '点を直す',
      onBack: _busy ? null : () => setState(() => _editing = false),
      bottom: FilledButton.icon(
        onPressed: _busy || _moved.values.every((s) => s.isEmpty)
            ? null
            : () => _recompute(reset: false),
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('この点で計算し直す'),
      ),
      children: [
        // 写真を1枚ずつ大きく出す（Figma S5 点を直す：フィルターチップで切り替え）
        if (frames.length > 1)
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < frames.length; i++)
                FilterChip(
                  label: Text(
                    '${_viewJa[frames[i]['view']] ?? '${frames[i]['view']}'}'
                    '${i == idx ? '（${i + 1}/${frames.length}）' : ''}',
                  ),
                  selected: i == idx,
                  showCheckmark: true,
                  selectedColor: AppColors.secondaryContainer,
                  checkmarkColor: AppColors.onSecondaryContainer,
                  labelStyle: AppText.labelLarge.copyWith(
                    color: i == idx
                        ? AppColors.onSecondaryContainer
                        : AppColors.onSurfaceVariant,
                  ),
                  side: i == idx
                      ? BorderSide.none
                      : const BorderSide(color: AppColors.outlineVariant),
                  onSelected: _busy
                      ? null
                      : (_) => setState(() => _frameIdx = i),
                ),
            ],
          )
        else
          Text(
            _viewJa[f['view']] ?? '${f['view']}',
            style: AppText.titleMedium.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            '手首と指の付け根の5つの点だけを、正しい位置までドラッグします。',
            style: AppText.titleLarge,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '直さなくてよい写真はそのままにします。指の点は直しません（カバーの大きさに効くのはこの5点だけです）。',
          style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (_busyText != null) BusyCard(text: _busyText!),
        if (_error != null) ErrorCard(message: _error!),
        PointEditor(
          key: ValueKey(fi),
          imageDataUrl: f['raw'] ?? f['image'],
          width: (f['width'] as num).toDouble(),
          height: (f['height'] as num).toDouble(),
          points: _pts[fi]!,
          onChanged: (k, p) => setState(() {
            _pts[fi]![k] = p;
            (_moved[fi] ??= {}).add(int.parse(k));
          }),
        ),
        const SizedBox(height: 12),
        const HelperNote(),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceAround,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _busy ? null : () => _recompute(reset: true),
              icon: const Icon(Icons.undo_rounded),
              label: const Text('元に戻す（自動の点）'),
            ),
            if (idx < frames.length - 1)
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => setState(() => _frameIdx = idx + 1),
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('この写真はとばす'),
              ),
          ],
        ),
      ],
    );
  }
}

/// 3Dの表示の左上の札（Figma の Box＋3d_rotation）
class _RotateHint extends StatelessWidget {
  const _RotateHint();
  @override
  Widget build(BuildContext context) => IgnorePointer(
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
              Icons.threed_rotation_rounded,
              size: 18,
              color: AppColors.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'ドラッグで回せます',
              style: AppText.labelLarge.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 写真の後ろの暗い色（Figma の写真の枠と同じ）
const _photoBackdrop = Color(0xFF2C3134);

/// 代表フレーム1枚（Figma の Representative frames）。暗い枠に写真、下に向きの名前
class _FrameThumb extends StatelessWidget {
  const _FrameThumb({required this.frame});
  final Map<String, dynamic> frame;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 90,
          width: double.infinity,
          color: _photoBackdrop,
          child: Image.memory(
            dataUrlBytes(frame['image']),
            fit: BoxFit.contain,
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _viewJa[frame['view']] ?? '${frame['view']}',
        style: AppText.labelLarge.copyWith(color: AppColors.onSurfaceVariant),
      ),
    ],
  );
}

/// 「詳しく見る」（Figma の 詳しく見る (expanded)）。角丸16のカードを開くと、値が区切り線で並ぶ
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    return ExpansionTile(
      leading: const Icon(Icons.visibility_rounded),
      title: Text('詳しく見る', style: AppText.titleMedium),
      backgroundColor: AppColors.surfaceContainerLow,
      collapsedBackgroundColor: AppColors.surfaceContainerLow,
      iconColor: AppColors.onSurfaceVariant,
      collapsedIconColor: AppColors.onSurfaceVariant,
      textColor: AppColors.onSurface,
      collapsedTextColor: AppColors.onSurface,
      shape: shape,
      collapsedShape: shape,
      clipBehavior: Clip.antiAlias,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// 値の一覧の1行。左に名前（Body Large）、右に値（Title Medium）。上に区切り線
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.sub,
    this.status,
  });
  final String label;
  final String value;
  final String? sub;
  final Widget? status;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppText.bodyLarge),
                  if (sub != null) Text(sub!, style: AppText.supporting),
                  if (status != null) ...[const SizedBox(height: 4), status!],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(value, style: AppText.titleMedium, textAlign: TextAlign.end),
          ],
        ),
      ),
    ],
  );
}
