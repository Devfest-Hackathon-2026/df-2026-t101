import 'dart:async';
import 'dart:math';

import 'api.dart';

/// 画面だけを通すためのモック（`--dart-define=MOCK_API=true`）。応答の形は docs/api.md の例に合わせる。
/// 3Dの見本は `web/demo/`（手 hand.glb、カバー cover.stl、クリップ c_clip_{角度}.stl）
class MockBackend {
  MockBackend._();
  static final instance = MockBackend._();

  final _cases = <String, Map<String, dynamic>>{};
  final _designs = <String, Map<String, dynamic>>{};
  final _rand = Random(7);
  int _n = 0;

  String _id(String p) =>
      '${p}_${(++_n).toString().padLeft(3, '0')}${_rand.nextInt(900) + 100}';

  Future<dynamic> handle(String method, String path, Object? body) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final b = (body is Map)
        ? Map<String, dynamic>.from(body)
        : <String, dynamic>{};
    final seg = Uri.parse(path).pathSegments;
    if (method == 'GET' && path == '/v1/cases') {
      return {'cases': _cases.values.toList().reversed.toList()};
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
    if (method == 'GET' && path == '/v1/parts') return _parts;
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
        final r = {
          ...b,
          'tool_d_source':
              b['tool_d_mm'] != null && b['tool_shaft_size'] == null
              ? 'user'
              : 'category',
          'activity_ja': null,
          'notes': c['requirements']?['notes'] ?? [],
          'assumptions': b['tool_shaft_size'] == 'unknown' ? ['道具の太さは推定'] : [],
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
        return {
          'turn': {
            'status': 'done',
            'message_ja': 'わかりました。「${b['message']}」をメモしました。ほかになければ「とばす」で進みます。',
            'choices': <String>[],
            'notes': notes,
            'suggested_changes': [],
            'out_of_scope_reason': 'none',
          },
          'requirements': {'notes': notes},
          'case_status': c['status'],
          'turn_count': notes.length,
        };
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
              'value': 20,
              'source': 'rule',
            },
          ],
          'case_status': 'designing',
        };
      case ('POST', 'designs'):
        return _newDesign(
          c,
          angle: 20,
          color: b['style']?['color'] ?? '#2A9D8F',
          revision: 1,
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
        if (d != null) d['approval'] = {'status': 'requested'};
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
        if (b['style'] != null) {
          d['style'] = {
            ...?d['style'],
            ...Map<String, dynamic>.from(b['style']),
          };
          return {'design': d};
        }
        if (b['instruction'] != null && '${b['instruction']}'.contains('どこ')) {
          return {'clarify_ja': '人差し指の付け根の関節ですか？ 2つ目の関節ですか？'};
        }
        final angle = (b['clip_angle_deg'] as num?)?.toInt() ?? _angleOf(d);
        final byUser = b['clip_angle_deg'] != null;
        final r = _newDesign(
          c,
          angle: angle,
          color: d['style']?['color'] ?? '#2A9D8F',
          revision: (d['revision'] as int) + 1,
          note: b['instruction'],
        );
        if (byUser) {
          final p = (r['design']['params'] as List).firstWhere(
            (p) => p['name'] == 'angle_deg',
          );
          p['source'] = 'user';
          p['override_by_user'] = true;
        }
        return r;
      }
      if (method == 'POST' && act == 'prepare-print') {
        d['print_prepared_at'] = DateTime.now().toIso8601String();
        d['files']['print'] = {
          'cover': 'demo/cover.stl',
          'c_clip': 'demo/c_clip_${_angleOf(d)}.stl',
        };
        return {
          'design': d,
          'files': {'print': d['files']['print']},
        };
      }
      if (method == 'POST' && act == 'approval') {
        d['approval'] = {
          'status': b['decision'] == 'approve' ? 'approved' : 'rejected',
          'comment_ja': b['comment_ja'],
        };
        c['status'] = b['decision'] == 'approve' ? 'approved' : 'previewing';
        d['files']['print'] = {
          'cover': 'demo/cover.stl',
          'c_clip': 'demo/c_clip_${_angleOf(d)}.stl',
        };
        return {
          'approval': d['approval'],
          'files': {'print': d['files']['print']},
          'case_status': c['status'],
        };
      }
    }
    throw ApiError('モックにないAPIです：$method $path', code: 'NOT_FOUND');
  }

  int _angleOf(Map<String, dynamic> d) =>
      ((d['params'] as List).firstWhere(
                (p) => p['name'] == 'angle_deg',
              )['value']
              as num)
          .toInt();

  Map<String, dynamic> _newDesign(
    Map<String, dynamic> c, {
    required int angle,
    required String color,
    required int revision,
    Object? note,
  }) {
    final id = _id('d');
    final toolD = (c['requirements']?['tool_d_mm'] as num?)?.toDouble() ?? 8.5;
    final d = <String, dynamic>{
      'design_id': id,
      'revision': revision,
      'status': 'ready',
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
          'reason_ja': '人差し指の横にクリップを差し込みます',
        },
        {
          'part_id': 'c_clip',
          'variant': 'standard',
          'reason_ja': '道具の太さ${toolD}mmに合わせ、押し込むだけで留まるクリップにしました',
        },
      ],
      'params': [
        {
          'part_id': 'c_clip',
          'name': 'angle_deg',
          'value': angle,
          'unit': 'deg',
          'range': [0, 40],
          'choices': [0, 20, 40],
          'baseline': 20,
          'source': 'ai',
          'reason_ja': '絵を描くので、筆先が紙に向かいやすい20度をおすすめします。字を書くときは40度も選べます',
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
          'reason_ja': 'クリップの力を受けるレールのまわりが割れにくい厚さにしました',
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
      'review': {'rounds': 2, 'final_verdict': 'ok', 'unresolved_issues': []},
      'warnings': [],
      'hand_overlay': {'mesh_path': 'demo/hand.glb', 'frame': 'hand'},
      'files': {
        'parts': {
          'cover': {'preview_stl': 'demo/cover.stl'},
          'c_clip': {'preview_stl': 'demo/c_clip_$angle.stl'},
        },
        'views': {'iso': 'demo/iso.png'},
      },
      'style': {'color': color, 'pattern': 'none'},
      'approval': {'status': 'none'},
      'summary_ja':
          'こぶしの外側に沿うカバーに、道具の太さ${toolD}mmに合わせた$angle度のクリップを付けました。手のひら側と手首は開けてあります。${note == null ? '' : '（「$note」に合わせて直しました）'}',
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
