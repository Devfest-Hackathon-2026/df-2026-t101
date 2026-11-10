import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:jijogu_app/app/router.dart';
import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/models/attachments.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/print/download.dart';

/// 部品ごとの材料（Figma の札）
const _partMaterial = {'cover': 'PLA', 'c_clip': 'PETG', 'tpu_sleeve': 'TPU'};

/// 部品ごとの小さな絵（Figma から書き出した静的な絵）
const _partImage = {
  'cover': 'assets/images/part_cover.svg',
  'c_clip': 'assets/images/part_c_clip.svg',
};

/// 部品ごとの刷り方（parts-library.md §7）
const _partHowTo = {
  'cover': 'カバー：手のひら側の切り口を下にして刷ります。内側にサポートが要ります（跡はフェルトで隠れます）。',
  'c_clip': 'C字クリップ：輪が机と平行になる向きで刷ります（縦に刷ると層の境目から割れやすい）。材料はPETGが使えればPETGがおすすめです。',
  'tpu_sleeve': 'TPUの筒：TPUで刷ります。',
};

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
    final rows = d == null ? <PrintRow>[] : printRows(d, _case?['requirements'] as Map<String, dynamic>?);
    final multi = d != null && showSwapGuide(d);
    final colorHex = '${d?['style']?['color'] ?? ''}';
    final comment = '${d?['approval']?['comment_ja'] ?? ''}'.trim();
    final canAdd = d != null &&
        canAddFromPrint(d, (_case?['requirements'] as Map?)?.cast<String, dynamic>(), ready: ready);
    return AppPage(
      title: '印刷と使い方',
      bottom: ready
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // カバーを刷ったあとで、別の道具のクリップを足す（ADR-0014 §4）
                if (canAdd) ...[
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRouter.design(widget.caseId, widget.designId)),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('取り付け具を足す（形の画面へ）'),
                  ),
                  const SizedBox(height: 8),
                ],
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false),
                  child: const Text('ホームへ戻る'),
                ),
              ],
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
            icon: Icons.lock_outline_rounded,
            child: Text('OTの確認が済むとダウンロードできます。'),
          ),
        // 取り付け具を足した・太さを直した版（ADR-0014 §4）
        if (d != null && coverKept(d))
          const InfoCard(
            tone: NoticeTone.success,
            icon: Icons.check_circle_outline_rounded,
            child: Text('カバーは前の版と同じです。刷ってあるカバーをそのまま使えます'),
          ),
        if (approved) ...[
          const SizedBox(height: 4),
          _ApprovedCard(
            reviewer: '${d?['approval']?['reviewer_email'] ?? ''}',
            decidedAt: '${d?['approval']?['decided_at'] ?? ''}',
            comment: comment,
          ),
        ],
        if (ready) ...[
          const _Heading(icon: Icons.download_rounded, text: '部品ごとのダウンロード'),
          for (final r in rows)
            _PartCard(
              partId: r.partId,
              name: r.name,
              fileName: r.path.split('/').last,
              howTo: _partHowTo[r.partId],
              onDownload: () => _dl(r.key, r.path),
              downloadLabel: '${multi ? r.name : (printPartJa[r.partId] ?? r.key)}をダウンロード',
            ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: () async {
              for (final r in rows) {
                await _dl(r.key, r.path);
              }
            },
            icon: const Icon(Icons.download_rounded),
            label: const Text('まとめてダウンロード'),
          ),
          const SizedBox(height: 6),
        ],
        if (d != null) ...[
          // 確認前（ダウンロードできないとき）も刷り方は読めるようにする
          if (!ready) ...[
            const _Heading(icon: Icons.print_rounded, text: '刷り方'),
            _Panel(
              child: _Lines([
                _partHowTo['cover']!,
                _partHowTo['c_clip']!,
                if (print.containsKey('tpu_sleeve')) _partHowTo['tpu_sleeve']!,
              ]),
            ),
          ],
          if (colorHex.isNotEmpty) _ColorRow(hex: colorHex),
          const _Heading(icon: Icons.check_circle_outline_rounded, text: '用意するもの'),
          _Panel(
            child: _Lines(
              ['内側に貼るフェルトかスポンジ（厚さ約1mm）', '面ファスナーのベルト（幅25mm）を$strapCount本'],
              icon: Icons.check_circle_outline_rounded,
            ),
          ),
          const _Heading(icon: Icons.edit_rounded, text: '組み立て方'),
          if (multi)
            const _Panel(
              child: _Lines(['クリップは差し替えて使います。使う道具のクリップをレールに差し込みます']),
            ),
          const _Panel(
            child: _Steps([
              'カバーの内側にフェルトを貼ります。',
              '両側のスリットにベルトを通します。',
              'クリップをレールに横から滑り込ませ、「カチッ」と止まるまで押します。',
              '道具をクリップに押し込みます。',
              '軽く引いて、抜けないか確かめます。',
            ]),
          ),
          const _Heading(icon: Icons.back_hand_rounded, text: '着け方'),
          const _Panel(
            child: _Lines([
              '握った指を無理に開かせず、手の甲側からかぶせます。',
              '手のひら側でベルトを留めます（家族や支援者が片手でできます）。',
            ]),
          ),
          const _Heading(icon: Icons.warning_amber_rounded, text: '注意'),
          const _Panel(
            color: AppColors.errorContainer,
            child: _Lines(
              [
                '痛みや赤みが出たら、すぐに使うのをやめて作業療法士に相談してください。',
                '最初は短い時間から使ってください。',
                'カバーとクリップは口に入れないでください。',
                'PLAは熱に弱いので、熱いお湯につけないでください。',
                '道具の太さが聞き取りと違うと挟めません。刷る前に確かめてください。',
              ],
              icon: Icons.error_outline_rounded,
              iconColor: AppColors.error,
              textColor: AppColors.onErrorContainer,
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
}

/// 小見出し（アイコン20＋Title Medium）。Figma の各ブロックの見出し
class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 6),
    child: Semantics(
      header: true,
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppText.titleMedium)),
        ],
      ),
    ),
  );
}

/// 角丸16の枠（surfaceContainerLow）
class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.color = AppColors.surfaceContainerLow,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

/// 文の並び。[icon] があれば各行の頭に付ける
class _Lines extends StatelessWidget {
  const _Lines(
    this.lines, {
    this.icon,
    this.iconColor = AppColors.primary,
    this.textColor = AppColors.onSurface,
  });
  final List<String> lines;
  final IconData? icon;
  final Color iconColor;
  final Color textColor;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < lines.length; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 22, color: iconColor),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                lines[i],
                style: AppText.bodyLarge.copyWith(color: textColor),
              ),
            ),
          ],
        ),
      ],
    ],
  );
}

/// 番号付きの手順（番号は primaryContainer の丸）
class _Steps extends StatelessWidget {
  const _Steps(this.steps);
  final List<String> steps;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < steps.length; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${i + 1}',
                  semanticsLabel: '${i + 1}.',
                  style: AppText.labelLarge.copyWith(
                    color: AppColors.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(steps[i], style: AppText.bodyLarge)),
            ],
          ),
        ),
      ],
    ],
  );
}

/// 確認済みの札（successContainer）。確認したOT・日時・コメント
class _ApprovedCard extends StatelessWidget {
  const _ApprovedCard({
    required this.reviewer,
    required this.decidedAt,
    required this.comment,
  });
  final String reviewer;
  final String decidedAt;
  final String comment;

  @override
  Widget build(BuildContext context) {
    const fg = AppColors.onSuccessContainer;
    return _Panel(
      color: AppColors.successContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_rounded, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'OTの確認が済みました',
                  style: AppText.titleMedium.copyWith(color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '確認したOT：$reviewer（$decidedAt）',
            style: AppText.bodyLarge.copyWith(color: fg),
          ),
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(
                      Icons.chat_rounded,
                      size: 20,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(comment, style: AppText.bodyLarge)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 部品1つ分のダウンロードの行（絵・名前・材料の札・刷り方・ダウンロードボタン）
class _PartCard extends StatelessWidget {
  const _PartCard({
    required this.partId,
    required this.name,
    required this.fileName,
    required this.howTo,
    required this.onDownload,
    required this.downloadLabel,
  });
  final String partId;
  final String name;
  final String fileName;
  final String? howTo;
  final VoidCallback onDownload;
  final String downloadLabel;

  @override
  Widget build(BuildContext context) {
    final img = _partImage[partId];
    final material = _partMaterial[partId];
    return _Panel(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: [
          ExcludeSemantics(
            child: img != null
                ? SvgPicture.asset(img, width: 56, height: 56)
                : Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.view_in_ar_rounded,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppText.titleMedium),
                if (material != null) ...[
                  const SizedBox(height: 4),
                  StatusLabel(label: material),
                ],
                const SizedBox(height: 4),
                if (howTo != null) Text(howTo!, style: AppText.supporting),
                Text(fileName, style: AppText.supporting),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: onDownload,
            tooltip: downloadLabel,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
    );
  }
}

/// 刷る色の行（色の丸＋色の値）
class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.hex});
  final String hex;

  static Color? _parse(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16);
    return h.length == 8 && v != null ? Color(v) : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = _parse(hex);
    return _Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: MergeSemantics(
        child: Row(
          children: [
            if (c != null) ...[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.outlineVariant),
                ),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '刷る色',
                    style: AppText.bodySmall.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  Text(hex, style: AppText.bodyLarge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
