import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../config.dart';
import '../data/mock_backend.dart';
import '../data/session.dart';

/// web/js/measure_engine.js（app/web_engine）が用意する window.jijoguMeasure
extension type _Engine._(JSObject _) implements JSObject {
  external JSPromise<JSString> init();
  external JSPromise<JSString> pickVideo(JSFunction? progress);
  external JSPromise<JSString> pickPhotos();
  external JSPromise<JSString> autoCoin(int index);
  external JSPromise<JSString> setCoin(double x, double y, int index);
  external JSPromise<JSString> frameImage(int index);
  external JSPromise<JSString> analyze(JSFunction? progress);
  external JSPromise<JSString> callHandMesh(
    String url,
    String caseId,
    String authName,
    String authValue,
    String handSide,
  );
  external JSPromise<JSString> useMockHandMesh(
    String bodyJson,
    String handSide,
  );
  external JSPromise<JSString> applyManualPoints(String json);
  external void reset();
  external JSPromise<JSString> startCamera(web.HTMLElement el);
  external JSPromise<JSString> switchCamera();
  external JSPromise<JSString> record(double maxSec, JSFunction? onTick);
  external void stopRecording();
  external void stopCamera();
}

@JS('jijoguMeasure')
external _Engine? get _engine;

class EngineError implements Exception {
  EngineError(
    this.message, {
    this.code = 'ENGINE_ERROR',
    this.retryable = false,
  });
  final String message;
  final String code;
  final bool retryable;
  @override
  String toString() => message;
}

typedef Progress = void Function(String stage, int i, int n);

/// 採寸エンジンの呼び出し。動画とフレームはJSの側だけにあり、Dartには数値と小さな画像だけが来る。
class MeasureEngine {
  MeasureEngine._();
  static final instance = MeasureEngine._();

  Future<_Engine> _e() async {
    for (var i = 0; i < 100; i++) {
      final e = _engine;
      if (e != null) return e;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw EngineError('採寸の準備ができませんでした');
  }

  Map<String, dynamic> _parse(JSString s) {
    final m = jsonDecode(s.toDart) as Map<String, dynamic>;
    final err = m['error'];
    if (err is Map) {
      throw EngineError(
        '${err['message']}',
        code: '${err['code']}',
        retryable: err['retryable'] == true,
      );
    }
    return m;
  }

  JSFunction? _cb(Progress? p) => p == null
      ? null
      : ((JSString stage, JSNumber i, JSNumber n) => p(
          stage.toDart,
          i.toDartInt,
          n.toDartInt,
        )).toJS;

  Future<void> init() async => _parse(await (await _e()).init().toDart);
  Future<Map<String, dynamic>> pickVideo([Progress? p]) async =>
      _parse(await (await _e()).pickVideo(_cb(p)).toDart);
  Future<Map<String, dynamic>> pickPhotos() async =>
      _parse(await (await _e()).pickPhotos().toDart);
  Future<Map<String, dynamic>> autoCoin([int index = 0]) async =>
      _parse(await (await _e()).autoCoin(index).toDart);
  Future<Map<String, dynamic>> setCoin(
    double x,
    double y, [
    int index = 0,
  ]) async => _parse(await (await _e()).setCoin(x, y, index).toDart);
  Future<Map<String, dynamic>> frameImage(int index) async =>
      _parse(await (await _e()).frameImage(index).toDart);
  Future<Map<String, dynamic>> analyze([Progress? p]) async =>
      _parse(await (await _e()).analyze(_cb(p)).toDart);

  /// hand-mesh（POST /v1/hand）を呼ぶ。モックのときは見本の応答を入れる
  Future<Map<String, dynamic>> callHandMesh(
    String caseId,
    String handSide,
  ) async {
    if (Config.mockApi) {
      return _parse(
        await (await _e())
            .useMockHandMesh(jsonEncode(mockHandMeshBody(caseId)), handSide)
            .toDart,
      );
    }
    final (k, v) = await Session.instance.authHeader();
    return _parse(
      await (await _e())
          .callHandMesh(Config.handMeshBase, caseId, k, v, handSide)
          .toDart,
    );
  }

  /// 確認の画面で直した点（代表のフレームの手首と付け根）から、手の甲の4区間を出し直す（measurement.md §13）
  Future<Map<String, dynamic>> applyManualPoints(
    List<Map<String, dynamic>> frames,
  ) async => _parse(
    await (await _e()).applyManualPoints(jsonEncode({'frames': frames})).toDart,
  );
  Future<void> reset() async => (await _e()).reset();

  /// アプリの中でカメラを開く（スマホは背面、PCはWebカメラ）
  Future<Map<String, dynamic>> startCamera(web.HTMLElement el) async =>
      _parse(await (await _e()).startCamera(el).toDart);
  Future<Map<String, dynamic>> switchCamera() async =>
      _parse(await (await _e()).switchCamera().toDart);

  /// 録画する。maxSec 秒か stopRecording で終わり、最初のフレームを返す
  Future<Map<String, dynamic>> record(
    double maxSec,
    void Function(double sec, bool hand) onTick,
  ) async => _parse(
    await (await _e())
        .record(
          maxSec,
          ((JSNumber sec, JSBoolean hand) => onTick(
            sec.toDartDouble,
            hand.toDart,
          )).toJS,
        )
        .toDart,
  );
  Future<void> stopRecording() async => (await _e()).stopRecording();
  Future<void> stopCamera() async => (await _e()).stopCamera();
}
