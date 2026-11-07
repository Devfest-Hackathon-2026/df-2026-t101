/// 画面のパス（docs/screens.md §1）。web に依存しないので、テストからも使える
class Paths {
  Paths._();
  static String interview(String c) => '/cases/$c/interview';
  static String capture(String c) => '/cases/$c/capture';
  static String design(String c, String? d) =>
      '/cases/$c/designs/${d ?? 'new'}';
  static String print(String c, String d) => '/cases/$c/designs/$d/print';
  static String review(String c) => '/review/$c';
}

/// ケースの状態から、続きの画面を決める（docs/screens.md §1）
String continueRoute(Map<String, dynamic> c) {
  final id = c['case_id'] as String;
  final d = c['current_design_id'] as String?;
  return switch (c['status']) {
    'interviewing' => Paths.interview(id),
    'measuring' => Paths.capture(id),
    'approved' when d != null => Paths.print(id, d),
    _ => Paths.design(id, d),
  };
}
