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
    return AppPage(
      title: '手の形を確かめる',
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: _busy ? null : _toDesign,
            child: const Text('合っている（保存して形を作る）'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy || widget.repFrames.isEmpty
                      ? null
                      : () => setState(() => _editing = true),
                  child: const Text('点を直す'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('撮り直す'),
                ),
              ),
            ],
          ),
        ],
      ),
      children: [
        const Text(
          '測った手を、1円玉で実寸にした3Dの形で表しました。薄い板より手の甲側をカバーで覆います。手のひら側と手首は開けておきます。',
        ),
        const SizedBox(height: 8),
        if (_busyText != null) BusyCard(text: _busyText!),
        if (_error != null) ErrorCard(message: _error!),
        SizedBox(
          height: 340,
          child: _hm['mesh_path'] == null
              ? const InfoCard(child: Text('手の3Dを読み込めませんでした。'))
              : Viewer3D(
                  handPath: _hm['mesh_path'],
                  landmarks: {
                    if (lm['palm_cut_base_mm'] != null)
                      'palm_cut_z': lm['palm_cut_base_mm'],
                    if (_baseline('cover', 'wrist_cut_mm') != null)
                      'wrist_cut_y': _baseline('cover', 'wrist_cut_mm'),
                  },
                ),
        ),
        if (widget.repFrames.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in widget.repFrames)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(
                              dataUrlBytes(f['image']),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        Text(
                          _viewJa[f['view']] ?? '${f['view']}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.sub,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (warnings.contains('MESH_SCALE_INCONSISTENT'))
          const InfoCard(
            color: Color(0xFFFFF4E0),
            icon: Icons.info_outline,
            child: Text('手の甲の点がずれているかもしれません。「点を直す」で確かめてください。'),
          ),
        if (warnings.contains('POINTS_MANUAL'))
          const InfoCard(icon: Icons.edit_outlined, child: Text('点を手で直しました。')),
        if (warnings.contains('ANGLE_DISAGREE'))
          const InfoCard(
            icon: Icons.info_outline,
            child: Text('手の3Dの曲がり角と、画像からの見積もりが15度以上違う関節があります。作業療法士に確かめてもらいます。'),
          ),
        if (warnings.contains('FEW_FRAMES') || warnings.contains('VIEW_BIASED'))
          const InfoCard(
            icon: Icons.info_outline,
            child: Text('使えたフレームが少ないか、見えた向きが片寄っています。ずれていたら撮り直してください。'),
          ),
        ExpansionTile(
          title: const Text('詳しく見る'),
          children: [
            ListTile(
              dense: true,
              title: const Text('手の甲の長さ（大きさを合わせるのに使った値）'),
              subtitle: Text(
                '手首→人差し指の付け根 ${palm['wrist_to_index_mcp_mm']} mm ／ 手首→中指の付け根 ${palm['wrist_to_middle_mcp_mm']} mm ／ '
                '手首→小指の付け根 ${palm['wrist_to_pinky_mcp_mm']} mm ／ 人差し指〜小指の付け根 ${palm['hand_width_mcp_mm']} mm'
                '（${palm['segments_source'] == 'manual' ? '直した点' : '自動の点'}）',
              ),
            ),
            ListTile(
              dense: true,
              title: Text(
                '大きさを合わせた倍率：${_hm['scale_factor'] ?? '—'}（ばらつき ${_hm['scale_spread_ratio'] ?? '—'}）',
              ),
              subtitle: Text(
                '縮尺：${_m['scale']?['px_per_mm_median']} px/mm ／ 警告：${warnings.isEmpty ? 'なし' : warnings.join('、')}',
              ),
            ),
            if (widget.stats != null)
              ListTile(
                dense: true,
                title: Text(
                  'フレーム：候補 ${widget.stats!['candidates']} → 残した ${widget.stats!['kept']} → 使えた ${widget.stats!['used']}',
                ),
                subtitle: Text('使わなかった理由：${widget.stats!['rejected']}'),
              ),
            for (final f in _fingerJa.keys)
              if (fingers[f] != null)
                ListTile(
                  dense: true,
                  title: Text(_fingerJa[f]!),
                  subtitle: Text(
                    '曲がり（手の3D）${fingers[f]['flexion_deg']['mcp']}°・${fingers[f]['flexion_deg']['pip']}°・${fingers[f]['flexion_deg']['dip']}° ／ '
                    '長さ ${(fingers[f]['lengths_mm'] as List).join('・')} mm（確認用）',
                  ),
                ),
          ],
        ),
      ],
    );
  }

  Widget _editPage() {
    return AppPage(
      title: '点を直す',
      onBack: _busy ? null : () => setState(() => _editing = false),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: _busy || _moved.values.every((s) => s.isEmpty)
                ? null
                : () => _recompute(reset: false),
            child: const Text('この点で計算し直す'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : () => _recompute(reset: true),
            child: const Text('元に戻す（自動の点）'),
          ),
        ],
      ),
      children: [
        const Text(
          '手首と指の付け根の5つの点だけを、正しい位置までドラッグします。直さなくてよい写真はそのままにします。指の点は直しません（カバーの大きさに効くのはこの5点だけです）。',
        ),
        const HelperNote(),
        if (_busyText != null) BusyCard(text: _busyText!),
        if (_error != null) ErrorCard(message: _error!),
        for (final f in widget.repFrames) ...[
          const SizedBox(height: 12),
          Text(
            _viewJa[f['view']] ?? '${f['view']}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          PointEditor(
            imageDataUrl: f['raw'] ?? f['image'],
            width: (f['width'] as num).toDouble(),
            height: (f['height'] as num).toDouble(),
            points: _pts[f['frame_index']]!,
            onChanged: (k, p) => setState(() {
              _pts[f['frame_index']]![k] = p;
              (_moved[f['frame_index'] as int] ??= {}).add(int.parse(k));
            }),
          ),
        ],
      ],
    );
  }
}
