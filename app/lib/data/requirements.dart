/// 選択式の答え（requirements の名前は api.md §3.2）
class Answers {
  String? activity; // draw / write / eat / other
  String? toolType; // brush / pen / spoon
  String? handSide;
  double? toolDmm; // mm で入れたとき
  String? shaftSize; // thin / medium / thick / unknown（区分を選んだとき）
  String? shaftShape; // round / flat
  String? donningBy; // self / helper
  String? fingerState; // fist / bent / straight
  String? captureBy; // self / helper

  /// 保存済みの requirements（GET /v1/cases/{id}）から答えを戻す。開き直したときに前の答えを消さないため。
  /// 区分で答えたときは、サーバーが tool_d_mm に目安の値を入れて tool_d_source を 'category' にするので、
  /// そのときは mm ではなく区分として戻す。
  void loadFrom(Map<String, dynamic> r) {
    activity = r['activity'] as String?;
    toolType = r['tool_type'] as String?;
    handSide = r['hand_side'] as String?;
    shaftShape = r['tool_shaft_shape'] as String?;
    donningBy = r['donning_by'] as String?;
    fingerState = r['finger_state'] as String?;
    captureBy = r['capture_by'] as String?;
    final d = (r['tool_d_mm'] as num?)?.toDouble();
    if (d != null && r['tool_d_source'] != 'category') {
      toolDmm = d;
      shaftSize = null;
    } else {
      toolDmm = null;
      shaftSize = r['tool_shaft_size'] as String?;
    }
  }

  bool get isComplete => [for (var q = 0; q < 7; q++) isAnswered(q)].every((x) => x);

  bool isAnswered(int q) => switch (q) {
    0 => activity != null,
    1 => handSide != null,
    2 => toolDmm != null || shaftSize != null,
    3 => shaftShape != null,
    4 => donningBy != null,
    5 => fingerState != null,
    _ => captureBy != null,
  };

  Map<String, dynamic> toJson() => {
    'activity': activity,
    'tool_type': toolType,
    'hand_side': handSide,
    'tool_d_mm': toolDmm,
    'tool_shaft_size': toolDmm == null ? shaftSize : null,
    'tool_shaft_shape': shaftShape,
    'finger_state': fingerState,
    'donning_by': donningBy,
    'capture_by': captureBy,
  };
}
