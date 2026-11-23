import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:jijogu_app/app/paths.dart';
import 'package:jijogu_app/app/router.dart';
import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/session.dart';
import 'package:jijogu_app/core/storage/files.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/order/order_logic.dart';
import 'package:jijogu_app/features/order/order_status_card.dart';

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

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  List<Map<String, dynamic>>? _cases;
  String? _error;
  bool _busy = false;

  /// 受託者アカウントなら「受けた注文」の入口を出す（設計 §6.4）
  bool _isFabricator = false;

  /// OTのアカウントなら、自分宛ての確認の依頼（GET /v1/reviews）。OTでなければ null で、欄を出さない
  List<Map<String, dynamic>>? _reviews;

  @override
  void initState() {
    super.initState();
    _load();
    _checkFabricator();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) AppRouter.observer.subscribe(this, route);
  }

  @override
  void dispose() {
    AppRouter.observer.unsubscribe(this);
    super.dispose();
  }

  /// 上の画面が閉じてホームに戻ってきたら、ケースと依頼を読み直す。
  /// 開いた画面の push を待って読み直すのでは足りない：問診は撮影の画面に置き換わって移るので、その時点で
  /// 待ちが終わってしまい、生成の画面から「ホームに戻る」で戻っても読み直さなかった（カードが「撮影を待っています」の
  /// まま残り、押すとカメラが開いた）
  @override
  void didPopNext() => _load();

  Future<void> _loadReviews() async {
    try {
      final r = await Api.instance.get('/v1/reviews');
      final list = (r is Map ? r['reviews'] : r) as List? ?? [];
      if (mounted) {
        setState(() => _reviews = [for (final x in list) Map<String, dynamic>.from(x)]);
      }
    } catch (_) {
      // OTでなければ 403。欄を出さない
    }
  }

  Future<void> _openReview(Map<String, dynamic> r) async {
    await Navigator.of(context).pushNamed(AppRouter.review('${r['case_id']}'));
    // 読み直しは didPopNext
  }

  /// OTのホームの欄：確認待ちを上に、確認済み・差し戻しは畳んでおく
  List<Widget> _reviewSection() {
    final all = _reviews ?? const <Map<String, dynamic>>[];
    if (all.isEmpty) return const [];
    final pending = [for (final r in all) if (r['approval_status'] == 'requested') r];
    final done = [for (final r in all) if (r['approval_status'] != 'requested') r];
    return [
      SectionLabel('確認を頼まれているケース（${pending.length}件）'),
      if (pending.isEmpty)
        const InfoCard(child: Text('いま確認を待っているケースはありません。')),
      for (final r in pending)
        _ReviewCard(key: ValueKey('review-${r['case_id']}'), data: r, onTap: () => _openReview(r)),
      if (done.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('確認済み・差し戻し（${done.length}件）', style: AppText.titleMedium),
            children: [
              for (final r in done)
                _ReviewCard(key: ValueKey('review-${r['case_id']}'), data: r, onTap: () => _openReview(r)),
            ],
          ),
        ),
      const SizedBox(height: 8),
    ];
  }

  Future<void> _checkFabricator() async {
    try {
      await Api.instance.get('/v1/fabricator/me');
      if (mounted) setState(() => _isFabricator = true);
    } catch (_) {
      // 受託者アカウントでなければ 403。入口を出さない
    }
  }

  /// 自分のケースと、OTなら確認の依頼も読み直す（ほかの画面から戻ったときも、依頼の状態が変わっているので）
  Future<void> _load() async {
    _loadReviews();
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final r = await Api.instance.get('/v1/cases');
      final list = (r is Map ? r['cases'] : r) as List? ?? [];
      if (!mounted) return;
      setState(
        () => _cases = [for (final c in list) Map<String, dynamic>.from(c)],
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final r = await Api.instance.post('/v1/cases', {'title': '筆のカバー'});
      if (!mounted) return;
      await Navigator.of(context).pushNamed(AppRouter.interview(r['case_id']));
      // 読み直しは didPopNext（問診は撮影の画面に置き換わるので、ここで待っても戻ってきた時ではない）
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
    final noCases = _error == null && _cases != null && _cases!.isEmpty;
    final hasReviews = _reviews?.isNotEmpty ?? false;
    // 大きな空の状態は、OTの欄がないときだけ（OTのホームは、確認の依頼が主役）
    final empty = noCases && !hasReviews;
    return AppPage(
      title: 'Hand-Some-Fit',
      titleWidget: Image.asset(
        'assets/images/logo.png',
        height: 40,
        semanticLabel: 'Hand-Some-Fit',
        filterQuality: FilterQuality.medium,
      ),
      large: true,
      actions: [
        if (_isFabricator)
          TextButton.icon(
            onPressed: () => Navigator.of(context).pushNamed(Paths.fabricator()),
            icon: const Icon(Icons.storefront_rounded),
            label: const Text('受けた注文'),
          ),
        _AccountMenu(name: Session.instance.displayName),
        const SizedBox(width: 4),
      ],
      // 「新しく作る」は画面の下に幅いっぱいで置く（主なボタンの決まり）。右下の浮いたボタンだと
      // 右手の親指でしか届きにくく、左手や片手で使う人に遠かった（2026-11-22）。
      // 空の状態は、本文のまん中に同じボタンがあるので出さない
      bottom: empty
          ? null
          : FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新しく作る'),
            ),
      children: [
        ..._reviewSection(),
        if (_error != null)
          ErrorCard(message: '読み込めませんでした（$_error）', onRetry: _load)
        else if (_cases == null) ...[
          const SectionLabel('作りかけ・作った道具'),
          for (var i = 0; i < 3; i++) const _CardSkeleton(),
        ] else if (empty)
          _EmptyState(onCreate: _busy ? null : _create)
        else if (noCases) ...[
          const SectionLabel('作りかけ・作った道具'),
          Text(
            'まだありません。',
            style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ] else ...[
          const SectionLabel('作りかけ・作った道具'),
          for (final c in _cases!)
            _CaseCard(
              key: ValueKey(c['case_id']),
              data: c,
              onTap: () => Navigator.of(context).pushNamed(continueRoute(c)),  // 読み直しは didPopNext
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

  int _loadSeq = 0; // 古い読み込みの結果で上書きしないため

  @override
  void initState() {
    super.initState();
    _loadDesign();
  }

  /// ホームが読み直してケースが変わっていたら、版も読み直す。カードは case_id をキーに使い回されるので、
  /// initState だけでは、生成のあとの画像や、もう一度頼んだあとの「差し戻し」の取り消しが反映されなかった
  @override
  void didUpdateWidget(_CaseCard old) {
    super.didUpdateWidget(old);
    const keys = ['current_design_id', 'status', 'updated_at'];
    if (keys.any((k) => '${old.data[k]}' != '${widget.data[k]}')) _loadDesign();
  }

  /// 最新の版を読み、画像と「差し戻し」かどうかを取る。失敗してもカードはそのまま出す
  Future<void> _loadDesign() async {
    final seq = ++_loadSeq;
    final c = widget.data;
    final d = c['current_design_id'] as String?;
    if (d == null) {
      _rejected = false; // initState・didUpdateWidget から同期で来るので、このあと build される
      return;
    }
    try {
      final r = await Api.instance.get('/v1/cases/${c['case_id']}/designs/$d');
      if (!mounted || seq != _loadSeq) return;
      final design = Map<String, dynamic>.from(
        (r is Map && r['design'] != null) ? r['design'] : r,
      );
      final rejected = (design['approval'] as Map?)?['status'] == 'rejected';
      final iso =
          ((design['files'] as Map?)?['views'] as Map?)?['iso'] as String?;
      if (rejected != _rejected) setState(() => _rejected = rejected);
      if (iso == null) return;
      final ref = await Files.resolve(iso);
      final res = await http.get(Uri.parse(ref.url), headers: ref.headers);
      if (res.statusCode >= 400 || res.bodyBytes.isEmpty) return;
      if (mounted && seq == _loadSeq) setState(() => _thumb = res.bodyBytes);
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
    final lo = c['latest_order'] is Map ? Map<String, dynamic>.from(c['latest_order'] as Map) : null;
    final orderLabel = lo == null ? '' : '注文：${orderStatusJa('${lo['status']}')}';
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
                label: '$title、$label${orderLabel.isEmpty ? '' : '、$orderLabel'}、$updated',
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
                              if (lo != null) ...[
                                const SizedBox(height: 4),
                                StatusLabel(
                                  label: orderLabel,
                                  tone: OrderStatusCard.toneOf('${lo['status']}'),
                                  icon: Icons.local_shipping_rounded,
                                ),
                              ],
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

/// OTの確認の状態の札（approval.status）
(String, StatusTone, IconData) _reviewLook(String? s) => switch (s) {
  'requested' => ('確認待ち', StatusTone.warning, Icons.hourglass_top_rounded),
  'approved' => ('確認済み', StatusTone.success, Icons.check_circle_outline_rounded),
  'rejected' => ('差し戻し済み', StatusTone.error, Icons.undo_rounded),
  // 差し戻しのあと、依頼した人が形を直していて、新しい版はまだ頼まれていない
  _ => ('依頼した人が直しています', StatusTone.neutral, Icons.edit_outlined),
};

/// 確認の依頼のカード（OTのホーム）。押すと S9 OT確認へ
class _ReviewCard extends StatefulWidget {
  const _ReviewCard({super.key, required this.data, required this.onTap});
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  @override
  State<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends State<_ReviewCard> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    final iso = widget.data['iso'] as String?;
    if (iso == null) return;
    try {
      final ref = await Files.resolve(iso);
      final res = await http.get(Uri.parse(ref.url), headers: ref.headers);
      if (res.statusCode >= 400 || res.bodyBytes.isEmpty) return;
      if (mounted) setState(() => _thumb = res.bodyBytes);
    } catch (_) {
      // 画像がなくてもカードは使える
    }
  }

  static String _date(Object? v) {
    final t = DateTime.tryParse('${v ?? ''}')?.toLocal();
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.data;
    final (label, tone, icon) = _reviewLook(r['approval_status'] as String?);
    final rev = r['revision'];
    final title = '${r['title'] ?? '道具'}${rev == null ? '' : '・版$rev'}';
    final who = '${r['requester_name'] ?? ''}'.trim();
    final requested = _date(r['requested_at']);
    final decided = _date(r['decided_at']);
    final when = [
      if (requested.isNotEmpty) '依頼 $requested',
      if (decided.isNotEmpty) '確認 $decided',
    ].join('　');
    final msg = '${r['message_ja'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          label: [
            title,
            label,
            if (who.isNotEmpty) '$whoさんから',
            if (when.isNotEmpty) when,
            if (msg.isNotEmpty) 'ひとこと：$msg',
          ].join('、'),
          excludeSemantics: true,
          child: InkWell(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
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
                        if (who.isNotEmpty || when.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            [if (who.isNotEmpty) '$whoさんから', if (when.isNotEmpty) when].join('　'),
                            style: AppText.bodySmall.copyWith(color: AppColors.onSurfaceVariant),
                          ),
                        ],
                        if (msg.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '「$msg」',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyLarge.copyWith(color: AppColors.onSurface),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.onSurfaceVariant),
                ],
              ),
            ),
          ),
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
              // 768px の確認用画像を、出す大きさ（56px × 画素の密度）で読み込む。そのままだとカードごとに大きな画像を
              // 読み込んで縮めて描き、一覧が重かった（2026-11-09）
              cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, _, _) =>
                  Icon(statusIcon, color: AppColors.primary),
            )
          : Icon(statusIcon, color: AppColors.primary),
    ),
  );
}
