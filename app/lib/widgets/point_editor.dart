import 'package:flutter/material.dart';

import 'ui.dart';

/// 手首（0）と指の付け根（5・9・13・17）の名前（docs/screens.md §2：専門用語を使わない）
const palmPointNames = {
  '0': '手首',
  '5': '人差し指の付け根',
  '9': '中指の付け根',
  '13': '薬指の付け根',
  '17': '小指の付け根',
};

/// 代表のフレーム1枚の上で、手首と付け根の5点をドラッグで動かす（docs/screens.md S5「点を直す」）。
/// - 点はフレームのpxで持つ。画像の表示の大きさに合わせて直す
/// - ドラッグ中は、指で隠れないよう、点の上に3倍の拡大鏡を出す
/// - 読み上げを有効にすると位置が取れないので、画像は読み上げの対象から外し、点を選んで矢印で動かすボタンを添える
class PointEditor extends StatefulWidget {
  const PointEditor({
    super.key,
    required this.imageDataUrl,
    required this.width,
    required this.height,
    required this.points,
    required this.onChanged,
  });
  final String imageDataUrl;
  final double width;
  final double height;
  final Map<String, Offset> points;
  final void Function(String key, Offset framePx) onChanged;

  @override
  State<PointEditor> createState() => _PointEditorState();
}

class _PointEditorState extends State<PointEditor> {
  String? _dragging;
  Offset? _finger; // 表示の座標
  String _selected = '0';

  String? _nearest(Offset local, double scale) {
    String? best;
    var bestD = 44.0; // 指で押しやすい半径（表示の px）
    for (final e in widget.points.entries) {
      final d = (e.value * scale - local).distance;
      if (d < bestD) {
        bestD = d;
        best = e.key;
      }
    }
    return best;
  }

  void _nudge(Offset d) {
    final p = widget.points[_selected];
    if (p == null) return;
    widget.onChanged(
      _selected,
      Offset(
        (p.dx + d.dx).clamp(0, widget.width),
        (p.dy + d.dy).clamp(0, widget.height),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: widget.width / widget.height,
          child: LayoutBuilder(
            builder: (context, c) {
              final scale = c.maxWidth / widget.width;
              return Semantics(
                label: '写真。手首と指の付け根の点を動かせます。下のボタンでも動かせます',
                image: true,
                child: GestureDetector(
                  excludeFromSemantics: true,
                  onPanStart: (d) {
                    final k = _nearest(d.localPosition, scale);
                    setState(() {
                      _dragging = k;
                      _finger = d.localPosition;
                      if (k != null) _selected = k;
                    });
                  },
                  onPanUpdate: (d) {
                    final k = _dragging;
                    if (k == null) return;
                    final p = Offset(
                      (d.localPosition.dx / scale).clamp(0, widget.width),
                      (d.localPosition.dy / scale).clamp(0, widget.height),
                    );
                    setState(() => _finger = d.localPosition);
                    widget.onChanged(k, p);
                  },
                  onPanEnd: (_) => setState(() {
                    _dragging = null;
                    _finger = null;
                  }),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: ColoredBox(
                              color: _photoBackdrop,
                              child: Image.memory(
                                dataUrlBytes(widget.imageDataUrl),
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                        // 手首から各付け根への線（Figma：inversePrimary の細い線）
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _BonesPainter(widget.points, scale),
                            ),
                          ),
                        ),
                        for (final e in widget.points.entries)
                          Positioned(
                            left: e.value.dx * scale -
                                _Dot.sizeFor(e.key == _selected) / 2,
                            top: e.value.dy * scale -
                                _Dot.sizeFor(e.key == _selected) / 2,
                            child: IgnorePointer(
                              child: _Dot(
                                label: e.key == '0' ? '手' : e.key,
                                selected: e.key == _selected,
                              ),
                            ),
                          ),
                        if (_dragging != null && _finger != null) ...[
                          Positioned(
                            left: _finger!.dx - 50,
                            top: _finger!.dy - 160,
                            child: const RawMagnifier(
                              size: Size(100, 100),
                              magnificationScale: 3,
                              focalPointOffset: Offset(0, 110),
                              decoration: MagnifierDecoration(
                                shape: CircleBorder(
                                  side: BorderSide(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: _finger!.dx - 50,
                            top: _finger!.dy - 56,
                            width: 100,
                            child: IgnorePointer(
                              child: ExcludeSemantics(
                                child: Text(
                                  '3倍に拡大',
                                  textAlign: TextAlign.center,
                                  style: AppText.labelSmall.copyWith(
                                    color: Colors.white,
                                    shadows: const [
                                      Shadow(
                                        blurRadius: 3,
                                        color: Colors.black54,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in palmPointNames.entries)
              _PointChip(
                label: e.value,
                selected: e.key == _selected,
                onPressed: () => setState(() => _selected = e.key),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Arrow(
              Icons.arrow_back_rounded,
              '左へ',
              () => _nudge(const Offset(-2, 0)),
            ),
            _Arrow(
              Icons.arrow_upward_rounded,
              '上へ',
              () => _nudge(const Offset(0, -2)),
            ),
            _Arrow(
              Icons.arrow_downward_rounded,
              '下へ',
              () => _nudge(const Offset(0, 2)),
            ),
            _Arrow(
              Icons.arrow_forward_rounded,
              '右へ',
              () => _nudge(const Offset(2, 0)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 写真の後ろの暗い色（Figma の写真の枠と同じ）
const _photoBackdrop = Color(0xFF2C3134);

/// 手首（0）から指の付け根への線
class _BonesPainter extends CustomPainter {
  _BonesPainter(this.points, this.scale);
  final Map<String, Offset> points;
  final double scale;
  @override
  void paint(Canvas canvas, Size size) {
    final w = points['0'];
    if (w == null) return;
    final paint = Paint()
      ..color = AppColors.inversePrimary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final e in points.entries) {
      if (e.key == '0') continue;
      canvas.drawLine(w * scale, e.value * scale, paint);
    }
  }

  @override
  bool shouldRepaint(_BonesPainter old) => true;
}

/// 動かせる点（Figma：白い縁の大きな丸。ふだんは primary を薄く、選んだ点は大きく明るく）。
/// 色だけで伝えないよう、選んだ点は大きさも変え、中に名前の文字を出す
class _Dot extends StatelessWidget {
  const _Dot({required this.label, required this.selected});
  final String label;
  final bool selected;

  static double sizeFor(bool selected) => selected ? 44 : 40;

  @override
  Widget build(BuildContext context) => Container(
    width: sizeFor(selected),
    height: sizeFor(selected),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: selected
          ? AppColors.inversePrimary.withValues(alpha: 0.6)
          : AppColors.primary.withValues(alpha: 0.45),
      border: Border.all(color: Colors.white, width: 3),
    ),
    child: Text(
      label,
      style: AppText.labelMedium.copyWith(
        color: selected ? AppColors.onPrimaryContainer : Colors.white,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// 動かす点を選ぶチップ（Figma の Filter chip の見た目）。選ぶとチェックの印が付く。
/// FilterChip は読み上げで「チェックボックス」になるため、ボタン＋selected にする
class _PointChip extends StatelessWidget {
  const _PointChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.only(left: selected ? 8 : 16, right: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: AppText.labelLarge.copyWith(fontSize: 16),
        backgroundColor: selected ? AppColors.secondaryContainer : null,
        foregroundColor: selected
            ? AppColors.onSecondaryContainer
            : AppColors.onSurfaceVariant,
        side: selected
            ? BorderSide.none
            : const BorderSide(color: AppColors.outlineVariant),
      ),
      icon: selected ? const Icon(Icons.check_rounded, size: 18) : null,
      label: Text(label),
    ),
  );
}

class _Arrow extends StatelessWidget {
  const _Arrow(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: IconButton.outlined(
      tooltip: '選んだ点を$labelうごかす',
      iconSize: 28,
      constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
      onPressed: onTap,
      icon: Icon(icon),
    ),
  );
}
