import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:jijogu_app/core/api/api_error.dart';
import 'package:jijogu_app/core/models/attachments.dart' show angleByTool, flatReason, maxAttachments, toolJa;

/// 画面だけを通すためのモック（`--dart-define=MOCK_API=true`）。応答の形は docs/api.md の例に合わせる。
/// 3Dの見本は `web/demo/`（手 hand.glb、カバー cover.stl、留め具 c_clip_{60,70,80}.stl、刷る向きは *.print.stl、画像 iso.png）。
/// 取り付け具（ADR-0014）は requirements.tools の丸い柄から作り、留め具の見本は角度ごとの c_clip_{角度}.stl を使う。
/// 形を変えたら `scripts/make_demo_assets.py` で作り直す
class MockBackend {
  MockBackend._();
  static final instance = MockBackend._();

  final _cases = <String, Map<String, dynamic>>{};
  final _designs = <String, Map<String, dynamic>>{};
  final _orders = <String, Map<String, dynamic>>{};
  final _rand = Random(7);
  int _n = 0;

  String _id(String p) =>
      '${p}_${(++_n).toString().padLeft(3, '0')}${_rand.nextInt(900) + 100}';

  bool _seeded = false;

  /// `?mock_seed=print` で開くと、印刷の画面まで進んだデモのケースを1つ用意する（発注の画面の確認・デモ動画用）
  Future<void> _seed() async {
    _seeded = true;
    if (Uri.base.queryParameters['mock_seed'] != 'print') return;
    final cid = (await handle('POST', '/v1/cases', {'title': '筆のカバー（見本）'}))['case_id'] as String;
    await handle('PUT', '/v1/cases/$cid/requirements', {
      'activity': 'draw', 'tool_type': 'brush', 'hand_side': 'right', 'tool_d_mm': 9.5, 'tool_shaft_shape': 'round',
    });
    final d = (await handle('POST', '/v1/cases/$cid/designs', {}))['design'] as Map;
    _designs[d['design_id']]?['status'] = 'ready';
    _cases[cid]?['status'] = 'approved';
  }

  Future<dynamic> handle(String method, String path, Object? body) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!_seeded) await _seed();
    final b = (body is Map)
        ? Map<String, dynamic>.from(body)
        : <String, dynamic>{};
    final seg = Uri.parse(path).pathSegments;
    if (method == 'GET' && path == '/v1/cases') {
      return {
        'cases': [
          for (final c in _cases.values.toList().reversed) {...c, 'latest_order': _latestOrder(c['case_id'] as String)},
        ],
      };
    }
    if (method == 'POST' && path == '/v1/cases') {
      final id = _id('c');
      _cases[id] = {
        'case_id': id,
        'title': b['title'] ?? '新しい道具',
        'status': 'interviewing',
        'demo': true,
        'updated_at': DateTime.now().toIso8601String(),
      };
      return {'case_id': id, 'status': 'interviewing'};
    }
    if (method == 'GET' && path == '/v1/therapists') {
      return {
        'therapists': [
          {'display_name': '見本 OT', 'email': 'ot.demo@example.com'},
        ],
      };
    }
    if (method == 'GET' && path == '/v1/reviews') {
      // モックでは誰でもOT役。OTに頼んだケースを、OTのホームの欄に出す（ブラウザ1つで試せるように）
      final all = [
        for (final c in _cases.values.toList().reversed)
          if (c['reviewer_email'] != null) _reviewItem(c),
      ];
      return {
        'reviews': [
          ...all.where((r) => r['approval_status'] == 'requested'),
          ...all.where((r) => r['approval_status'] != 'requested'),
        ],
      };
    }
    if (method == 'GET' && path == '/v1/parts') return _parts;
    if (seg.length >= 2 && (seg[1] == 'fabricator' || seg[1] == 'orders')) {
      return _orderRoutes(method, seg, Uri.parse(path).queryParameters, b);
    }
    if (seg.length < 3 || seg[1] != 'cases') {
      throw ApiError('モックにないAPIです：$method $path', code: 'NOT_FOUND');
    }
    final c = _cases[seg[2]];
    if (c == null) throw ApiError('ケースがありません', code: 'NOT_FOUND');
    final rest = seg.sublist(3).join('/');
    if (method == 'DELETE' && rest.isEmpty) {
      _cases.remove(seg[2]);
      _designs.removeWhere((_, d) => d['case_id'] == seg[2]);
      return {'deleted': true, 'case_id': seg[2]};
    }
    c['updated_at'] = DateTime.now().toIso8601String();
    switch ((method, rest)) {
      case ('GET', ''):
        return c;
      case ('PUT', 'requirements'):
        // サーバー（routes/cases.py・attachments.py）と同じく tools を正規化し、今までの項目は主な道具にする
        final raw = (b['tools'] as List?)?.isNotEmpty == true
            ? [for (final t in b['tools'] as List) Map<String, dynamic>.from(t as Map)]
            : [b];
        final tools = [for (final t in raw) _normalizeTool(t)];
        final pi = tools.indexWhere((t) => t['tool_shaft_shape'] != 'flat');
        final primary = tools[pi < 0 ? 0 : pi];
        final r = {
          ...b,
          'tools': tools,
          'activity_ja': null,
          'notes': c['requirements']?['notes'] ?? [],
          'assumptions': _reqAssumptions(tools),
          for (final k in const ['activity', 'tool_type', 'tool_d_mm', 'tool_d_source', 'tool_shaft_size', 'tool_shaft_shape'])
            k: primary[k],
        };
        c['requirements'] = r;
        c['status'] = 'measuring';
        return {'requirements': r, 'case_status': 'measuring'};
      case ('POST', 'interview'):
        final notes = [
          ...List<String>.from(c['requirements']?['notes'] ?? []),
          '${b['message']}',
        ];
        c['requirements'] = {...?c['requirements'], 'notes': notes};
        c['turn_count'] = notes.length;
        return {
          'turn': {
            'status': 'done',
            'message_ja': 'わかりました。「${b['message']}」をメモしました。ほかになければ「まとめを見る」で進みます。',
            'choices': <String>[],
            'notes': notes,
            'suggested_changes': [],
            'out_of_scope_reason': 'none',
          },
          'requirements': {'notes': notes},
          'case_status': c['status'],
          'turn_count': notes.length,
        };
      case ('GET', 'orders'):
        final list = _orders.values.where((o) => o['case_id'] == c['case_id']).toList()
          ..sort((x, y) => '${y['created_at']}'.compareTo('${x['created_at']}'));
        return {'orders': list};
      case ('POST', 'consent'):
        c['mesh_consent_at'] = DateTime.now().toIso8601String();
        c['consent_text_version'] = b['consent_text_version'];
        return {'ok': true};
      case ('PUT', 'measurement'):
        final m = b;
        if ((m['capture']?['mesh_id'] ?? '') == '') {
          throw ApiError(
            '手の3Dの番号がありません。撮り直してください。',
            code: 'MEASUREMENT_INVALID',
          );
        }
        final manual = (m['manual_points'] as List?)?.isNotEmpty == true;
        final palm = Map<String, dynamic>.from(m['palm'] ?? {});
        final k = ((palm['hand_width_mcp_mm'] ?? 75) as num) / 75.0;
        final mid = _id('m');
        final hm = {
          'frame': 'hand',
          'mesh_path': 'demo/hand.glb',
          'scale_factor': double.parse(k.toStringAsFixed(3)),
          'scale_source': manual ? 'manual_points' : 'auto',
          'scale_spread_ratio': 0.04,
          'joints_mm': {
            'wrist': [0.0, 0.0, 0.0],
          },
          'cover_landmarks': {
            'palm_cut_base_mm': 38.6,
            'wrist_to_middle_mcp_mm': palm['wrist_to_middle_mcp_mm'] ?? 92.4,
            'rail_anchor': {
              'point_mm': [-31.5, 95.0, -6.0],
              'direction': [0.02, 0.62, 0.78],
            },
            'slit_zones': {
              'thumb_side': [-36.0, 52.0],
              'pinky_side': [44.0, 50.0],
            },
          },
        };
        c['measurement'] = m;
        c['hand_model'] = hm;
        c['measurement_id'] = mid;
        c['status'] = 'designing';
        c.remove('current_design_id');
        return {
          'accepted': true,
          'measurement_id': mid,
          'warnings': [
            ...List<String>.from(m['quality']?['warnings'] ?? []),
            if (manual) 'POINTS_MANUAL',
          ],
          'hand_model': hm,
          'baseline': [
            {
              'part_id': 'cover',
              'name': 'cover_thickness_mm',
              'value': 2.5,
              'source': 'default',
            },
            {
              'part_id': 'c_clip',
              'name': 'tool_d_mm',
              'value': c['requirements']?['tool_d_mm'] ?? 8.5,
              'source': 'interview',
            },
            {
              'part_id': 'c_clip',
              'name': 'angle_deg',
              'value': 70,
              'source': 'rule',
            },
          ],
          'case_status': 'designing',
        };
      case ('POST', 'designs'):
        // 取り付け具は丸い柄の道具から。平たい柄は作らずに知らせる（全部平たいなら作れない）
        final req = Map<String, dynamic>.from(c['requirements'] ?? {});
        final tools = _toolsOf(req);
        final pi = tools.indexWhere((t) => t['tool_shaft_shape'] != 'flat');
        if (pi < 0) {
          throw ApiError('平たい柄は、いまの留め具では挟めません', code: 'DESIGN_INFEASIBLE');
        }
        return _newDesign(
          c,
          atts: [
            for (final (i, t) in tools.indexed)
              if (t['tool_shaft_shape'] != 'flat') _attachment(t, i, primary: i == pi),
          ],
          issues: [
            for (final t in tools)
              if (t['tool_shaft_shape'] == 'flat') flatReason(t['tool_type'] as String?),
          ],
          color: b['style']?['color'] ?? '#2A9D8F',
          revision: 1,
          origin: 'initial',
        );
      case ('POST', 'recover'):
        return {
          'case_status': c['status'],
          'current_design_id': c['current_design_id'],
          'active_operation': null,
          'recovered': false,
        };
      case ('POST', 'review-request'):
        c['status'] = 'in_review';
        c['reviewer_email'] = b['reviewer_email'];
        final d = _designs[b['design_id']];
        if (d != null) {
          d['approval'] = {
            'status': 'requested',
            'requested_at': DateTime.now().toIso8601String(),
            'message_ja': '${b['message_ja'] ?? ''}',
          };
        }
        return {
          'case_status': 'in_review',
          'review_url': 'http://localhost:5173/#/review/${c['case_id']}',
        };
    }
    if (seg.length >= 5 && seg[3] == 'designs') {
      final d = _designs[seg[4]];
      if (d == null) throw ApiError('版がありません', code: 'NOT_FOUND');
      final act = seg.length > 5 ? seg[5] : '';
      if (method == 'GET' && act == '') return {'design': d};
      if (method == 'POST' && act == 'refine') {
        return _refine(c, d, b);
      }
      if (method == 'GET' && act == 'fabricators') return _fabricatorList(d);
      if (method == 'POST' && act == 'orders') return _createOrder(c, d, b);
      if (method == 'POST' && act == 'prepare-print') {
        d['print_prepared_at'] = DateTime.now().toIso8601String();
        d['files']['print'] = _printFiles(d);
        return {
          'design': d,
          'files': {'print': d['files']['print']},
        };
      }
      if (method == 'POST' && act == 'approval') {
        d['approval'] = {
          ...?(d['approval'] as Map?)?.cast<String, dynamic>(),
          'status': b['decision'] == 'approve' ? 'approved' : 'rejected',
          'comment_ja': b['comment_ja'],
          'decided_at': DateTime.now().toIso8601String(),
        };
        c['status'] = b['decision'] == 'approve' ? 'approved' : 'previewing';
        d['files']['print'] = _printFiles(d);
        return {
          'approval': d['approval'],
          'files': {'print': d['files']['print']},
          'case_status': c['status'],
        };
      }
    }
    throw ApiError('モックにないAPIです：$method $path', code: 'NOT_FOUND');
  }

  // ---------------------------------------------------------------- 発注（設計 §6.3。値は api/app/data/fabrication.json と同じ）
  static const _fabricators = [
    {'id': 'umikaze', 'name': 'うみかぜ3D工房', 'region': '大阪府 大阪市', 'fictional': true,
     'base_fee_yen': 800, 'yen_per_gram': 20, 'lead_days': 3, 'felt_service': true, 'felt_fee_yen': 200},
    {'id': 'hoshizora', 'name': 'ほしぞら出力舎', 'region': '北海道 札幌市', 'fictional': true,
     'base_fee_yen': 600, 'yen_per_gram': 30, 'lead_days': 5, 'felt_service': false, 'felt_fee_yen': 0},
    {'id': 'komorebi', 'name': 'こもれび造形ラボ', 'region': '東京都 品川区', 'fictional': true,
     'base_fee_yen': 1000, 'yen_per_gram': 25, 'lead_days': 2, 'felt_service': true, 'felt_fee_yen': 200},
  ];
  static const _printer = {
    'model': 'Bambu Lab A1', 'layer_mm': 0.2, 'infill_pct': 15,
    'supports_ja': 'カバーの内側、留め具のレールに入る舌の下', 'orientation_ja': 'ファイルの向きのまま',
  };
  static const _colorNames = {
    '#2A9D8F': 'ティール', '#E76F51': 'コーラル', '#264653': '紺', '#E9C46A': '黄色', '#F4F1EA': '白', '#5A666B': '灰色',
  };

  /// GET /v1/reviews の1件（api/app/routes/misc.py の reviews と同じ形）
  Map<String, dynamic> _reviewItem(Map<String, dynamic> c) {
    final d = _designs[c['current_design_id']] ?? const <String, dynamic>{};
    final ap = (d['approval'] as Map?) ?? const {};
    return {
      'case_id': c['case_id'],
      'title': c['title'],
      'case_status': c['status'],
      'design_id': c['current_design_id'],
      'revision': d['revision'],
      'approval_status': ap['status'] ?? 'none',
      'requested_at': ap['requested_at'],
      'decided_at': ap['decided_at'],
      'message_ja': ap['message_ja'] ?? '',
      'requester_name': '見本の利用者',
      'iso': (d['files'] as Map?)?['views']?['iso'],
      'updated_at': c['updated_at'],
    };
  }

  num _gramsOf(String key) => key == 'cover' ? 18 : (key.startsWith('tpu_sleeve') ? 3 : 4);
  String _materialOf(String key) => key == 'cover' ? 'PLA' : (key.startsWith('tpu_sleeve') ? 'TPU' : 'PETG');
  String _nameOf(String key, Map<String, dynamic> d) {
    if (key == 'cover') return 'カバー';
    if (key.startsWith('tpu_sleeve')) return 'TPUの筒';
    for (final a in (d['attachments'] as List?) ?? const []) {
      if ('${a['print_key'] ?? 'c_clip'}' == key) {
        return '留め具（${toolJa[a['tool_type']] ?? '道具'}・${a['angle_deg']}度）';
      }
    }
    return '留め具';
  }

  Map<String, dynamic> _estimates(Map<String, dynamic> d) => {
    for (final k in ((d['files']?['print'] as Map?) ?? const {}).keys)
      '$k': {'volume_mm3': 0, 'grams': _gramsOf('$k'), 'minutes': _gramsOf('$k') * 5 + 5},
  };

  int _r10(num v) => ((v / 10) + 0.5).floor() * 10;
  Map<String, int> _quote(Map f, Map<String, dynamic> est, List keys, int qty, bool felt) {
    final g = keys.fold<num>(0, (s, k) => s + (est['$k']?['grams'] as num? ?? 0));
    final parts = _r10((f['base_fee_yen'] as num) + (f['yen_per_gram'] as num) * g * qty);
    final fy = felt ? _r10((f['felt_fee_yen'] as num) * qty) : 0;
    return {'parts_yen': parts, 'felt_yen': fy, 'total_yen': parts + fy};
  }

  void _assertOrderable(Map<String, dynamic> d) {
    final approved = d['approval']?['status'] == 'approved';
    if (!(approved || d['print_prepared_at'] != null) || (d['files']?['print'] as Map?)?.isNotEmpty != true) {
      throw ApiError('OTの確認が済んだ版だけ発注できます', code: 'FORBIDDEN');
    }
  }

  Map<String, dynamic> _fabricatorList(Map<String, dynamic> d) {
    _assertOrderable(d);
    final est = _estimates(d);
    final keys = est.keys.toList();
    final list = [for (final f in _fabricators) {...f, 'price': _quote(f, est, keys, 1, false)}]
      ..sort((a, b) => ((a['price'] as Map)['total_yen'] as int).compareTo((b['price'] as Map)['total_yen'] as int));
    final hex = '${d['style']?['color'] ?? '#2A9D8F'}';
    return {
      'fabricators': list,
      'estimates': est,
      'printer': _printer,
      'materials': {for (final k in keys) k: _materialOf(k)},
      'names': {for (final k in keys) k: _nameOf(k, d)},
      'color': {'hex': hex, 'name_ja': _colorNames[hex] ?? ''},
      'felt': {'thickness_mm': 1.0},
      'delivery_days_after_ship': 2,
    };
  }

  Map<String, dynamic> _createOrder(Map<String, dynamic> c, Map<String, dynamic> d, Map<String, dynamic> b) {
    _assertOrderable(d);
    final f = _fabricators.where((x) => x['id'] == b['fabricator_id']).firstOrNull;
    final prints = Map<String, dynamic>.from(d['files']['print'] as Map);
    final keys = [for (final k in (b['print_keys'] as List? ?? const [])) '$k'];
    final qty = b['quantity'];
    final felt = b['felt'] == true;
    if (f == null || keys.isEmpty || keys.any((k) => !prints.containsKey(k)) || qty is! int || qty < 1 || qty > 3) {
      throw ApiError('入力の形が正しくありません', code: 'INVALID_ARGUMENT');
    }
    if (felt && !(f['felt_service'] == true && keys.contains('cover'))) {
      throw ApiError('この受託者・部品では、フェルトを貼って送れません', code: 'INVALID_ARGUMENT');
    }
    final est = _estimates(d);
    final id = _id('o');
    final now = DateTime.now().toUtc().toIso8601String();
    final hex = '${d['style']?['color'] ?? '#2A9D8F'}';
    final o = <String, dynamic>{
      'order_id': id,
      'display_id': id.substring(2, 6).toUpperCase(),
      'case_id': c['case_id'],
      'design_id': d['design_id'],
      'fabricator_id': f['id'],
      'fabricator_snapshot': {for (final k in ['name', 'region', 'lead_days', 'felt_service', 'felt_fee_yen', 'fictional']) k: f[k]},
      'status': 'received',
      'items': [
        for (final k in keys)
          {'print_key': k, 'name_ja': _nameOf(k, d), 'material': _materialOf(k), 'path': prints[k],
           'grams': est[k]['grams'], 'minutes': est[k]['minutes']},
      ],
      'quantity': qty,
      'color': {'hex': hex, 'name_ja': _colorNames[hex] ?? ''},
      'felt': felt,
      'price': _quote(f, est, keys, qty, felt),
      'lead_days': f['lead_days'],
      'printer': _printer,
      'approval': d['approval']?['status'] == 'approved'
          ? {'kind': 'ot', 'reviewer_email': c['reviewer_email'], 'decided_at': now}
          : {'kind': 'demo'},
      'shipping': Map<String, dynamic>.from(b['shipping'] as Map? ?? const {}),
      'demo': c['demo'] == true,
      'created_at': now,
      'printing_at': null,
      'shipped_at': null,
      'delivered_at': null,
      'cancelled_at': null,
      'updated_at': now,
    };
    _orders[id] = o;
    return {'order': o};
  }

  Map<String, dynamic>? _latestOrder(String caseId) {
    final list = _orders.values.where((o) => o['case_id'] == caseId && o['status'] != 'cancelled').toList()
      ..sort((x, y) => '${y['created_at']}'.compareTo('${x['created_at']}'));
    return list.isEmpty ? null : {'order_id': list.first['order_id'], 'status': list.first['status']};
  }

  Map<String, dynamic> _move(String id, String from, String to) {
    final o = _orders[id];
    if (o == null) throw ApiError('注文が見つかりません', code: 'NOT_FOUND');
    if (o['status'] != from) throw ApiError('注文の状態が変わりました。読み込み直してください', code: 'CONFLICT');
    final now = DateTime.now().toUtc().toIso8601String();
    o['status'] = to;
    o['${to}_at'] = now;
    o['updated_at'] = now;
    return {'order': o};
  }

  /// 受託者に見せる形（OTのメールは見せない。取り消した注文の届け先は残さない。サーバーの fabricator_view と同じ）
  Map<String, dynamic> _fabView(Map<String, dynamic> o) {
    final ap = Map<String, dynamic>.from(o['approval'] as Map? ?? const {});
    return {
      for (final e in o.entries)
        if (!const {'case_id', 'design_id', 'owner_uid'}.contains(e.key)) e.key: e.value,
      'approval': {'kind': ap['kind'], if (ap['kind'] == 'ot') 'decided_at': ap['decided_at']},
      if (o['status'] == 'cancelled') 'shipping': null,
    };
  }

  Future<dynamic> _orderRoutes(String method, List<String> seg, Map<String, String> q, Map<String, dynamic> b) async {
    // /v1/orders/{o}/(cancel|delivered)
    if (seg[1] == 'orders' && seg.length == 4 && method == 'POST') {
      if (seg[3] == 'cancel') return _move(seg[2], 'received', 'cancelled');
      if (seg[3] == 'delivered') return _move(seg[2], 'shipped', 'delivered');
    }
    // /v1/fabricator/...（モックの利用者は受託者アカウントも兼ねる）
    if (seg[1] == 'fabricator') {
      if (method == 'GET' && seg.length == 3 && seg[2] == 'me') {
        return {'fabricators': [for (final f in _fabricators) {'id': f['id'], 'name': f['name']}]};
      }
      if (method == 'GET' && seg.length == 3 && seg[2] == 'orders') {
        final list = _orders.values.where((o) => o['fabricator_id'] == q['fabricator_id']).toList()
          ..sort((x, y) => '${y['created_at']}'.compareTo('${x['created_at']}'));
        return {'orders': [for (final o in list) _fabView(o)]};
      }
      if (seg.length >= 4 && seg[2] == 'orders') {
        final o = _orders[seg[3]];
        if (o == null) throw ApiError('注文が見つかりません', code: 'NOT_FOUND');
        if (method == 'GET' && seg.length == 4) return {'order': _fabView(o)};
        if (method == 'POST' && seg.length == 5 && seg[4] == 'status') {
          final to = b['status'];
          if (to == 'printing') return {'order': _fabView(_move(seg[3], 'received', 'printing')['order'] as Map<String, dynamic>)};
          if (to == 'shipped') return {'order': _fabView(_move(seg[3], 'printing', 'shipped')['order'] as Map<String, dynamic>)};
          throw ApiError('変えられる状態は「造形中」と「発送済み」だけです', code: 'INVALID_ARGUMENT');
        }
      }
    }
    throw ApiError('モックにないAPIです：$method ${seg.join('/')}', code: 'NOT_FOUND');
  }

  /// 印刷用ファイル：カバーと、取り付け具ごと（print_key → 角度の留め具）
  Map<String, dynamic> _printFiles(Map<String, dynamic> d) {
    final atts = (d['attachments'] as List?) ?? const [];
    return <String, dynamic>{
      'cover': 'demo/cover.print.stl',
      if (atts.isEmpty) 'c_clip': 'demo/c_clip_${_angleOf(d)}.print.stl',
      for (final a in atts) '${a['print_key'] ?? 'c_clip'}': 'demo/c_clip_${a['angle_deg']}.print.stl',
    };
  }

  int _angleOf(Map<String, dynamic> d) =>
      ((d['params'] as List).firstWhere(
                (p) => p['name'] == 'angle_deg',
              )['value']
              as num)
          .toInt();

  /// 微調整（api.md §3.5）。生成APIと同じく、指示は1回に1つ。取り付け具を足す・角度・太さは取り付け具ごと
  Map<String, dynamic> _refine(
    Map<String, dynamic> c,
    Map<String, dynamic> d,
    Map<String, dynamic> b,
  ) {
    const kinds = ['instruction', 'param_changes', 'clip_angle_deg', 'tool_d_mm', 'add_attachment', 'style'];
    final keys = [for (final k in kinds) if (b[k] != null) k];
    if (keys.length != 1) {
      throw ApiError('${kinds.join('・')} のどれか1つだけを送ってください', code: 'INVALID_ARGUMENT');
    }
    final k = keys.first;
    final aid = b['attachment_id'];
    if (aid != null && aid is! String) {
      throw ApiError('attachment_id は文字列で送ってください', code: 'INVALID_ARGUMENT');
    }
    if (aid != null && (k == 'add_attachment' || k == 'style')) {
      throw ApiError('取り付け具を足すときと色を変えるときは attachment_id を送らないでください', code: 'INVALID_ARGUMENT');
    }
    if (k == 'style') {
      d['style'] = {...?d['style'], ...Map<String, dynamic>.from(b['style'])};
      return {'design': d};
    }
    if (k == 'instruction' && '${b['instruction']}'.contains('どこ')) {
      return {'clarify_ja': '人差し指の付け根の関節ですか？ 2つ目の関節ですか？'};
    }
    final req = Map<String, dynamic>.from(c['requirements'] ?? {});
    final tools = [for (final t in _toolsOf(req)) Map<String, dynamic>.from(t)];
    final atts = [
      for (final a in jsonDecode(jsonEncode(d['attachments'] ?? [])) as List)
        Map<String, dynamic>.from(a as Map),
    ];
    if (aid != null && !atts.any((a) => a['id'] == aid)) {
      throw ApiError('この版にない取り付け具です', code: 'INVALID_ARGUMENT');
    }
    final target = atts.firstWhere(
      (a) => a['id'] == aid,
      orElse: () => atts.firstWhere((a) => a['primary'] == true),
    );
    var origin = k == 'instruction' ? 'refine_text' : 'refine_params';
    var changedReq = false;
    switch (k) {
      case 'clip_angle_deg':
        final a = (b['clip_angle_deg'] as num).toInt();
        if (!const [60, 70, 80].contains(a)) {
          throw ApiError('角度は 60・70・80 のどれかです', code: 'INVALID_ARGUMENT');
        }
        target.addAll({'angle_deg': a, 'angle_source': 'user', 'reason_ja': '画面で角度を選びました'});
        origin = 'refine_clip_angle';
      case 'tool_d_mm':
        final v = _checkToolD(b['tool_d_mm']);
        target.addAll({'tool_d_mm': v, 'tool_d_source': 'user'});
        final i = (target['tool_index'] as num?)?.toInt() ?? 0;
        if (i < tools.length) tools[i] = _normalizeTool({...tools[i], 'tool_d_mm': v});
        origin = 'refine_tool_d';
        changedReq = true;
      case 'add_attachment':
        final t = Map<String, dynamic>.from(b['add_attachment'] as Map);
        if (t['tool_d_mm'] != null) _checkToolD(t['tool_d_mm']);
        if (t['tool_shaft_shape'] == 'flat') {
          throw ApiError(flatReason(t['tool_type'] as String?), code: 'INVALID_ARGUMENT');
        }
        if (max(atts.length, tools.length) >= maxAttachments) {
          throw ApiError('取り付け具は$maxAttachmentsつまでです', code: 'INVALID_ARGUMENT');
        }
        final tool = _normalizeTool(t);
        final nums = [for (final a in atts) int.tryParse('${a['id']}'.substring(1)) ?? 0];
        atts.add(_attachment(tool, tools.length, primary: false)
          ..['id'] = 'a${nums.fold(0, max) + 1}');
        tools.add(tool);
        origin = 'refine_add_attachment';
        changedReq = true;
    }
    if (changedReq) {
      // 足した道具・直した太さを聞き取りの記録に残す。今までの項目は主な道具
      final p = tools[tools.indexWhere((t) => t['tool_shaft_shape'] != 'flat').clamp(0, tools.length - 1)];
      c['requirements'] = {
        ...req,
        'tools': tools,
        'assumptions': _reqAssumptions(tools),
        for (final k in const ['tool_d_mm', 'tool_d_source']) k: p[k],
      };
    }
    return _newDesign(
      c,
      atts: atts,
      color: d['style']?['color'] ?? '#2A9D8F',
      revision: (d['revision'] as int) + 1,
      note: b['instruction'],
      origin: origin,
    );
  }

  Map<String, dynamic> _newDesign(
    Map<String, dynamic> c, {
    required List<Map<String, dynamic>> atts,
    required String color,
    required int revision,
    required String origin,
    List<String> issues = const [],
    Object? note,
  }) {
    final id = _id('d');
    // 今までの項目（params の c_clip・files.parts.c_clip）は主な取り付け具の値
    final primary = atts.firstWhere((a) => a['primary'] == true);
    final angle = (primary['angle_deg'] as num).toInt();
    final toolD = (primary['tool_d_mm'] as num).toDouble();
    final byUser = primary['angle_source'] == 'user';
    for (final a in atts) {
      a['files'] = {'preview_stl': 'demo/c_clip_${a['angle_deg']}.stl'};
      a['print_key'] = a['primary'] == true ? 'c_clip' : 'c_clip_${a['id']}';
      a['checks'] = [
        {'rule': 'R6f', 'ok': true, 'value': 1, 'message_ja': '留め具は受け具とねじの2つで、道具を挟める'},
        {'rule': 'R6h', 'ok': true, 'value': 0, 'message_ja': '道具の通り道に当たる所はありません'},
      ];
      a['clip'] = {'source': 'generated', 'tool_d_mm': a['tool_d_mm'], 'angle_deg': a['angle_deg']};
      a['tool'] = _demoTool(a['angle_deg'] as num?, a['tool_d_mm'] as num?);
    }
    final d = <String, dynamic>{
      'design_id': id,
      'revision': revision,
      'origin': origin,
      'status': issues.isEmpty ? 'ready' : 'needs_attention',
      'progress': {'step': 'reviewing', 'round': 2},
      'parts': [
        {
          'part_id': 'cover',
          'variant': 'standard',
          'reason_ja': '握った形のまま、手の甲側からかぶせられる形にしました',
        },
        {
          'part_id': 'air_holes',
          'variant': 'standard',
          'reason_ja': '長い時間使うので、手の甲に空気穴を6つ開けました',
        },
        {
          'part_id': 'strap_slits',
          'variant': 'single',
          'reason_ja': 'ベルト1本で留めます。回ってしまう場合は2本にできます',
        },
        {
          'part_id': 'rail',
          'variant': 'standard',
          'reason_ja': '人差し指の横に留め具を差し込みます',
        },
        {
          'part_id': 'c_clip',
          'variant': 'standard',
          'reason_ja': '道具の太さ${toolD}mmに合わせ、ねじで締める留め具にしました',
        },
      ],
      'params': [
        {
          'part_id': 'c_clip',
          'name': 'angle_deg',
          'value': angle,
          'unit': 'deg',
          'range': null,
          // catalog.json と同じ（2026-11-08 に 0／20／40 から変えた）
          'choices': [60, 70, 80],
          'baseline': 70,
          'source': byUser ? 'user' : 'ai',
          if (byUser) 'override_by_user': true,
          'reason_ja': primary['reason_ja'],
          'clamped': false,
        },
        {
          'part_id': 'cover',
          'name': 'cover_thickness_mm',
          'value': 2.5,
          'unit': 'mm',
          'range': [2.0, 3.5],
          'baseline': 2.5,
          'source': 'ai',
          'reason_ja': '留め具の力を受けるレールのまわりが割れにくい厚さにしました',
          'clamped': false,
        },
        {
          'part_id': 'c_clip',
          'name': 'tool_d_mm',
          'value': toolD,
          'unit': 'mm',
          'range': [3.5, 20],
          'baseline': toolD,
          'source': 'interview',
          'reason_ja': '聞き取りの道具の太さ',
          'clamped': false,
        },
        {
          'part_id': 'air_holes',
          'name': 'count',
          'value': 6,
          'unit': '',
          'range': [0, 10],
          'baseline': 6,
          'source': 'ai',
          'reason_ja': '長い時間使うため',
          'clamped': false,
        },
      ],
      'review': {
        'rounds': 2,
        'final_verdict': issues.isEmpty ? 'ok' : 'revise',
        'unresolved_issues': [
          for (final i in issues) {'severity': 'medium', 'description_ja': i},
        ],
      },
      'warnings': [],
      'hand_overlay': {'mesh_path': 'demo/hand.glb', 'frame': 'hand'},
      'tool': _demoTool(angle, toolD),
      'files': <String, dynamic>{
        'parts': {
          'cover': {'preview_stl': 'demo/cover.stl'},
          'c_clip': {'preview_stl': 'demo/c_clip_$angle.stl'},
        },
        'views': {'iso': 'demo/iso.png'},
      },
      'attachments': atts,
      'style': {'color': color, 'pattern': 'none'},
      'approval': {'status': 'none'},
      'summary_ja':
          '手の甲に沿うカバーに、道具の太さ${toolD}mmに合わせた$angle度の留め具を付けました。手のひら側と手首は開けてあります。${note == null ? '' : '（「$note」に合わせて直しました）'}',
    };
    _designs[id] = d;
    c['current_design_id'] = id;
    c['status'] = 'previewing';
    return {'design': d};
  }

  static const _parts = {
    'parts': [
      {
        'part_id': 'cover',
        'params': [
          {
            'name': 'cover_thickness_mm',
            'label_ja': 'カバーの厚み',
            'unit': 'mm',
            'min': 2.0,
            'max': 3.5,
            'step': 0.1,
          },
          {
            'name': 'palm_cut_offset_mm',
            'label_ja': '手のひら側を切る位置',
            'unit': 'mm',
            'min': -8,
            'max': 8,
            'step': 0.5,
          },
        ],
      },
      {
        'part_id': 'air_holes',
        'params': [
          {
            'name': 'count',
            'label_ja': '空気穴の数',
            'unit': '',
            'min': 0,
            'max': 10,
            'step': 1,
          },
        ],
      },
    ],
  };
}

/// hand-mesh のモックの応答（api.md §4 の例の形）
Map<String, dynamic> mockHandMeshBody(String caseId) => {
  'method': 'mesh_recovery',
  'model': 'mock',
  'fusion': 'median_params',
  'frames_used': 7,
  'mesh_id': 'hm_mock${caseId.hashCode.abs() % 100000}',
  'mesh_sha256': 'sha256:mock',
  'mesh_stats': {'vertices': 9134, 'faces': 18264, 'watertight': true},
  'joints_mm': {
    'wrist': [0.0, 0.0, 0.0],
  },
  'fingers': {
    for (final f in ['index', 'middle', 'ring', 'pinky'])
      f: {
        'flexion_deg': {'mcp': 70.0, 'pip': 85.0, 'dip': 30.0},
        'iqr_deg': {'mcp': 6.0, 'pip': 8.5, 'dip': 5.0},
      },
  },
  'warnings': <String>[],
  'result_token': 'v1.$caseId.mock',
};

/// 道具1つの太さを決める（生成APIの normalize_tool と同じ。数値があれば user、なければ区分から推定して category）
Map<String, dynamic> _normalizeTool(Map<String, dynamic> t) {
  const shaftD = {'thin': 6.0, 'medium': 8.5, 'thick': 11.5};
  const defaultD = {'brush': 8.5, 'pen': 8.5, 'spoon': 11.5};
  final out = <String, dynamic>{
    for (final k in const ['activity', 'tool_type', 'tool_d_mm', 'tool_shaft_size', 'tool_shaft_shape'])
      k: t[k],
  };
  final assumptions = <String>[];
  if (out['tool_d_mm'] != null) {
    out['tool_d_source'] = 'user';
  } else {
    out['tool_d_mm'] =
        shaftD[out['tool_shaft_size'] ?? 'unknown'] ?? defaultD[out['tool_type']] ?? 8.5;
    out['tool_d_source'] = 'category';
    assumptions.add('道具の太さは推定です。刷る前に太さを確かめてください');
  }
  if (out['tool_shaft_shape'] == 'flat') {
    assumptions.add('${toolJa[out['tool_type']] ?? '道具'}：平たい柄は留め具で挟めません。太柄スポンジなどで丸くしてください');
  }
  out['assumptions'] = assumptions;
  return out;
}

/// 要求の道具の一覧（tools がない古い要求は今までの項目から1つ。生成APIの normalize_tools と同じ）
List<Map<String, dynamic>> _toolsOf(Map<String, dynamic> req) {
  final ts = req['tools'];
  if (ts is List && ts.isNotEmpty) {
    return [for (final t in ts) Map<String, dynamic>.from(t as Map)];
  }
  return [_normalizeTool({...req, 'tool_shaft_shape': req['tool_shaft_shape'] ?? 'round'})];
}

/// 要求の assumptions。道具が複数のときは道具の名前をつける（生成APIの requirement_assumptions と同じ）
List<String> _reqAssumptions(List<Map<String, dynamic>> tools) => [
  for (final t in tools)
    for (final a in List<String>.from(t['assumptions'] as List? ?? const []))
      tools.length > 1 && !a.startsWith('${toolJa[t['tool_type']] ?? '道具'}：')
          ? '${toolJa[t['tool_type']] ?? '道具'}：$a'
          : a,
];

/// AIが角度を選んだ理由（モック。道具ごと）
const _angleReason = {
  'brush': '絵を描くので、筆を立て気味の70度をおすすめします。少し寝かせたいときは60度も選べます',
  'pen': '字を書くので、ペンを少し寝かせた60度をおすすめします。立て気味にしたいときは70度も選べます',
  'spoon': '食べるので、スプーンを口に運びやすい60度をおすすめします。立て気味にしたいときは70度も選べます',
};

/// 見本の留め具（web/demo/c_clip_{角度}.stl）の道具の軸（実際の手の座標）。scripts/make_demo_assets.py が出す値。
/// 万力式の留め具は形から道具の軸を推定できないので、生成APIと同じく版に書く（2026-11-24）
Map<String, dynamic> _demoTool(num? angle, num? toolD) {
  const axes = {
    60: [0.0, 0.5, -0.866],
    70: [0.0, 0.342, -0.9397],
    80: [0.0, 0.1736, -0.9848],
  };
  return {
    'center': [-65.23, 59.5, 11.68],
    'axis': axes[angle?.toInt()] ?? axes[70],
    'tip_mm': 100.0,
    'rear_mm': 50.0,
    'diameter_mm': (toolD ?? 8.5).toDouble(),
  };
}

/// 道具1つから取り付け具を作る（生成APIの build_attachments と同じ。ID は a＋道具の番号＋1）
Map<String, dynamic> _attachment(Map<String, dynamic> t, int i, {required bool primary}) {
  final type = t['tool_type'] as String?;
  return {
    'id': 'a${i + 1}',
    'tool_index': i,
    'tool_type': type,
    'activity': t['activity'],
    'tool_d_mm': (t['tool_d_mm'] as num?)?.toDouble() ?? 8.5,
    'tool_d_source': t['tool_d_source'],
    'angle_deg': angleByTool[type] ?? 70, // 道具が分からない古い要求は今までの70度
    'angle_source': 'ai',
    'reason_ja': _angleReason[type] ?? _angleReason['brush'],
    'primary': primary,
    'tool': null,
    'checks': <Map<String, dynamic>>[],
  };
}

/// 人が入れる柄の太さは、要求と同じ 3.5〜20mm（生成APIの _check_tool_d と同じ）
double _checkToolD(Object? v) {
  if (v is! num || v < 3.5 || v > 20.0) {
    throw ApiError('柄の太さは 3.5〜20mm で入れてください', code: 'INVALID_ARGUMENT');
  }
  return v.toDouble();
}
