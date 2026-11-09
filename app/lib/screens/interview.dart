import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/attachments.dart' show toolJa;
import '../data/requirements.dart';
import '../router.dart';
import '../widgets/tool_fields.dart';
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

/// まとめの「やりたいこと」
const _actJa = {
  'draw': '筆で絵を描く',
  'write': 'ペンで字を書く',
  'eat': 'スプーンで食べる',
  'other': 'その他',
};

/// 同じ道具が2つあるときの呼び分け
const _actShort = {'draw': '絵を描く', 'write': '字を書く', 'eat': '食べる', 'other': 'その他'};

class _InterviewScreenState extends State<InterviewScreen> {
  final a = Answers();
  int _q = 0; // 0〜6：選択式、7：チャット、8：まとめ
  int _t = 0; // 質問3・4で答えている道具（a.tools の番号）
  bool _mmInput = false;
  final _chat = <(bool, String)>[]; // (自分か, 文)
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  List<String> _choices = [];
  List<Map<String, dynamic>> _suggested = [];
  List<String> _notes = [];
  bool _busy = false;
  String? _error;
  int _turns = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 前に答えた内容を戻す（開き直すと、前の答えが空に戻っていた。2026-11-09）
  Future<void> _load() async {
    try {
      final c = Map<String, dynamic>.from(
        await Api.instance.get('/v1/cases/${widget.caseId}'),
      );
      final r = Map<String, dynamic>.from(c['requirements'] as Map? ?? {});
      if (!mounted) return;
      setState(() {
        a.loadFrom(r);
        _notes = List<String>.from(r['notes'] as List? ?? []);
        _turns = (c['turn_count'] as num?)?.toInt() ?? 0;
        if (a.isComplete) _q = 8; // 全部答えてあれば、まとめから（鉛筆のボタンで直せる）
      });
    } catch (_) {
      // 読めなくても、最初から答えれば進める
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 選択式の並び（質問3・4は道具ごと）。道具が1つなら今までの7問
  List<(int, int)> get _steps => interviewSteps(a.tools.length);

  int get _pos => _steps.indexOf((_q, _t)).clamp(0, _steps.length - 1);

  void _go(int q, [int t = 0]) {
    if (t != _t || q == 0) _mmInput = false;
    _q = q;
    _t = t;
  }

  void _next() {
    final s = _steps;
    final i = _pos + 1;
    if (i < s.length) {
      _go(s[i].$1, s[i].$2);
    } else {
      _go(7);
    }
  }

  void _prev() {
    final p = _steps[_pos - 1];
    _go(p.$1, p.$2);
  }

  ToolAnswer get _tool => a.tools[_t];

  /// 今の問いに答えてあるか（質問3・4は今の道具だけを見る）
  bool get _answered => switch (_q) {
    2 => _tool.toolDmm != null || _tool.shaftSize != null,
    3 => _tool.shaftShape != null,
    _ => a.isAnswered(_q),
  };

  /// 道具の呼び名（同じ道具が2つあれば、やりたいことを添える）
  String _toolName(int i) {
    final t = a.tools[i];
    final name = toolJa[t.toolType] ?? '道具';
    final same = a.tools.where((o) => o.toolType == t.toolType).length > 1;
    return same ? '$name（${_actShort[t.activity] ?? 'その他'}）' : name;
  }

  void _set(VoidCallback f) {
    setState(f);
    final at = (_q, _t);
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      // 質問1はいくつでも選べるので、自動では進まない
      if (mounted &&
          _q > 0 &&
          _q < 7 &&
          (_q, _t) == at &&
          _answered &&
          !(_q == 2 && _mmInput)) {
        setState(_next);
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
        final rephrase = await showDialog<bool>(
          context: context,
          builder: (_) => OutOfScopeDialog(
            reason: '${t['message_ja']}',
            canRephrase: _turns < 3,
          ),
        );
        if (rephrase == true && mounted) _inputFocus.requestFocus();
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
    if (_loading) {
      return AppPage(
        title: 'やりたいこと',
        onBack: () => Navigator.of(context).pop(),
        children: const [BusyCard(text: '前に答えた内容を読み込んでいます')],
      );
    }
    if (_q == 7) return _chatPage();
    if (_q == 8) return _summaryPage();
    final (title, choices) = _question(_q);
    final pos = _pos;
    final total = interviewTotal(a.tools.length);
    return AppPage(
      title: 'やりたいこと',
      onBack: pos == 0
          ? () => Navigator.of(context).pop()
          : () => setState(_prev),
      bottom: _q == 2 && _mmInput
          ? _wide(
              FilledButton(
                onPressed: () => setState(() {
                  _mmInput = false;
                  _tool.toolDmm ??= 8.5;
                  _tool.shaftSize = null;
                  _next();
                }),
                child: Text('${(_tool.toolDmm ?? 8.5).toStringAsFixed(1)}mmで決める'),
              ),
            )
          : (_answered
                ? _wide(
                    FilledButton(
                      onPressed: () => setState(_next),
                      child: const Text('次へ'),
                    ),
                  )
                : null),
      children: [
        // 進み具合（Figma：「質問 1 / 7」＋ M3 の進み具合の棒）。道具が2つ以上なら、質問3・4の数だけ増える
        Text(
          '質問 ${pos + 1} / $total',
          style: AppText.labelLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: (pos + 1) / total),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            title,
            style: AppText.headlineSmall.copyWith(color: AppColors.onSurface),
          ),
        ),
        const SizedBox(height: 6),
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
    // 質問1：押すたびに選ぶ／外す（選んだ順に道具が並ぶ）
    Widget m(String label, String act, String sub) => ChoiceButton(
      label: label,
      sub: sub,
      multi: true,
      selected: a.hasActivity(act),
      onTap: () => setState(() => a.toggleActivity(act)),
    );
    // 質問3・4の見出し。道具が2つ以上なら道具の名前を前に付ける
    final tool = a.tools.length > 1 && (q == 2 || q == 3)
        ? '${_toolName(_t)}：'
        : '';
    switch (q) {
      case 0:
        return (
          '何をしたいですか',
          [
            const SizedBox(height: 6),
            Text(
              '使う道具をすべて選んでください（いくつでも）。',
              style: AppText.bodyLarge.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            m('絵を描く（筆）', 'draw', '筆を挟むクリップを作ります'),
            m('字を書く（ペン）', 'write', 'ペンを挟むクリップを作ります'),
            m('食べる（スプーン）', 'eat', 'スプーンを挟むクリップを作ります'),
            m('その他', 'other', 'あとのチャットで教えてください'),
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
          '$tool道具の柄の太さ（挟む所）',
          [
            const SizedBox(height: 6),
            Text(
              '指で持つあたり（クリップで挟む所）の太さです。',
              style: AppText.bodyLarge.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            for (final e in shaftRows.entries)
              c(
                e.value.$1,
                _tool.toolDmm == null && _tool.shaftSize == e.key,
                () {
                  _mmInput = false;
                  _tool.shaftSize = e.key;
                  _tool.toolDmm = null;
                },
                e.value.$2,
              ),
            if (_mmInput)
              _mmCard()
            else
              ChoiceButton(
                label: 'mmで入れる',
                sub: 'おすすめ。定規で測った太さを入れます',
                selected: _tool.toolDmm != null,
                onTap: () => setState(() {
                  _mmInput = true;
                  _tool.toolDmm ??= 8.5;
                  _tool.shaftSize = null;
                }),
              ),
            const SizedBox(height: 2),
            const InfoCard(
              tone: NoticeTone.info,
              child: Text('できるだけmmで入れてください（クリップをぴったりに作るため）。'),
            ),
          ],
        );
      case 3:
        return (
          '$tool柄の形は',
          [
            c('丸い', _tool.shaftShape == 'round', () => _tool.shaftShape = 'round'),
            c(
              '平たい',
              _tool.shaftShape == 'flat',
              () => _tool.shaftShape = 'flat',
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

  /// 「mmで入れる」を選んだときのカード（S7 の取り付け具を足す画面と同じ部品）
  Widget _mmCard() => ToolDmmCard(
    value: _tool.toolDmm ?? 8.5,
    onChanged: (v) => setState(() => _tool.toolDmm = v),
  );

  Widget _chatPage() {
    final required = a.activity == 'other';
    final lastAi = _chat.lastIndexWhere((m) => !m.$1);
    final canType = !_busy && _turns < 3;
    final next = _busy || (required && _turns == 0)
        ? null
        : () => setState(() => _q = 8);
    return AppPage(
      title: 'ほかに伝えたいこと',
      onBack: () => setState(() => _q = 6),
      bottom: _wide(
        _chat.isEmpty
            ? TextButton(
                onPressed: next,
                style: TextButton.styleFrom(minimumSize: const Size(64, 56)),
                child: const Text('とばす'),
              )
            : FilledButton(onPressed: next, child: const Text('まとめを見る')),
      ),
      children: [
        const InfoCard(
          tone: NoticeTone.info,
          child: Text('病名などの詳しいことは書かなくてかまいません。'),
        ),
        const SizedBox(height: 8),
        _Bubble(
          me: false,
          text: required
              ? 'やりたいことを教えてください（例：「編み物の棒を持ちたい」）。'
              : 'ほかに伝えたいことはありますか？（なければ「とばす」）',
        ),
        for (final (i, (me, t)) in _chat.indexed)
          _Bubble(
            me: me,
            text: t,
            actions: i == lastAi
                ? [
                    for (final s in _suggested)
                      SuggestButton(
                        label: '${s['reason_ja'] ?? '答えを変えますか？'}（変える）',
                        onPressed: () => _applySuggestion(s),
                      ),
                  ]
                : const [],
          ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const _AiAvatar(),
                const SizedBox(width: 8),
                Semantics(
                  liveRegion: true,
                  child: Text('考えています…', style: AppText.supporting),
                ),
              ],
            ),
          ),
        if (_error != null) ErrorCard(message: _error!),
        const SizedBox(height: 12),
        Text(
          '例（押すと送れます）',
          style: AppText.labelLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
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
        const SizedBox(height: 20),
        // 入力欄（Figma の Composer：丸い入力欄＋送るボタン）。
        // キーボードに隠れないよう、下のボタンの場所ではなく本文の最後に置く
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                enabled: canType,
                style: AppText.bodyLarge,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  hintText: _turns >= 3 ? '会話は3往復までです' : '伝えたいこと',
                  hintStyle: AppText.bodyLarge.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                  helperText: '音声入力もキーボードから使えます',
                  helperStyle: AppText.bodySmall.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                onSubmitted: _send,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '送る',
              style: IconButton.styleFrom(fixedSize: const Size(56, 56)),
              icon: const Icon(Icons.send_rounded),
              onPressed: _busy ? null : () => _send(_input.text),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryPage() {
    final one = a.tools.length == 1;
    String thick(ToolAnswer t) => t.toolDmm != null
        ? '${t.toolDmm!.toStringAsFixed(1)}mm（mmで入力）'
        : '${_shaftJa[t.shaftSize]}';
    String shape(ToolAnswer t) => t.shaftShape == 'flat' ? '平たい' : '丸い';
    // (見出し, 答え, 戻る質問, 道具の番号)。道具が2つ以上なら、道具ごとに「道具・太さ・形」の1行
    final rows = <(String, String, int, int)>[
      (
        'やりたいこと',
        a.tools.map((t) => _actJa[t.activity] ?? 'その他').join('、'),
        0,
        0,
      ),
      ('着ける手', a.handSide == 'left' ? '左手' : '右手', 1, 0),
      if (one) ...[
        ('柄の太さ', thick(a.tools[0]), 2, 0),
        ('柄の形', shape(a.tools[0]), 3, 0),
      ] else
        for (final (i, t) in a.tools.indexed)
          (_toolName(i), '柄の太さ ${thick(t)}・${shape(t)}', 2, i),
      ('着け外し', a.donningBy == 'self' ? '自分でできる' : '家族や支援者がする', 4, 0),
      (
        '指の形',
        switch (a.fingerState) {
          'fist' => '握った形で固まっている',
          'bent' => '少し曲がっている',
          _ => 'ほぼ伸ばせる',
        },
        5,
        0,
      ),
      ('撮影', a.captureBy == 'self' ? '自分（片手）' : '家族や支援者', 6, 0),
    ];
    final guessed = [
      for (final (i, t) in a.tools.indexed)
        if (t.toolDmm == null && t.shaftShape != 'flat') _toolName(i),
    ];
    return AppPage(
      title: 'まとめ',
      onBack: () => setState(() => _q = 7),
      bottom: _wide(
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.photo_camera_rounded),
          label: const Text('この内容で撮影に進む'),
        ),
      ),
      children: [
        Semantics(
          header: true,
          child: Text(
            'この内容で撮影に進みます',
            style: AppText.headlineSmall.copyWith(color: AppColors.onSurface),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '違う所があれば、鉛筆のボタンで直せます。',
          style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        // 答えの一覧（Figma の Summary list）。行ごとに「直す」（鉛筆）
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              for (final (i, (label, value, q, t)) in rows.indexed) ...[
                if (i > 0) const Divider(height: 1, thickness: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: MergeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: AppText.bodySmall.copyWith(
                                  color: AppColors.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                value,
                                style: AppText.bodyLarge.copyWith(
                                  color: AppColors.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '「$label」を直す',
                        icon: const Icon(Icons.edit_rounded),
                        color: AppColors.onSurfaceVariant,
                        onPressed: () => setState(() => _go(q, t)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (one && a.tools[0].shaftShape == 'flat')
          const InfoCard(
            tone: NoticeTone.warning,
            child: Text('平たい柄のクリップは準備中です。丸い柄の道具を使うか、家族やOTと相談してください。'),
          ),
        // 道具が2つ以上：平たい柄の道具だけクリップを作らない（ADR-0014 §1）
        if (!one)
          for (final t in a.tools)
            if (t.shaftShape == 'flat')
              InfoCard(
                tone: NoticeTone.warning,
                child: Text(
                  '${toolJa[t.toolType] ?? '道具'}：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください',
                ),
              ),
        if (guessed.isNotEmpty)
          InfoCard(
            tone: NoticeTone.warning,
            icon: Icons.straighten_rounded,
            child: Text(
              '${one ? '' : '${guessed.join('・')}の'}太さを推定で作ります。刷る前に、道具の太さを定規で確かめてください。',
            ),
          ),
        if (_notes.isNotEmpty) ...[
          const SizedBox(height: 4),
          // チャットのメモ（Figma の Chat memo）
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.chat_rounded,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'チャットのメモ',
                        style: AppText.titleSmall.copyWith(
                          color: AppColors.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _notes.join('、'),
                  style: AppText.bodyLarge.copyWith(color: AppColors.onSurface),
                ),
              ],
            ),
          ),
        ],
        if (_error != null) ErrorCard(message: _error!),
      ],
    );
  }
}

/// 下のボタンを幅いっぱいにする（docs/screens.md §2）
Widget _wide(Widget child) => SizedBox(width: double.infinity, child: child);

/// AI の印（Figma：tertiaryContainer の丸＋auto_awesome）
class _AiAvatar extends StatelessWidget {
  const _AiAvatar();
  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: SizedBox(
      width: 32,
      height: 32,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.tertiaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.auto_awesome_rounded,
          size: 18,
          color: AppColors.onTertiaryContainer,
        ),
      ),
    ),
  );
}

/// 会話の吹き出し。自分は右・primary、AI は左・surfaceContainerHigh＋印。
/// 色と位置だけで伝えないよう、読み上げでは「あなた」「AI」を添える
class _Bubble extends StatelessWidget {
  const _Bubble({required this.me, required this.text, this.actions = const []});
  final bool me;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: me ? AppColors.primary : AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(me ? 20 : 4),
          topRight: Radius.circular(me ? 4 : 20),
          bottomLeft: const Radius.circular(20),
          bottomRight: const Radius.circular(20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: me ? 'あなた' : 'AI',
            child: Text(
              text,
              style: AppText.bodyLarge.copyWith(
                color: me ? AppColors.onPrimary : AppColors.onSurface,
              ),
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: me
          ? Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(width: 48),
                Flexible(child: bubble),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _AiAvatar(),
                const SizedBox(width: 8),
                Flexible(child: bubble),
                const SizedBox(width: 24),
              ],
            ),
    );
  }
}

/// S11 対象外の案内（Figma の Basic dialog：警告の印・理由・代わりにできること）
class OutOfScopeDialog extends StatelessWidget {
  const OutOfScopeDialog({
    super.key,
    required this.reason,
    this.canRephrase = false,
  });
  final String reason;

  /// 「言い直す」を出すか（押すと true を返し、入力欄に戻る）
  final bool canRephrase;

  @override
  Widget build(BuildContext context) {
    Widget alt(String t) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3),
          child: Icon(
            Icons.check_circle_outline_rounded,
            size: 20,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            t,
            style: AppText.bodyLarge.copyWith(color: AppColors.onSurface),
          ),
        ),
      ],
    );
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('このアプリでは作れません', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$reason\n\n指を伸ばしたり固定したりする装具は、体に合わせた調整が必要なため、このアプリでは作れません。作業療法士に相談してください。',
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    '代わりにできること',
                    style: AppText.titleSmall.copyWith(
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                alt('握った形のまま、こぶしにかぶせて道具を持つカバーなら作れます'),
                const SizedBox(height: 10),
                alt('作業療法士に相談して、装具を作ってもらう'),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (canRephrase) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('閉じる'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('言い直す'),
          ),
        ] else
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('閉じる'),
          ),
      ],
    );
  }
}
