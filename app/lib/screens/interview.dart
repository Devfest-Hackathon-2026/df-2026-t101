import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/requirements.dart';
import '../router.dart';
import '../widgets/ui.dart';

/// S2 やりたいこと（選択式の7問 → 任意のチャット → まとめ）。docs/screens.md S2、api.md §3.2
class InterviewScreen extends StatefulWidget {
  const InterviewScreen({super.key, required this.caseId});
  final String caseId;
  @override
  State<InterviewScreen> createState() => _InterviewScreenState();
}

const _shaftJa = {
  'thin': '細い（約6mm）',
  'medium': 'ふつう（約8.5mm）',
  'thick': '太い（約11.5mm）',
  'unknown': 'わからない',
};

class _InterviewScreenState extends State<InterviewScreen> {
  final a = Answers();
  int _q = 0; // 0〜6：選択式、7：チャット、8：まとめ
  bool _mmInput = false;
  final _chat = <(bool, String)>[]; // (自分か, 文)
  final _input = TextEditingController();
  List<String> _choices = [];
  List<Map<String, dynamic>> _suggested = [];
  List<String> _notes = [];
  bool _busy = false;
  String? _error;
  int _turns = 0;

  void _set(VoidCallback f) {
    setState(f);
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (mounted && _q < 7 && a.isAnswered(_q) && !(_q == 2 && _mmInput)) {
        setState(() => _q++);
      }
    });
  }

  Future<void> _send(String text) async {
    if (text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _chat.add((true, text));
      _input.clear();
    });
    try {
      final r = await Api.instance.post(
        '/v1/cases/${widget.caseId}/interview',
        {'message': text.length > 500 ? text.substring(0, 500) : text},
      );
      final t = Map<String, dynamic>.from(r['turn']);
      setState(() {
        _turns++;
        _chat.add((false, '${t['message_ja']}'));
        _choices = List<String>.from(t['choices'] ?? []);
        _suggested = [
          for (final s in (t['suggested_changes'] as List? ?? []))
            Map<String, dynamic>.from(s),
        ];
        _notes = List<String>.from(t['notes'] ?? _notes);
      });
      if (t['status'] == 'out_of_scope' && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => OutOfScopeDialog(reason: '${t['message_ja']}'),
        );
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applySuggestion(Map<String, dynamic> s) {
    setState(() {
      final v = s['value'];
      switch (s['field']) {
        case 'hand_side':
          a.handSide = '$v';
        case 'tool_d_mm':
          a.toolDmm = (v as num?)?.toDouble() ?? double.tryParse('$v');
        case 'finger_state':
          a.fingerState = '$v';
        case 'donning_by':
          a.donningBy = '$v';
        case 'capture_by':
          a.captureBy = '$v';
        case 'tool_shaft_shape':
          a.shaftShape = '$v';
      }
      _suggested.remove(s);
    });
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.instance.put(
        '/v1/cases/${widget.caseId}/requirements',
        a.toJson(),
      );
      if (!mounted) return;
      if (r['case_status'] == 'interviewing') {
        setState(() => _error = '「その他」のときは、チャットでやりたいことを教えてください。');
        return;
      }
      Navigator.of(context)
          .pushReplacementNamed(AppRouter.capture(widget.caseId));
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_q == 7) return _chatPage();
    if (_q == 8) return _summaryPage();
    final (title, choices) = _question(_q);
    return AppPage(
      title: '${_q + 1}/7',
      onBack: _q == 0
          ? () => Navigator.of(context).pop()
          : () => setState(() => _q--),
      bottom: _q == 2 && _mmInput
          ? FilledButton(
              onPressed: () => setState(() {
                _mmInput = false;
                a.shaftSize = null;
                _q++;
              }),
              child: Text('${(a.toolDmm ?? 8.5).toStringAsFixed(1)}mmで決める'),
            )
          : (a.isAnswered(_q)
                ? FilledButton(
                    onPressed: () => setState(() => _q++),
                    child: const Text('次へ'),
                  )
                : null),
      children: [
        LinearProgressIndicator(value: (_q + 1) / 7),
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...choices,
      ],
    );
  }

  (String, List<Widget>) _question(int q) {
    Widget c(String label, bool sel, VoidCallback f, [String? sub]) =>
        ChoiceButton(
          label: label,
          sub: sub,
          selected: sel,
          onTap: () => _set(f),
        );
    switch (q) {
      case 0:
        return (
          '何をしたいですか',
          [
            c('絵を描く（筆）', a.activity == 'draw', () {
              a.activity = 'draw';
              a.toolType = 'brush';
            }),
            c('字を書く（ペン）', a.activity == 'write', () {
              a.activity = 'write';
              a.toolType = 'pen';
            }),
            c('食べる（スプーン）', a.activity == 'eat', () {
              a.activity = 'eat';
              a.toolType = 'spoon';
            }),
            c('その他', a.activity == 'other', () {
              a.activity = 'other';
              a.toolType = 'brush';
            }, 'あとのチャットで教えてください'),
          ],
        );
      case 1:
        return (
          'どちらの手に着けますか',
          [
            c('右手', a.handSide == 'right', () => a.handSide = 'right'),
            c('左手', a.handSide == 'left', () => a.handSide = 'left'),
          ],
        );
      case 2:
        return (
          '道具の柄の太さ（挟む所）',
          [
            const InfoCard(
              icon: Icons.straighten,
              child: Text(
                '指で持つあたり（クリップで挟む所）の太さです。1円玉（直径20mm）と並べると、目安になります。できるだけmmで入れてください（クリップをぴったりに作るため）。',
              ),
            ),
            if (_mmInput)
              _mmStepper()
            else ...[
              ChoiceButton(
                label: 'mmで入れる',
                sub: 'おすすめ。定規で測った太さを入れます',
                selected: a.toolDmm != null,
                onTap: () => setState(() {
                  _mmInput = true;
                  a.toolDmm ??= 8.5;
                  a.shaftSize = null;
                }),
              ),
              for (final e in _shaftJa.entries)
                c(e.value, a.toolDmm == null && a.shaftSize == e.key, () {
                  a.shaftSize = e.key;
                  a.toolDmm = null;
                }),
            ],
          ],
        );
      case 3:
        return (
          '柄の形は',
          [
            c('丸い', a.shaftShape == 'round', () => a.shaftShape = 'round'),
            c(
              '平たい',
              a.shaftShape == 'flat',
              () => a.shaftShape = 'flat',
              '平たい柄のクリップは準備中です',
            ),
          ],
        );
      case 4:
        return (
          'カバーとクリップを着け外しするのは',
          [
            c('自分でできる', a.donningBy == 'self', () => a.donningBy = 'self'),
            c(
              '家族や支援者がする',
              a.donningBy == 'helper',
              () => a.donningBy = 'helper',
            ),
          ],
        );
      case 5:
        return (
          '指の形は',
          [
            c(
              '握った形で固まっている',
              a.fingerState == 'fist',
              () => a.fingerState = 'fist',
            ),
            c(
              '少し曲がっている',
              a.fingerState == 'bent',
              () => a.fingerState = 'bent',
            ),
            c(
              'ほぼ伸ばせる',
              a.fingerState == 'straight',
              () => a.fingerState = 'straight',
              '軽く握った形で撮ってください',
            ),
          ],
        );
      default:
        return (
          '撮影するのは',
          [
            c('自分（片手）', a.captureBy == 'self', () => a.captureBy = 'self'),
            c(
              '家族や支援者',
              a.captureBy == 'helper',
              () => a.captureBy = 'helper',
              'おすすめです',
            ),
          ],
        );
    }
  }

  Widget _mmStepper() {
    final v = a.toolDmm ?? 8.5;
    Widget b(IconData i, String tip, double d) => IconButton.filledTonal(
      tooltip: tip,
      iconSize: 36,
      constraints: const BoxConstraints(minWidth: 72, minHeight: 72),
      onPressed: () => setState(() => a.toolDmm = (v + d).clamp(3.5, 20.0)),
      icon: Icon(i),
    );
    return InfoCard(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          b(Icons.remove, '0.5mm細く', -0.5),
          Semantics(
            liveRegion: true,
            child: Text(
              '${v.toStringAsFixed(1)} mm',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
          ),
          b(Icons.add, '0.5mm太く', 0.5),
        ],
      ),
    );
  }

  Widget _chatPage() {
    final required = a.activity == 'other';
    return AppPage(
      title: 'ほかに伝えたいこと',
      onBack: () => setState(() => _q = 6),
      bottom: FilledButton(
        onPressed: _busy || (required && _turns == 0)
            ? null
            : () => setState(() => _q = 8),
        child: Text(_chat.isEmpty ? 'とばす' : 'まとめを見る'),
      ),
      children: [
        if (_chat.isEmpty)
          InfoCard(
            child: Text(
              required
                  ? 'やりたいことを教えてください（例：「編み物の棒を持ちたい」）。病名などの詳しいことは書かなくてかまいません。'
                  : 'ほかに伝えたいことはありますか？（なければ「とばす」）病名などの詳しいことは書かなくてかまいません。',
            ),
          ),
        for (final (me, t) in _chat)
          Align(
            alignment: me ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                color: me ? const Color(0xFFE3EEF3) : AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.line),
              ),
              child: Text(t),
            ),
          ),
        if (_busy)
          const Padding(padding: EdgeInsets.all(8), child: Text('考えています…')),
        for (final s in _suggested)
          OutlinedButton(
            onPressed: () => _applySuggestion(s),
            child: Text('${s['reason_ja'] ?? '答えを変えますか？'}（変える）'),
          ),
        if (_error != null) ErrorCard(message: _error!),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t
                in (_choices.isNotEmpty
                    ? _choices
                    : const ['痛い所がある', '長い時間使いたい', '目立たない見た目がいい']))
              SuggestButton(
                label: t,
                onPressed: _busy || _turns >= 3 ? null : () => _send(t),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _input,
          maxLength: 500,
          minLines: 1,
          maxLines: 4,
          enabled: !_busy && _turns < 3,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: _turns >= 3 ? '会話は3往復までです' : '伝えたいこと（音声入力もキーボードから使えます）',
            suffixIcon: IconButton(
              tooltip: '送る',
              icon: const Icon(Icons.send),
              onPressed: _busy ? null : () => _send(_input.text),
            ),
          ),
          onSubmitted: _send,
        ),
      ],
    );
  }

  Widget _summaryPage() {
    String act() => switch (a.activity) {
      'draw' => '筆で絵を描く',
      'write' => 'ペンで字を書く',
      'eat' => 'スプーンで食べる',
      _ => 'その他',
    };
    final tool = a.toolDmm != null
        ? '柄の太さ${a.toolDmm!.toStringAsFixed(1)}mm（mmで入力）'
        : '柄の太さ：${_shaftJa[a.shaftSize]}';
    final rows = <(String, int)>[
      (act(), 0),
      (a.handSide == 'left' ? '左手' : '右手', 1),
      (tool, 2),
      (a.shaftShape == 'flat' ? '平たい柄' : '丸い柄', 3),
      (a.donningBy == 'self' ? '自分で着け外し' : '家族や支援者が着け外し', 4),
      (
        switch (a.fingerState) {
          'fist' => '握った形で固まっている',
          'bent' => '少し曲がっている',
          _ => 'ほぼ伸ばせる',
        },
        5,
      ),
      (a.captureBy == 'self' ? '自分で撮影' : '家族や支援者が撮影', 6),
    ];
    return AppPage(
      title: 'まとめ',
      onBack: () => setState(() => _q = 7),
      bottom: FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('この内容で撮影に進む'),
      ),
      children: [
        for (final (t, q) in rows)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              title: Text(t),
              trailing: TextButton(
                onPressed: () => setState(() => _q = q),
                child: const Text('直す'),
              ),
            ),
          ),
        if (a.shaftShape == 'flat')
          const InfoCard(
            color: Color(0xFFFFF4E0),
            icon: Icons.info_outline,
            child: Text('平たい柄のクリップは準備中です。丸い柄の道具を使うか、家族やOTと相談してください。'),
          ),
        if (a.toolDmm == null)
          const InfoCard(
            color: Color(0xFFFFF4E0),
            icon: Icons.straighten,
            child: Text('太さを推定で作ります。刷る前に、道具の太さを定規で確かめてください。'),
          ),
        if (_notes.isNotEmpty)
          InfoCard(
            icon: Icons.chat_bubble_outline,
            child: Text('メモ：${_notes.join('、')}'),
          ),
        if (_error != null) ErrorCard(message: _error!),
      ],
    );
  }
}

/// S11 対象外の案内
class OutOfScopeDialog extends StatelessWidget {
  const OutOfScopeDialog({super.key, required this.reason});
  final String reason;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('このアプリでは作れません'),
    content: Text(
      '$reason\n\n指を伸ばしたり固定したりする装具は、体に合わせた調整が必要なため、このアプリでは作れません。作業療法士に相談してください。',
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('閉じる'),
      ),
    ],
  );
}
