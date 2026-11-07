import 'package:flutter/material.dart';

import '../data/api.dart';
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

/// S1 ホーム（ケース一覧）
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

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: 'わたしの道具',
      bottom: FilledButton.icon(
        onPressed: _busy ? null : _create,
        icon: const Icon(Icons.add),
        label: const Text('新しく作る'),
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${Session.instance.displayName} さん',
                style: const TextStyle(color: AppColors.sub),
              ),
            ),
            TextButton(
              onPressed: () => Session.instance.signOut(),
              child: const Text('ログアウト'),
            ),
          ],
        ),
        if (_error != null)
          ErrorCard(message: '読み込めませんでした（$_error）', onRetry: _load)
        else if (_cases == null)
          for (var i = 0; i < 3; i++)
            Container(
              height: 76,
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEDEAE3),
                borderRadius: BorderRadius.circular(16),
              ),
            )
        else if (_cases!.isEmpty)
          const InfoCard(
            icon: Icons.brush_outlined,
            child: Text('まだ道具がありません。やりたいことを教えてください。'),
          )
        else
          for (final c in _cases!)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                minVerticalPadding: 14,
                leading: const Icon(Icons.back_hand_outlined),
                title: Text('${c['title'] ?? '道具'}'),
                subtitle: Text(
                  '${caseStatusJa[c['status']] ?? c['status']}　${(c['updated_at'] ?? '').toString().split('.').first.replaceAll('T', ' ')}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).pushNamed(continueRoute(c));
                  _load();
                },
              ),
            ),
      ],
    );
  }
}
