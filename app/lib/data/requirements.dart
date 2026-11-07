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
