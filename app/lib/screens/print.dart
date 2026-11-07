import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/download.dart';
import '../widgets/ui.dart';

const _partJa = {'cover': 'カバー', 'c_clip': 'C字クリップ', 'tpu_sleeve': 'TPUの筒'};

/// S10 ダウンロードと印刷ガイド（docs/screens.md S10、parts-library.md §7）
class PrintScreen extends StatefulWidget {
  const PrintScreen({super.key, required this.caseId, required this.designId});
  final String caseId;
  final String designId;
  @override
  State<PrintScreen> createState() => _PrintScreenState();
}

class _PrintScreenState extends State<PrintScreen> {
  Map<String, dynamic>? _case;
  Map<String, dynamic>? _design;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await Api.instance.get('/v1/cases/${widget.caseId}');
      final r = await Api.instance.get(
        '/v1/cases/${widget.caseId}/designs/${widget.designId}',
      );
      setState(() {
        _case = Map<String, dynamic>.from(c);
        _design = Map<String, dynamic>.from(r['design'] ?? r);
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _prepareDemo() async {
    setState(() => _busy = true);
    try {
      await Api.instance.post(
        '/v1/cases/${widget.caseId}/designs/${widget.designId}/prepare-print',
      );
      await _load();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dl(String part, String path) async {
    try {
      await downloadFile(path, path.split('/').last);
    } catch (e) {
      if (mounted) showError(context, 'ダウンロードできませんでした。もう一度試してください。（$e）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _design;
    final demo = _case?['demo'] == true;
    final print = Map<String, dynamic>.from(d?['files']?['print'] ?? {});
    final approved = d?['approval']?['status'] == 'approved';
    final ready = print.isNotEmpty && (approved || demo);
    final strapCount = _strapCount(d);
    return AppPage(
      title: '印刷と使い方',
      bottom: ready
          ? FilledButton.icon(
              onPressed: () async {
                for (final e in print.entries) {
                  await _dl(e.key, '${e.value}');
                }
              },
              icon: const Icon(Icons.download),
              label: const Text('まとめてダウンロード'),
            )
          : (demo
                ? FilledButton(
                    onPressed: _busy ? null : _prepareDemo,
                    child: const Text('印刷用データを作る（デモ）'),
                  )
                : OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('形の画面に戻る'),
                  )),
      children: [
        if (demo) const DemoBanner(),
        if (_error != null) ErrorCard(message: _error!, onRetry: _load),
        if (d == null && _error == null) const BusyCard(text: '読み込んでいます'),
        if (_busy) const BusyCard(text: '印刷用のデータを作っています（20〜60秒）'),
        if (d != null && !ready && !demo)
          const InfoCard(
            icon: Icons.lock_outline,
            child: Text('OTの確認が済むとダウンロードできます。'),
          ),
        if (approved)
          InfoCard(
            icon: Icons.verified_outlined,
            child: Text(
              '確認したOT：${d?['approval']?['reviewer_email'] ?? ''}（${d?['approval']?['decided_at'] ?? ''}）\n${d?['approval']?['comment_ja'] ?? ''}',
            ),
          ),
        if (ready)
          for (final e in print.entries)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.view_in_ar_outlined),
                      title: Text(_partJa[e.key] ?? e.key),
                      subtitle: Text('${e.value}'.split('/').last),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _dl(e.key, '${e.value}'),
                      icon: const Icon(Icons.download),
                      label: Text('${_partJa[e.key] ?? e.key}をダウンロード'),
                    ),
                  ],
                ),
              ),
            ),
        if (d != null) ...[
          _section('刷り方', [
            'カバー：手のひら側の切り口を下にして刷ります。内側にサポートが要ります（跡はフェルトで隠れます）。',
            'C字クリップ：輪が机と平行になる向きで刷ります（縦に刷ると層の境目から割れやすい）。材料はPETGが使えればPETGがおすすめです。',
            if (print.containsKey('tpu_sleeve')) 'TPUの筒：TPUで刷ります。',
            '刷る色：${d['style']?['color'] ?? ''}',
          ]),
          _section('用意するもの', [
            '内側に貼るフェルトかスポンジ（厚さ約1mm）',
            '面ファスナーのベルト（幅25mm）を$strapCount本',
          ]),
          _section('組み立て方', [
            '1. カバーの内側にフェルトを貼ります。',
            '2. 両側のスリットにベルトを通します。',
            '3. クリップをレールに横から滑り込ませ、「カチッ」と止まるまで押します。',
            '4. 道具をクリップに押し込みます。',
            '5. 軽く引いて、抜けないか確かめます。',
          ]),
          _section('着け方', [
            '握った指を無理に開かせず、手の甲側からかぶせます。',
            '手のひら側でベルトを留めます（家族や支援者が片手でできます）。',
          ]),
          const InfoCard(
            color: Color(0xFFFDECEA),
            icon: Icons.health_and_safety_outlined,
            child: Text(
              '痛みや赤みが出たら、すぐに使うのをやめて作業療法士に相談してください。\n'
              '最初は短い時間から使ってください。口に入れないでください。PLAは熱に弱いので、熱いお湯につけないでください。\n'
              '道具の太さが聞き取りと違うと挟めません。刷る前に確かめてください。',
            ),
          ),
        ],
      ],
    );
  }

  int _strapCount(Map<String, dynamic>? d) {
    for (final p in (d?['params'] as List? ?? [])) {
      if (p['part_id'] == 'strap_slits' && p['name'] == 'strap_count') {
        return (p['value'] as num).toInt();
      }
    }
    return 1;
  }

  Widget _section(String title, List<String> lines) => InfoCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(l),
          ),
      ],
    ),
  );
}
