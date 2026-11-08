import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../data/files.dart';
import '../widgets/ui.dart';

/// web/js/viewer.js が用意する window.jijoguViewer
extension type _Viewer._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> showHand(
    web.HTMLElement el,
    String url,
    String headersJson,
    String landmarksJson,
  );
  external JSPromise<JSAny?> showAssembly(web.HTMLElement el, String sceneJson);
  external JSPromise<JSAny?> setPart(
    web.HTMLElement el,
    String id,
    String url,
    String headersJson,
    String color,
  );
  external void setColor(web.HTMLElement el, String color);
  external void setHandVisible(web.HTMLElement el, bool visible);
  external void reframe(web.HTMLElement el);
}

@JS('jijoguViewer')
external _Viewer? get _viewer;

Future<_Viewer> _waitViewer() async {
  for (var i = 0; i < 100; i++) {
    final v = _viewer;
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('3D表示の準備ができませんでした');
}

/// 表示する部品（Storage のパスと色）
class PartFile {
  const PartFile(this.id, this.path);
  final String id;
  final String path;
}

/// three.js の3D表示を埋め込む。
/// - 手だけ（S5）：[handPath] と [landmarks]
/// - 組み付け（S7）：[handPath]（半透明）＋[parts]＋道具の棒（[toolDmm]）
class Viewer3D extends StatefulWidget {
  const Viewer3D({
    super.key,
    this.handPath,
    this.parts = const [],
    this.color = '#2A9D8F',
    this.toolDmm = 0,
    this.showHand = true,
    this.landmarks,
    this.label = '3Dの表示。指でドラッグすると回せます。2本の指で広げると大きくなります',
  });
  final String? handPath;
  final List<PartFile> parts;
  final String color;
  final double toolDmm;
  final bool showHand;
  final Map<String, dynamic>? landmarks;
  final String label;

  bool get assembly => parts.isNotEmpty;

  @override
  State<Viewer3D> createState() => _Viewer3DState();
}

class _Viewer3DState extends State<Viewer3D> {
  web.HTMLElement? _el;
  String? _error;

  Future<Map<String, dynamic>> _ref(String path) async {
    final r = await Files.resolve(path);
    return {'url': r.url, 'headers': r.headers};
  }

  Future<void> _render() async {
    final el = _el;
    if (el == null) return;
    try {
      final v = await _waitViewer();
      if (!widget.assembly) {
        if (widget.handPath == null) return;
        final h = await _ref(widget.handPath!);
        await v
            .showHand(
              el,
              h['url'] as String,
              jsonEncode(h['headers']),
              jsonEncode(widget.landmarks),
            )
            .toDart;
      } else {
        final parts = [
          for (final p in widget.parts)
            {'id': p.id, ...await _ref(p.path), 'color': widget.color},
        ];
        await v
            .showAssembly(
              el,
              jsonEncode({
                if (widget.handPath != null)
                  'hand': {
                    ...await _ref(widget.handPath!),
                    'opacity': 0.35,
                    'visible': widget.showHand,
                  },
                'parts': parts,
                'tool_d_mm': widget.toolDmm,
              }),
            )
            .toDart;
      }
      if (mounted && _error != null) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '3Dを読み込めませんでした（$e）');
    }
  }

  @override
  void didUpdateWidget(Viewer3D old) {
    super.didUpdateWidget(old);
    final partsChanged =
        old.parts.length != widget.parts.length ||
        [
          for (var i = 0; i < widget.parts.length; i++)
            old.parts[i].path != widget.parts[i].path,
        ].any((x) => x);
    if (old.handPath != widget.handPath ||
        partsChanged ||
        jsonEncode(old.landmarks) != jsonEncode(widget.landmarks)) {
      unawaited(_render());
      return;
    }
    final el = _el;
    final v = _viewer;
    if (el == null || v == null) return;
    if (old.color != widget.color) v.setColor(el, widget.color);
    if (old.showHand != widget.showHand) v.setHandVisible(el, widget.showHand);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      // Figma の 3D表示の面：surfaceContainerHigh・角丸28（three.js は背景を透かして描く）
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: ColoredBox(
          color: AppColors.surfaceContainerHigh,
          child: Stack(
            fit: StackFit.expand,
            children: [
              HtmlElementView.fromTagName(
                tagName: 'div',
                onElementCreated: (Object el) {
                  final div = el as web.HTMLDivElement;
                  div.style.width = '100%';
                  div.style.height = '100%';
                  _el = div;
                  unawaited(_render());
                },
              ),
              if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: AppText.bodyLarge.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
