import 'package:jijogu_app/core/models/attachments.dart';

/// S7 で選んだ直し方（よく使う指示・クリップの角度）。押しただけでは送らず、画面の下のボタンで送る。
/// 隣のボタン（「もう少しゆるく」と「もう少しきつく」など）を押し間違えて作り直さないため（2026-11-22）
class RefineChoice {
  const RefineChoice._({
    required this.key,
    required this.buttonLabel,
    required this.body,
    required this.busyText,
    required this.doneText,
    this.angle,
  });

  /// よく使う指示（「もう少しゆるく」など）
  factory RefineChoice.instruction(
    String text,
    Map<String, dynamic> design,
    String? attachmentId,
  ) => RefineChoice._(
    key: 'instruction:$text:$attachmentId',
    buttonLabel: '「$text」で直す',
    body: withAttachment({'instruction': text}, design, attachmentId),
    busyText: '「$text」に合わせて直しています',
    doneText: '「$text」に合わせて直しました',
  );

  /// クリップの角度。[toolLabel] は取り付け具が2つ以上のときの道具の名前
  factory RefineChoice.angle(
    int angle,
    Map<String, dynamic> design,
    String? attachmentId, {
    String? toolLabel,
  }) {
    final clip = '${toolLabel == null ? '' : '$toolLabelの'}クリップ';
    return RefineChoice._(
      key: 'angle:$angle:$attachmentId',
      buttonLabel: '$clipを$angle度で描き直す',
      body: withAttachment({'clip_angle_deg': angle}, design, attachmentId),
      busyText: '$clipを$angle度で描き直しています（カバーはそのままです）',
      doneText: '$clipを$angle度にしました（カバーはそのままです）',
      angle: angle,
    );
  }

  final String key;

  /// 画面の下の主なボタンの文
  final String buttonLabel;

  /// refine に送る本文
  final Map<String, dynamic> body;

  /// 直している間に出す文
  final String busyText;

  /// 新しい版を開いたときに出す文
  final String doneText;

  /// 角度の選択なら、選んだ角度
  final int? angle;

  @override
  bool operator ==(Object other) => other is RefineChoice && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// OTに頼んだあと・確認済みの版を直すときの注意（直すと新しい版になり、確認は外れる）
String? reReviewNote(String approvalStatus) =>
    approvalStatus == 'requested' || approvalStatus == 'approved'
    ? '直すと新しい版になり、OTの確認をもう一度頼みます。'
    : null;
