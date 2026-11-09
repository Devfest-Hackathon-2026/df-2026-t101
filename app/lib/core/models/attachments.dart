import 'package:jijogu_app/core/models/requirements.dart' show ToolAnswer;

/// 道具の日本語名（生成APIの TOOL_JA と同じ）
const toolJa = {'brush': '筆', 'pen': 'ペン', 'spoon': 'スプーン'};

/// 1つの版の取り付け具の上限（生成APIの MAX_ATTACHMENTS と同じ）
const maxAttachments = 4;

/// 道具ごとの角度の目安・区分の太さ・わからないときの太さ（生成APIの attachments.py と同じ）
const angleByTool = {'brush': 70, 'pen': 60, 'spoon': 60};
const shaftD = {'thin': 6.0, 'medium': 8.5, 'thick': 11.5};
const defaultD = {'brush': 8.5, 'pen': 8.5, 'spoon': 11.5};

/// 足す道具のやりたいこと（質問1の組の逆）
const toolActivity = {'brush': 'draw', 'pen': 'write', 'spoon': 'eat'};

/// 平たい柄の道具の知らせ（生成APIの flat_reason と同じ）
String flatReason(String? toolType) =>
    '${toolJa[toolType] ?? '道具'}：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください';

num? _param(Map<String, dynamic> design, String name) {
  for (final p in (design['params'] as List? ?? const [])) {
    if (p is Map && p['part_id'] == 'c_clip' && p['name'] == name) {
      return p['value'] as num?;
    }
  }
  return null;
}

/// 版の取り付け具の一覧。古い版（attachments がない）は主な取り付け具1つとして組み立てる。
List<Map<String, dynamic>> attachmentsOf(Map<String, dynamic> design) {
  final atts = design['attachments'];
  if (atts is List && atts.isNotEmpty) {
    return [for (final a in atts) Map<String, dynamic>.from(a as Map)];
  }
  final parts = ((design['files'] as Map?)?['parts'] as Map?) ?? const {};
  final clip = parts['c_clip'] as Map?;
  return [
    {
      'id': 'a1',
      'tool_index': 0,
      'primary': true,
      'tool': design['tool'],
      'tool_type': null, // 古い版は道具の種類を持たない（tool は軸の形）
      'angle_deg': _param(design, 'angle_deg') ?? design['clip_angle_deg'],
      'tool_d_mm': _param(design, 'tool_d_mm'),
      'files': {'preview_stl': clip?['preview_stl']},
      'print_key': 'c_clip',
    },
  ];
}

/// 一覧での呼び名。同じ道具が他にもあるときは太さを付ける（生成APIの attachment_label と同じ）。
String attachmentLabel(Map<String, dynamic> att, List<Map<String, dynamic>> all) {
  final name = toolJa[att['tool_type']] ?? '道具';
  final same = all.any((o) =>
      !identical(o, att) && o['id'] != att['id'] && o['tool_type'] == att['tool_type']);
  if (!same) return name;
  return '$name ${_g(att['tool_d_mm'])}mm';
}

// Python の :g 相当（整数は小数点なし）
String _g(Object? v) {
  if (v is! num) return '$v';
  final d = v.toDouble();
  if (d == d.roundToDouble()) return d.toInt().toString();
  return double.parse(d.toStringAsPrecision(6)).toString();
}

// ───────── S7 の決め方（画面から切り出して、テストで確かめる） ─────────

/// 画面で使う取り付け具の一覧。古い版は、道具の名前・太さの出どころを要求から、角度の出どころを params から補う
List<Map<String, dynamic>> viewAttachments(Map<String, dynamic> design, Map<String, dynamic>? requirements) {
  final l = attachmentsOf(design);
  if (design['attachments'] is List && (design['attachments'] as List).isNotEmpty) return l;
  final a = l.first;
  a['tool_type'] ??= requirements?['tool_type'];
  a['tool_d_source'] ??= requirements?['tool_d_source'];
  for (final p in (design['params'] as List? ?? const [])) {
    if (p is Map && p['part_id'] == 'c_clip' && p['name'] == 'angle_deg') a['angle_source'] ??= p['source'];
  }
  return l;
}

Map<String, dynamic>? _primaryOf(List<Map<String, dynamic>> atts) =>
    atts.isEmpty ? null : atts.firstWhere((a) => a['primary'] == true, orElse: () => atts.first);

/// 選ぶ取り付け具の ID：wanted が版にあればそれ、なければ主な取り付け具
String? selectAttachment(List<Map<String, dynamic>> atts, String? wanted) {
  if (wanted != null && atts.any((a) => a['id'] == wanted)) return wanted;
  return _primaryOf(atts)?['id'] as String?;
}

/// 新しい版で選ぶ ID：足した取り付け具があればそれ、なければ今の選択（版から外れたら主）
String? selectionAfter(List<Map<String, dynamic>> before, List<Map<String, dynamic>> after, String? selected) {
  final old = {for (final a in before) a['id']};
  final added = [for (final a in after) if (!old.contains(a['id'])) a['id'] as String?];
  return selectAttachment(after, added.isNotEmpty ? added.last : selected);
}

/// 微調整の本文に、直す取り付け具の ID を添える。古い版（attachments がない）には添えない（サーバーは主を直す）
Map<String, dynamic> withAttachment(Map<String, dynamic> body, Map<String, dynamic> design, String? id) {
  final has = design['attachments'] is List && (design['attachments'] as List).isNotEmpty;
  return {...body, if (has && id != null) 'attachment_id': id};
}

/// 取り付け具を足せないときの文（足せるなら null）。要求の道具の数（平たい柄も）も数える（生成APIと同じ）
String? addBlockedReason(Map<String, dynamic> design, Map<String, dynamic>? requirements) {
  final n = (design['attachments'] as List?)?.length ?? 0;
  final t = (requirements?['tools'] as List?)?.length ?? 0;
  return (n > t ? n : t) >= maxAttachments ? '取り付け具は$maxAttachmentsつまでです' : null;
}

/// 足す画面の道具の答え（やりたいことは道具から決める）
ToolAnswer newTool(String toolType) => ToolAnswer()
  ..toolType = toolType
  ..activity = toolActivity[toolType];

/// 平たい柄を選んだときの知らせ
String? flatNotice(ToolAnswer t) => t.shaftShape == 'flat' ? flatReason(t.toolType) : null;

/// 「足す」「この太さで直す」を押せるか。太さを直すときは形を聞かない
bool canSubmitTool(ToolAnswer t, {bool fixOnly = false}) {
  final thick = t.toolDmm != null || t.shaftSize != null;
  if (fixOnly) return thick;
  return t.toolType != null && t.activity != null && thick && t.shaftShape == 'round';
}

/// 送る太さ（mm、なければ区分の目安、わからなければ道具の目安）
double toolDOf(ToolAnswer t) => t.toolDmm ?? shaftD[t.shaftSize] ?? defaultD[t.toolType] ?? 8.5;

/// おすすめの角度（取り付け具の ID → AIが選んだ角度）。前の版から持ってきた分は変えない
Map<String, int> recommendedAngles(Map<String, dynamic> design, Map<String, int> carried) {
  final out = {...carried};
  for (final a in viewAttachments(design, null)) {
    final id = a['id'] as String?, v = a['angle_deg'];
    if (id != null && !out.containsKey(id) && a['angle_source'] == 'ai' && v is num) out[id] = v.toInt();
  }
  return out;
}

/// 取り付け具を足した・太さを直した版か（カバーは前の版と同じ。ADR-0014 §4）
bool coverKept(Map<String, dynamic> design) =>
    const {'refine_add_attachment', 'refine_tool_d'}.contains(design['origin']);

/// S10 に「取り付け具を足す（形の画面へ）」を出すか。刷れる版で、まだ足せるとき
/// （カバーを刷ったあとでクリップを足す。ADR-0014 §4）
bool canAddFromPrint(Map<String, dynamic> design, Map<String, dynamic>? requirements, {required bool ready}) =>
    ready && addBlockedReason(design, requirements) == null;

// ───────── S10・S9 の一覧（画面から切り出して、テストで確かめる） ─────────

/// 印刷する部品の名前
const printPartJa = {'cover': 'カバー', 'c_clip': 'C字クリップ', 'tpu_sleeve': 'TPUの筒'};

/// S10 のダウンロードの1行
class PrintRow {
  const PrintRow(this.key, this.partId, this.name, this.path);
  final String key; // files.print のキー
  final String partId; // 絵・材料・刷り方の引き当て（cover／c_clip／tpu_sleeve）
  final String name;
  final String path;
}

/// S10 の行：カバー、取り付け具ごと、残り（TPUの筒など）。取り付け具が1つなら今までの「C字クリップ（70度）」
List<PrintRow> printRows(Map<String, dynamic> design, Map<String, dynamic>? requirements) {
  final print = Map<String, dynamic>.from(((design['files'] as Map?)?['print'] as Map?) ?? const {});
  final atts = viewAttachments(design, requirements);
  final rows = <PrintRow>[];
  final used = <String>{};
  void add(String key, String partId, String name) {
    rows.add(PrintRow(key, partId, name, '${print[key]}'));
    used.add(key);
  }

  if (print.containsKey('cover')) add('cover', 'cover', printPartJa['cover']!);
  for (final a in atts) {
    final key = (a['print_key'] as String?) ?? 'c_clip';
    if (!print.containsKey(key) || used.contains(key)) continue;
    final angle = a['angle_deg'];
    if (atts.length == 1) {
      add(key, 'c_clip', angle != null ? '${printPartJa['c_clip']}（${_g(angle)}度）' : printPartJa['c_clip']!);
    } else {
      add(key, 'c_clip', '${attachmentLabel(a, atts)} クリップ（${_g(a['tool_d_mm'])}mm・${_g(angle)}度）');
    }
  }
  for (final k in print.keys) {
    if (!used.contains(k)) add(k, k, printPartJa[k] ?? k);
  }
  return rows;
}

/// 「クリップは差し替えて使います」の案内を出すか（取り付け具が2つ以上のとき）
bool showSwapGuide(Map<String, dynamic> design) => attachmentsOf(design).length >= 2;

/// S9 の検査1つ（R6f・R6h）
class ReviewCheck {
  const ReviewCheck(this.rule, this.ok, this.value, this.messageJa);
  final String rule;
  final bool ok;
  final Object? value;
  final String messageJa;
  String get resultJa => ok ? '合格' : '注意';
}

/// S9 の取り付け具1つ分
class ReviewAttachment {
  const ReviewAttachment(this.title, this.summary, this.checks);
  final String title;
  final String summary; // 太さ・角度
  final List<ReviewCheck> checks;
}

/// S9 の取り付け具の一覧（道具・太さ・角度と R6f・R6h の結果）
List<ReviewAttachment> reviewAttachments(Map<String, dynamic> design, Map<String, dynamic>? requirements) {
  final atts = viewAttachments(design, requirements);
  return [
    for (final a in atts)
      ReviewAttachment(
        attachmentLabel(a, atts),
        [
          if (a['tool_d_mm'] != null) '太さ${_g(a['tool_d_mm'])}mm',
          if (a['angle_deg'] != null) '角度${_g(a['angle_deg'])}度',
        ].join('・'),
        [
          for (final c in (a['checks'] as List? ?? const []))
            if (c is Map) ReviewCheck('${c['rule']}', c['ok'] == true, c['value'], '${c['message_ja'] ?? ''}'),
        ],
      ),
  ];
}
