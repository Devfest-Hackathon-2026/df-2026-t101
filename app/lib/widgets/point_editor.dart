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
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              dataUrlBytes(widget.imageDataUrl),
                              fit: BoxFit.fill,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                        for (final e in widget.points.entries)
                          Positioned(
                            left: e.value.dx * scale - 16,
                            top: e.value.dy * scale - 16,
                            child: IgnorePointer(
                              child: _Dot(
                                label: e.key == '0' ? '手' : e.key,
                                selected: e.key == _selected,
                              ),
                            ),
                          ),
                        if (_dragging != null && _finger != null)
                          Positioned(
                            left: _finger!.dx - 60,
                            top: _finger!.dy - 150,
                            child: const RawMagnifier(
                              size: Size(120, 120),
                              magnificationScale: 3,
                              focalPointOffset: Offset(0, 90),
                              decoration: MagnifierDecoration(
                                shape: CircleBorder(
                                  side: BorderSide(
                                    color: AppColors.primary,
                                    width: 3,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in palmPointNames.entries)
              SuggestButton(
                label: '${e.key == _selected ? '● ' : ''}${e.value}',
                onPressed: () => setState(() => _selected = e.key),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Arrow(Icons.arrow_back, '左へ', () => _nudge(const Offset(-2, 0))),
            _Arrow(Icons.arrow_upward, '上へ', () => _nudge(const Offset(0, -2))),
            _Arrow(
              Icons.arrow_downward,
              '下へ',
              () => _nudge(const Offset(0, 2)),
            ),
            _Arrow(Icons.arrow_forward, '右へ', () => _nudge(const Offset(2, 0))),
          ],
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.label, required this.selected});
  final String label;
  final bool selected;
  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: (selected ? AppColors.accent : AppColors.primary).withValues(
        alpha: 0.85,
      ),
      border: Border.all(color: Colors.white, width: 2),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
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
