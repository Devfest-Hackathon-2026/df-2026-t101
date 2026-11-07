import 'package:flutter/material.dart';

import '../bridge/viewer.dart';
import '../data/api.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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

  @override
  Widget build(BuildContext context) {
    final d = _design;
    final parts = Map<String, dynamic>.from(d?['files']?['parts'] ?? {});
    return AppPage(
      title: 'OT確認',
      bottom: d == null
          ? null
          : Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _decide('reject'),
                    child: const Text('差し戻す'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy || _checked.values.any((v) => !v)
                        ? null
                        : () => _decide('approve'),
                    child: const Text('確認済みにする'),
                  ),
                ),
              ],
            ),
      children: [
        if (_error != null) ErrorCard(message: _error!),
        if (_case == null && _error == null) const BusyCard(text: '読み込んでいます'),
        if (_case != null && d == null)
          const InfoCard(child: Text('確認を頼まれている版はありません。')),
        if (d != null) ...[
          SizedBox(
            height: 340,
            child: Viewer3D(
              handPath: d['hand_overlay']?['mesh_path'],
              parts: [
                for (final e in parts.entries)
                  PartFile(e.key, '${e.value['preview_stl']}'),
              ],
              color: '${d['style']?['color'] ?? '#2A9D8F'}',
            ),
          ),
          InfoCard(child: Text('${d['summary_ja'] ?? ''}')),
          const Text(
            '引数（Parameters）',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          for (final p in (d['params'] as List? ?? []))
            ListTile(
              dense: true,
              leading: Icon(
                p['clamped'] == true || p['override_by_user'] == true
                    ? Icons.warning_amber
                    : Icons.tune,
                color: p['clamped'] == true || p['override_by_user'] == true
                    ? AppColors.warn
                    : AppColors.sub,
              ),
              title: Text(
                '${p['part_id']}.${p['name']} = ${p['value']} ${p['unit'] ?? ''}（範囲 ${p['range']}、基準 ${p['baseline']}、${p['source']}）',
              ),
              subtitle: Text('${p['reason_ja'] ?? ''}'),
            ),
          if ((_case!['measurement']?['quality']?['warnings'] as List?)
                  ?.isNotEmpty ==
              true)
            InfoCard(
              color: const Color(0xFFFFF4E0),
              icon: Icons.info_outline,
              child: Text(
                '採寸の警告：${(_case!['measurement']['quality']['warnings'] as List).join('、')}',
              ),
            ),
          const SizedBox(height: 8),
          for (final e in _checks.entries)
            CheckboxListTile(
              value: _checked[e.key],
              title: Text(e.value),
              onChanged: (v) => setState(() => _checked[e.key] = v ?? false),
            ),
          TextField(
            controller: _comment,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'コメント',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }
}
