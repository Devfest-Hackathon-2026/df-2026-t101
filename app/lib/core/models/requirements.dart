/// 1つの道具の答え（PUT requirements の tools の1件。送る項目はこの5つだけ）
class ToolAnswer {
  String? activity; // draw / write / eat / other
  String? toolType; // brush / pen / spoon
  double? toolDmm; // mm で入れたとき
  String? shaftSize; // thin / medium / thick / unknown（区分を選んだとき）
  String? shaftShape; // round / flat

  bool get isComplete =>
      activity != null && (toolDmm != null || shaftSize != null) && shaftShape != null;

  Map<String, dynamic> toJson() => {
    'activity': activity,
    'tool_type': toolType,
    'tool_d_mm': toolDmm,
    'tool_shaft_size': toolDmm == null ? shaftSize : null,
    'tool_shaft_shape': shaftShape,
  };

  /// 区分で答えたときはサーバーが tool_d_mm に目安を入れて tool_d_source を 'category' にするので、
  /// そのときは mm ではなく区分として戻す。
  static ToolAnswer fromJson(Map<String, dynamic> r) {
    final t = ToolAnswer()
      ..activity = r['activity'] as String?
      ..toolType = r['tool_type'] as String?
      ..shaftShape = r['tool_shaft_shape'] as String?;
    final d = (r['tool_d_mm'] as num?)?.toDouble();
    if (d != null && r['tool_d_source'] != 'category') {
      t.toolDmm = d;
    } else {
      t.shaftSize = r['tool_shaft_size'] as String?;
    }
    return t;
  }
}

/// 質問1のやりたいことと道具の組（その他は筆）
const activityTool = {'draw': 'brush', 'write': 'pen', 'eat': 'spoon', 'other': 'brush'};

/// S2a の選択式の並び（質問3・4は道具ごと）。(質問, 道具の番号)。道具がなければ質問3・4の段は作らない
List<(int, int)> interviewSteps(int nTools) => [
  (0, 0),
  (1, 0),
  for (var i = 0; i < nTools; i++) ...[(2, i), (3, i)],
  (4, 0),
  (5, 0),
  (6, 0),
];

/// 進み具合に出す全体の数。まだ道具を選んでいなくても、道具1つとして数える（今までの「1 / 7」）
int interviewTotal(int nTools) => 5 + 2 * (nTools < 1 ? 1 : nTools);

/// 選択式の答え（requirements の名前は api.md §3.2）
class Answers {
  List<ToolAnswer> tools = []; // 選んだ順
  String? handSide;
  String? donningBy; // self / helper
  String? fingerState; // fist / bent / straight
  String? captureBy; // self / helper

  /// 主な道具（最初の丸い柄、なければ最初）。空のときは空の答えを返す（tools は増やさない）。
  ToolAnswer get primary => tools.isEmpty
      ? ToolAnswer()
      : tools.firstWhere((t) => t.shaftShape != 'flat', orElse: () => tools[0]);

  // setter だけが道具を作る（空なら1つ足す）。あれば主な道具に書く
  ToolAnswer get _target {
    if (tools.isEmpty) tools.add(ToolAnswer());
    return primary;
  }

  // 今までの項目は主な道具を読み書きする（チャットの提案の当て先）。読むだけでは作らない
  String? get activity => primary.activity;
  set activity(String? v) => _target.activity = v;
  String? get toolType => primary.toolType;
  set toolType(String? v) => _target.toolType = v;
  double? get toolDmm => primary.toolDmm;
  set toolDmm(double? v) => _target.toolDmm = v;
  String? get shaftSize => primary.shaftSize;
  set shaftSize(String? v) => _target.shaftSize = v;
  String? get shaftShape => primary.shaftShape;
  set shaftShape(String? v) => _target.shaftShape = v;

  /// 質問1：押すたびに選ぶ／外す（選んだ順を保つ）。道具は activityTool の組
  void toggleActivity(String activity) {
    final i = tools.indexWhere((t) => t.activity == activity);
    if (i >= 0) {
      tools.removeAt(i);
    } else {
      tools.add(ToolAnswer()
        ..activity = activity
        ..toolType = activityTool[activity]);
    }
  }

  bool hasActivity(String activity) => tools.any((t) => t.activity == activity);

  /// 保存済みの requirements（GET /v1/cases/{id}）から答えを戻す。開き直したときに前の答えを消さないため。
  void loadFrom(Map<String, dynamic> r) {
    handSide = r['hand_side'] as String?;
    donningBy = r['donning_by'] as String?;
    fingerState = r['finger_state'] as String?;
    captureBy = r['capture_by'] as String?;
    final ts = r['tools'];
    if (ts is List && ts.isNotEmpty) {
      tools = [for (final t in ts) ToolAnswer.fromJson(Map<String, dynamic>.from(t as Map))];
    } else if (const ['activity', 'tool_type', 'tool_d_mm', 'tool_shaft_size', 'tool_shaft_shape']
        .any((k) => r[k] != null)) {
      tools = [ToolAnswer.fromJson(r)];
    } else {
      tools = [];
    }
  }

  bool get isComplete => [for (var q = 0; q < 7; q++) isAnswered(q)].every((x) => x);

  bool isAnswered(int q) => switch (q) {
    0 => tools.isNotEmpty && tools.every((t) => t.activity != null),
    1 => handSide != null,
    2 => tools.isNotEmpty && tools.every((t) => t.toolDmm != null || t.shaftSize != null),
    3 => tools.isNotEmpty && tools.every((t) => t.shaftShape != null),
    4 => donningBy != null,
    5 => fingerState != null,
    _ => captureBy != null,
  };

  Map<String, dynamic> toJson() {
    final p = primary;
    return {
      ...p.toJson(),
      'hand_side': handSide,
      'finger_state': fingerState,
      'donning_by': donningBy,
      'capture_by': captureBy,
      'tools': [for (final t in tools) t.toJson()],
    };
  }
}
