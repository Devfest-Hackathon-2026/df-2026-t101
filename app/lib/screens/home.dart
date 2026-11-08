import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/api.dart';
import '../data/files.dart';
import '../data/session.dart';
import '../paths.dart';
import '../router.dart';
import '../widgets/ui.dart';

const caseStatusJa = {
  'interviewing': '聞き取り中',
  'measuring': '撮影を待っています',
  'designing': '形を作る前',
  'previewing': '形を確かめています',
  'in_review': '確認待ち',
  'approved': '確認済み',
};

/// 状態の札の色とアイコン（Figma の M3/Status label。色だけで伝えないので、アイコンも変える）
(StatusTone, IconData) _statusLook(String? status) => switch (status) {
  'interviewing' => (StatusTone.neutral, Icons.chat_outlined),
  'measuring' => (StatusTone.neutral, Icons.photo_camera_outlined),
  'designing' => (StatusTone.neutral, Icons.view_in_ar_rounded),
  'previewing' => (StatusTone.neutral, Icons.visibility_outlined),
  'in_review' => (StatusTone.warning, Icons.hourglass_top_rounded),
  'approved' => (StatusTone.success, Icons.check_circle_outline_rounded),
  _ => (StatusTone.neutral, Icons.info_outline_rounded),
};

/// S1 ホーム（ケース一覧）。Figma「S1 ホーム（ケース一覧）」「S1 ホーム（空の状態）」
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>>? _cases;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Api.instance.get('/v1/cases');
      final list = (r is Map ? r['cases'] : r) as List? ?? [];
      setState(
        () => _cases = [for (final c in list) Map<String, dynamic>.from(c)],
      );
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final r = await Api.instance.post('/v1/cases', {'title': '筆のカバー'});
      if (!mounted) return;
      await Navigator.of(context).pushNamed(AppRouter.interview(r['case_id']));
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ケースを消す（確かめてから。手の3Dの形・版・印刷用のデータもまとめて消える。元に戻せない）
  Future<void> _delete(Map<String, dynamic> c) async {
    final title = '${c['title'] ?? '道具'}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
        title: const Text('この道具を消しますか？'),
        content: Text(
          '「$title」を消します。手の3Dの形、作った形、印刷用のデータもすべて消えます。消したあとは元に戻せません。'
          '${c['status'] == 'in_review' ? '\n\nOTに確認を頼んでいる途中です。消すと、OTも見られなくなります。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              minimumSize: const Size(64, 48),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('消す'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.instance.delete('/v1/cases/${c['case_id']}');
      if (!mounted) return;
      setState(() => _cases?.removeWhere((x) => x['case_id'] == c['case_id']));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('「$title」を消しました')));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final empty = _error == null && _cases != null && _cases!.isEmpty;
    return AppPage(
      title: 'わたしの道具',
      large: true,
      actions: [
        _AccountMenu(name: Session.instance.displayName),
        const SizedBox(width: 4),
      ],
      floatingActionButton: empty
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add_rounded, size: 24),
              label: const Text('新しく作る'),
            ),
      children: [
        if (_error != null)
          ErrorCard(message: '読み込めませんでした（$_error）', onRetry: _load)
        else if (_cases == null) ...[
          const SectionLabel('作りかけ・作った道具'),
          for (var i = 0; i < 3; i++) const _CardSkeleton(),
        ] else if (empty)
          _EmptyState(onCreate: _busy ? null : _create)
        else ...[
          const SectionLabel('作りかけ・作った道具'),
          for (final c in _cases!)
            _CaseCard(
              key: ValueKey(c['case_id']),
              data: c,
              onTap: () async {
                await Navigator.of(context).pushNamed(continueRoute(c));
                _load();
              },
              onDelete: () => _delete(c),
            ),
          const SizedBox(height: 8),
          const InfoCard(
            tone: NoticeTone.info,
            child: Text('PCで大きく見たいときは、同じGoogleアカウントでログインしてください。'),
          ),
        ],
      ],
    );
  }
}

/// 右上のアカウントのボタン（名前とログアウト）
class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.name});
  final String name;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'アカウント',
    icon: const Icon(Icons.account_circle_outlined),
    onSelected: (v) {
      if (v == 'logout') Session.instance.signOut();
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        enabled: false,
        child: Text('$name さん', style: AppText.titleSmall),
      ),
      const PopupMenuItem(
        value: 'logout',
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.logout_rounded),
          title: Text('ログアウト'),
        ),
      ),
    ],
  );
}

/// 空の状態（大きな手のアイコン＋「新しく作る」）
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});
  final VoidCallback? onCreate;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            color: AppColors.secondaryContainer,
            borderRadius: BorderRadius.circular(64),
          ),
          child: const Icon(
            Icons.back_hand_outlined,
            size: 80,
            color: AppColors.onSecondaryContainer,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'まだ道具がありません',
          textAlign: TextAlign.center,
          style: AppText.headlineSmall,
        ),
        const SizedBox(height: 16),
        Text(
          'やりたいことを教えてください。質問に答えて手を撮ると、形ができます。',
          textAlign: TextAlign.center,
          style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add_rounded),
          label: const Text('新しく作る'),
        ),
      ],
    ),
  );
}

/// 読み込み中：カードの形の灰色の枠
class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();
  @override
  Widget build(BuildContext context) => Container(
    height: 96,
    margin: const EdgeInsets.symmetric(vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
    ),
  );
}

/// ケースのカード（Figma の M3/Case card）。左に最新の版の画像（views/iso.png）、なければ状態のアイコン
class _CaseCard extends StatefulWidget {
  const _CaseCard({
    super.key,
    required this.data,
    required this.onTap,
    required this.onDelete,
  });
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  @override
  State<_CaseCard> createState() => _CaseCardState();
}

class _CaseCardState extends State<_CaseCard> {
  Uint8List? _thumb;
  bool _rejected = false;

  @override
  void initState() {
    super.initState();
    _loadDesign();
  }

  /// 最新の版を読み、画像と「差し戻し」かどうかを取る。失敗してもカードはそのまま出す
  Future<void> _loadDesign() async {
    final c = widget.data;
    final d = c['current_design_id'] as String?;
    if (d == null) return;
    try {
      final r = await Api.instance.get('/v1/cases/${c['case_id']}/designs/$d');
      final design = Map<String, dynamic>.from(
        (r is Map && r['design'] != null) ? r['design'] : r,
      );
      final rejected = (design['approval'] as Map?)?['status'] == 'rejected';
      final iso =
          ((design['files'] as Map?)?['views'] as Map?)?['iso'] as String?;
      if (mounted && rejected) setState(() => _rejected = true);
      if (iso == null) return;
      final ref = await Files.resolve(iso);
      final res = await http.get(Uri.parse(ref.url), headers: ref.headers);
      if (res.statusCode >= 400 || res.bodyBytes.isEmpty) return;
      if (mounted) setState(() => _thumb = res.bodyBytes);
    } catch (_) {
      // 画像がなくても一覧は使える
    }
  }

  String _updated(Object? v) {
    final t = DateTime.tryParse('${v ?? ''}')?.toLocal();
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '更新 ${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.data;
    final status = c['status'] as String?;
    var (tone, icon) = _statusLook(status);
    var label = caseStatusJa[status] ?? '$status';
    if (_rejected && status != 'approved') {
      (tone, icon) = (StatusTone.error, Icons.error_outline_rounded);
      label = '差し戻し';
    }
    final title = '${c['title'] ?? '道具'}';
    final updated = _updated(c['updated_at']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // カードの本体を押すと続きの画面へ。右のメニューのボタンは別に押せる（読み上げでも別の項目）
            Expanded(
              child: Semantics(
                button: true,
                label: '$title、$label、$updated',
                excludeSemantics: true,
                child: InkWell(
                  onTap: widget.onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                    child: Row(
                      children: [
                        _Thumb(bytes: _thumb, statusIcon: icon),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: AppText.titleMedium),
                              const SizedBox(height: 4),
                              StatusLabel(label: label, tone: tone, icon: icon),
                              if (updated.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  updated,
                                  style: AppText.bodySmall.copyWith(
                                    color: AppColors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: PopupMenuButton<String>(
                tooltip: '「$title」のメニュー',
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: AppColors.onSurfaceVariant,
                ),
                onSelected: (v) {
                  if (v == 'delete') widget.onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.delete_outline_rounded,
                        color: AppColors.error,
                      ),
                      title: Text('消す'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 56×56 の小さな画像。版の画像がなければ、状態のアイコンを出す
class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.statusIcon});
  final Uint8List? bytes;
  final IconData statusIcon;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Container(
      width: 56,
      height: 56,
      color: AppColors.surfaceContainerHighest,
      child: bytes != null
          ? Image.memory(
              bytes!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Icon(statusIcon, color: AppColors.primary),
            )
          : Icon(statusIcon, color: AppColors.primary),
    ),
  );
}
