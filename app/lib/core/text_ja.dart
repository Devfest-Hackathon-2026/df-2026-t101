/// AI が書いた、利用者に見せる文（*_ja）から、項目名と英語の値を取り除く（生成APIの clean_ja と同じ決まり。2026-11-10）。
/// 新しい版は生成APIで掃除済み。前に作った版の文も、表示の前にここを通す。
/// - かっこの中が項目名だけ（tool_type=spoon、activity=eat、angle_deg など。「_」「=」「:」を含む英数字）なら、かっこごと消す
/// - かっこの外の「項目名=値」は、値が数なら数だけ残し、英語の値なら両方消す
/// 「PLA（ポリ乳酸）」「60度（おすすめ）」「(PLA)」のような、ふつうのかっこは残す
String cleanJa(String text) {
  if (text.isEmpty) return text;
  var out = text.replaceAllMapped(_codeParen, (m) => RegExp(r'[_=:]').hasMatch(m[1]!) ? '' : m[0]!);
  out = out.replaceAllMapped(_codeAssign, (m) => RegExp(r'^[\d.+\-]+$').hasMatch(m[1]!) ? m[1]! : '');
  out = out
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAllMapped(RegExp(r'[ \t]+([。、，．）)])'), (m) => m[1]!)
      .replaceAll(RegExp(r'。{2,}'), '。');
  return out.trim();
}

final _codeParen = RegExp(r'\s*[（(]\s*([A-Za-z0-9_.]+(?:\s*[=:]\s*[A-Za-z0-9_.+\-]+)?)\s*[）)]');
final _codeAssign = RegExp(r'(?<![A-Za-z0-9_.])[A-Za-z][A-Za-z0-9]*(?:[_.][A-Za-z0-9]+)*\s*=\s*([A-Za-z0-9_.+\-]+)');

/// 版などの値を、掃除した文にする（null は空文字）
String ja(Object? v) => cleanJa(v == null ? '' : '$v');
