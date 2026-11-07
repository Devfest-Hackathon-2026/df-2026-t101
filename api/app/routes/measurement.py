"""採寸の保存（docs/api.md §3.3）。生メッシュを実寸にし、カバーの目印と基準値を作る（geometry は担当B）"""
from __future__ import annotations

import uuid

from fastapi import APIRouter, Body, Depends

from .. import measure, ops
from ..auth import User, current_user
from ..errors import ApiError
from ..store import db, files, now
from .common import owned_case

router = APIRouter()


@router.put("/v1/cases/{case_id}/measurement")
def put_measurement(case_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case = owned_case(case_id, user)
    ops.assert_no_active(case)
    token, extra_warnings = measure.validate(body, case, case_id)
    mesh_id = body["capture"]["mesh_id"]
    raw = files.get(f"cases/{case_id}/hand/raw/{mesh_id}.glb")
    measure.check_mesh(raw, token)
    hand_side = body["hand_side"]
    if (case.get("requirements") or {}).get("hand_side") not in (None, hand_side):
        raise ApiError("MEASUREMENT_INVALID", details=[{"field": "hand_side", "constraint": "== requirements.hand_side"}])

    from .. import geometry  # 担当B
    try:
        g = geometry.prepare_measurement(raw, body, hand_side, requirements=case.get("requirements") or {})
    except geometry.GeometryError as e:
        raise ApiError(getattr(e, "code", "MEASUREMENT_INVALID"), getattr(e, "message_ja", None), getattr(e, "details", None))

    # 角度はブラウザの値ではなく、署名で守られたメッシュの関節から出し直す（measurement.md §11）
    flex = measure.flexion_from_joints(g["joints_mm"], hand_side)
    m = dict(body)
    m["fingers"] = {f: {**body["fingers"][f], "flexion_deg": flex.get(f, body["fingers"][f]["flexion_deg"])}
                    if f in flex else body["fingers"][f] for f in body["fingers"]}
    warnings = sorted(set((body.get("quality") or {}).get("warnings", []) + extra_warnings + g.get("warnings", [])))
    m.setdefault("quality", {})["warnings"] = warnings
    if body.get("manual_points"):
        m["palm"] = {**body["palm"], "segments_source": "manual"}

    measurement_id = "m_" + uuid.uuid4().hex[:8]
    mesh_path = f"cases/{case_id}/hand/{measurement_id}.glb"
    files.put(mesh_path, g["scaled_glb"], "model/gltf-binary")
    tool_d = (case.get("requirements") or {}).get("tool_d_mm")
    baseline = []
    for b in g.get("baseline", []):  # 道具の太さは聞き取りの値を正にする
        if b["part_id"] == "c_clip" and b["name"] == "tool_d_mm" and tool_d:
            b = {**b, "value": tool_d, "source": "interview"}
        baseline.append(b)
    hand_model = {
        "frame": "hand", "mesh_path": mesh_path, "scale_factor": g["scale_factor"],
        "scale_source": "manual_points" if body.get("manual_points") else "auto",
        "scale_spread_ratio": g.get("scale_spread_ratio"), "joints_mm": g["joints_mm"],
        "cover_landmarks": g["cover_landmarks"], "warnings": g.get("warnings", []),
    }
    status = "designing" if case["status"] in ("measuring", "designing", "previewing", "changes_requested") else case["status"]
    db.update(f"cases/{case_id}", {
        "measurement": {**m, "__replace__": True}, "measurement_id": measurement_id,
        "hand_model": {**hand_model, "__replace__": True}, "baseline": baseline, "measured_at": now(),
        "current_design_id": None, "status": status, "updated_at": now(),
    })
    return {"accepted": True, "measurement_id": measurement_id, "warnings": warnings,
            "hand_model": hand_model, "baseline": baseline, "case_status": status}
