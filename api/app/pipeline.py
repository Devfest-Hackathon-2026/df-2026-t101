"""形を作る流れ（docs/generation-pipeline.md §1・§4・§5、api.md §3.4〜§3.6・§3.11）。
部品選び → 寸法決め → 範囲チェック → 殻と描画（geometry）→ 描いたあとの検査 → 画像での確認（最大3回）。"""
from __future__ import annotations

import copy
import hashlib
import json
import logging
import shutil
import tempfile
import time
import uuid
from pathlib import Path

from . import gemini, ops, validator
from .attachments import (ANGLE_BY_TOOL, attachment_label, attachment_params, build_attachments, clip_stem,
                          next_attachment_id, normalize_tool, primary_index, print_key, requirement_assumptions,
                          stored_tools)
from .config import settings
from .errors import ApiError
from .store import Cache, db, files, now
from .validator import Param

log = logging.getLogger("pipeline")
MAX_ROUNDS = 3
SAFETY_RULES = ("R6c", "R6d")


class Deadline:
    def __init__(self, seconds: int):
        self.t_end = time.monotonic() + seconds

    def left(self) -> float:
        return self.t_end - time.monotonic()

    def check(self) -> None:
        if time.monotonic() > self.t_end:
            raise ApiError("GENERATION_TIMEOUT")


def _geometry():
    from . import geometry  # 担当B の入口（api/app/geometry）
    return geometry


def hand_summary(case: dict) -> dict:
    """Gemini に渡す手の要約（メッシュそのものは渡さない。generation-pipeline.md §3.3）"""
    hm = case.get("hand_model") or {}
    m = case.get("measurement") or {}
    lm = hm.get("cover_landmarks") or {}
    palm = m.get("palm") or {}
    return {
        "wrist_to_middle_mcp_mm": lm.get("wrist_to_middle_mcp_mm") or palm.get("wrist_to_middle_mcp_mm"),
        "hand_width_mcp_mm": palm.get("hand_width_mcp_mm"),
        "palm_cut_base_mm": lm.get("palm_cut_base_mm"),
        "flexion_deg": {f: (m.get("fingers", {}).get(f) or {}).get("flexion_deg") for f in ("index", "middle", "ring", "pinky")},
        "scale_factor": hm.get("scale_factor"), "scale_source": hm.get("scale_source"),
        "warnings": (m.get("quality") or {}).get("warnings", []) + (hm.get("warnings") or []),
        "points_manual": bool(m.get("manual_points")),
    }


def _param_defs_for_prompt(selected: list[str], baseline: dict[tuple[str, str], Param]) -> list[dict]:
    out = []
    for pid in selected:
        for d in validator.ai_params(pid):
            b = baseline.get((pid, d["name"]))
            out.append({"part_id": pid, "name": d["name"], "unit": d.get("unit"), "type": d.get("type"),
                        "min": d.get("min"), "max": d.get("max"), "choices": d.get("choices"),
                        "ai_delta": d.get("ai_delta"), "baseline": b.value if b else d.get("default"),
                        "source": b.source if b else "default", "description_ja": d.get("description_ja")})
    return out


def _catalog_summary() -> list[dict]:
    return [{"id": p["id"], "required": p.get("required", False), "description_ja": p.get("description_ja", "")}
            for p in validator.catalog()["parts"]]


def _progress(case_id: str, design_id: str, step: str, message_ja: str, round_no: int = 0) -> None:
    db.update(f"cases/{case_id}/designs/{design_id}",
              {"progress": {"step": step, "round": round_no, "max_rounds": MAX_ROUNDS, "message_ja": message_ja}})


def geometry_hash(parts: list[str], params: list[Param], shell_sha: str | None, attachments: list[dict] | None = None) -> str:
    body = {"parts": sorted(parts), "params": sorted([[p.part_id, p.name, p.value] for p in params]),
            "cover_shell_sha256": shell_sha, "catalog_version": validator.catalog().get("version")}
    if attachments:   # 取り付け具が違えば別のハッシュにする
        body["attachments"] = [[a["id"], a["tool_d_mm"], a["angle_deg"]] for a in attachments]
    return "sha256:" + hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def clip_stems(atts: list[dict]) -> dict[str, str]:
    """取り付け具ごとのSTLの名前の元。同じ名前になる取り付け具（道具・太さ・角度が同じ）には ID をつけて分ける"""
    stems = {a["id"]: clip_stem(a, atts) for a in atts}
    dup = {s for s in stems.values() if list(stems.values()).count(s) > 1}
    return {k: f"{s}_{k}" if s in dup else s for k, s in stems.items()}


def _upload_preview(case_id: str, design_id: str, result: dict, atts: list[dict]) -> dict:
    """プレビュー用STLと確認用画像を置く。取り付け具ごとの files.preview_stl も atts に入れる（atts[0] が主）"""
    out = {"parts": {}, "views": {}}
    stems = clip_stems(atts)
    for part, path in (result.get("files") or {}).items():
        name = f"{stems[atts[0]['id']]}.preview.stl" if part == "c_clip" else f"{part}.preview.stl"
        key = f"cases/{case_id}/designs/{design_id}/{name}"
        files.put(key, Path(path).read_bytes(), "model/stl")
        out["parts"][part] = {"preview_stl": key}
    if "c_clip" in out["parts"]:
        atts[0]["files"] = {"preview_stl": out["parts"]["c_clip"]["preview_stl"]}
    for a in atts[1:]:
        ex = (result.get("extra_clips") or {})[a["id"]]
        key = f"cases/{case_id}/designs/{design_id}/{stems[a['id']]}.preview.stl"
        files.put(key, Path(ex["file"]).read_bytes(), "model/stl")
        a["files"] = {"preview_stl": key}
    for i, path in enumerate(result.get("views") or []):
        name = Path(path).stem if Path(path).stem in ("front", "side", "top", "iso") else ("front", "side", "top", "iso")[i % 4]
        key = f"cases/{case_id}/designs/{design_id}/views/{name}.png"
        files.put(key, Path(path).read_bytes(), "image/png")
        out["views"][name] = key
    return out


COVER_PARTS = ("cover", "air_holes", "strap_slits", "rail")   # カバーのSTLの形を決める部品


def _reuse_parent_cover(case: dict, parent: dict | None, params: list[Param], result: dict, file_refs: dict) -> None:
    """カバーの入力が前の版と同じなら、カバーのプレビュー用STLを前の版の中身にする
    （OpenSCAD は同じ入力でも毎回少し違うSTLを出すため。ADR-0014 §4 カバーは前の版と同じ）。検査は描き直したもののまま"""
    old_key = ((parent or {}).get("files") or {}).get("parts", {}).get("cover", {}).get("preview_stl")
    new_ref = (file_refs.get("parts") or {}).get("cover")
    if not old_key or not new_ref or not result.get("cover_shell_sha256"):
        return
    if result["cover_shell_sha256"] != parent.get("cover_shell_sha256") \
            or case.get("measurement_id") != parent.get("hand_measurement_id"):
        return
    def cover_values(ps: list[Param]) -> dict:
        return {p.key(): p.value for p in ps if p.part_id in COVER_PARTS}
    if cover_values(params) != cover_values(validator.params_from_records(parent.get("params") or [])):
        return
    data = files.get(old_key)
    if data:
        files.put(new_ref["preview_stl"], data, "model/stl")


def _make(case: dict, params: list[Param], selected: list[str], workdir: str, quality: str = "preview",
          extra_clips: dict[str, dict] | None = None) -> dict:
    hm = case["hand_model"]
    glb = files.get(hm["mesh_path"])
    if glb is None:
        raise ApiError("NOT_FOUND", "手のメッシュが見つかりません。撮り直してください")
    try:
        # 左右は採寸したときの値を正とする（聞き取りで変えると、保存したメッシュを逆向きに正準化してしまうため。11/8）
        hand_side = (case.get("measurement") or {}).get("hand_side") or case["requirements"]["hand_side"]
        return _geometry().make_design(glb, hm["joints_mm"], hand_side,
                                       validator.to_dict(params), workdir,
                                       Cache(f"internal/cases/{case['_id']}/cover/{case.get('measurement_id')}"), quality=quality,
                                       parts=tuple(p for p in ("cover", "c_clip", "tpu_sleeve") if p in selected),
                                       extra_clips=extra_clips or None)
    except ApiError:
        raise
    except Exception as e:  # noqa: BLE001
        code = getattr(e, "code", None)
        if code:
            raise ApiError(code, getattr(e, "message_ja", None), getattr(e, "details", None))
        log.exception("make_design failed")
        raise ApiError("RENDER_FAILED")


def _render_safe(case: dict, params: list[Param], selected: list[str], workdir: str, clamped: list,
                 extra_clips: dict[str, dict] | None = None) -> tuple[dict, list[Param]]:
    """描いて、手のひら側・手首の安全の検査（R6c・R6d）に落ちたら、切る位置を動かして最大2回作り直す"""
    for attempt in range(3):
        res = _make(case, params, selected, workdir, extra_clips=extra_clips)
        bad = [v for v in res.get("violations", []) if v.get("rule") in SAFETY_RULES]
        if not bad or attempt == 2:
            return res, params
        for p in params:
            if p.key() == ("cover", "palm_cut_offset_mm") and any(v["rule"] == "R6c" for v in bad):
                clamped.append({"part_id": "cover", "name": p.name, "from": p.value, "to": p.value - 2, "rule": "R6c"})
                p.value, p.clamped = round(p.value - 2, 2), True
            if p.key() == ("cover", "wrist_cut_mm") and any(v["rule"] == "R6d" for v in bad):
                clamped.append({"part_id": "cover", "name": p.name, "from": p.value, "to": p.value + 5, "rule": "R6d"})
                p.value, p.clamped = round(p.value + 5, 2), True
    return res, params


def _render_attachments(case: dict, params: list[Param], selected: list[str], workdir: str, clamped: list,
                        extras: dict[str, dict]) -> tuple[dict, list[Param], list[str]]:
    """主なクリップとほかのクリップを描く。返り値は (result, params, 描けなかったほかのクリップのID)。
    主なクリップかカバーが描けなければ ApiError（RENDER_FAILED など）"""
    tmp: list = []
    try:
        res, ps = _render_safe(case, copy.deepcopy(params), selected, workdir, tmp, extras)
        clamped += tmp
        return res, ps, []
    except ApiError as e:
        if e.code != "RENDER_FAILED" or not extras:
            raise
    # どのクリップが描けないか分からないので、主なクリップだけで描き、ほかは1つずつ描く
    tmp = []
    res, ps = _render_safe(case, copy.deepcopy(params), selected, workdir, tmp)
    clamped += tmp
    res["extra_clips"], failed = {}, []
    for aid, cp in extras.items():
        try:
            res["extra_clips"][aid] = _make(case, ps, selected, workdir, extra_clips={aid: cp})["extra_clips"][aid]
        except ApiError as e:
            if e.code != "RENDER_FAILED":
                raise
            failed.append(aid)
    return res, ps, failed


def _clip_values(params: list[Param]) -> dict:
    return validator.to_dict(params).get("c_clip", {})


def _sync_primary(att: dict, params: list[Param]) -> None:
    """主な取り付け具の太さと角度を、今までの項目（params の c_clip）にそろえる"""
    for q in params:
        if q.part_id != "c_clip":
            continue
        if q.name == "tool_d_mm":
            att["tool_d_mm"] = q.value
        elif q.name == "angle_deg":
            att.update(angle_deg=q.value, angle_source=q.source, reason_ja=q.reason_ja or att.get("reason_ja", ""))


def _apply_angles(atts: list[dict], answers: list | None, clamped: list) -> None:
    """主でない取り付け具の角度を、寸法決めの答えから入れる（選択肢になければ道具の目安にして clamped に残す）"""
    choices = (validator.param_def("c_clip", "angle_deg") or {}).get("choices") or [60, 70, 80]
    by_id = {x.get("attachment_id"): x for x in answers or []}
    for a in atts:
        x = by_id.get(a["id"])
        if a["primary"] or not x:
            continue
        v = x.get("angle_deg")
        if isinstance(v, (int, float)) and float(v).is_integer():
            v = int(v)
        if v in choices:
            a.update(angle_deg=v, angle_source="ai", reason_ja=x.get("reason_ja", ""))
        else:
            to = ANGLE_BY_TOOL.get(a["tool_type"], 60)
            clamped.append({"part_id": "c_clip", "name": "angle_deg", "from": x.get("angle_deg"), "to": to, "rule": "R2",
                            "attachment_id": a["id"]})
            a.update(angle_deg=to, angle_source="rule")


def _check_attachments(params: list[Param], atts: list[dict], selected: list[str], hand: dict, req: dict,
                       overrides: set) -> tuple[dict[str, list[Param]], dict[str, list], list]:
    """主でない取り付け具ごとの範囲チェック（R1〜R5）。返り値は ({ID: その取り付け具の params}, {落ちたID: 違反}, clamped)"""
    ok, bad, clamped = {}, {}, []
    for a in atts[1:]:
        r = validator.check(attachment_params(params, a), selected_parts=selected, hand=hand,
                            requirements={**req, "tool_shaft_shape": "round", "tool_d_mm": a["tool_d_mm"]},
                            user_override_keys=overrides)
        if r.fatal:
            bad[a["id"]] = r.violations
            continue
        ok[a["id"]] = r.params
        clamped += [{**c, "attachment_id": a["id"]} for c in r.clamped if c.get("part_id") == "c_clip"]
    return ok, bad, clamped


def _attachments_of(design: dict, requirements: dict) -> list[dict]:
    """版の取り付け具。今までの版にはないので、params と要求の今までの項目から主な取り付け具を1つ作る
    （ID と tool_index は、要求の道具の一覧の最初の丸い柄の位置）"""
    if design.get("attachments"):
        return copy.deepcopy(design["attachments"])
    tools = stored_tools(requirements)
    i = primary_index(tools) or 0
    legacy = {k: requirements.get(k) for k in ("activity", "tool_type", "tool_d_mm", "tool_d_source", "tool_shaft_size")}
    atts, _ = build_attachments({"tools": [{**legacy, "tool_shaft_shape": "round"}]})
    atts[0].update(id=f"a{i + 1}", tool_index=i)
    _sync_primary(atts[0], validator.params_from_records(design.get("params") or []))
    return atts


def _refine_attachment(params: list[Param], att: dict, changes: list[dict], *, source: str, override: bool,
                       selected: list[str], hand: dict, req: dict, overrides: set, clamped: list) -> None:
    """主でない取り付け具に c_clip の変更を当てる。この取り付け具の一覧（attachment_params）で範囲チェックをかけ、
    角度だけを取り付け具に書き戻す（太さは聞き取りが決める値なので、ここでは変えない）"""
    ap, changed = validator.merge_changes(attachment_params(params, att), changes, source=source, override_by_user=override)
    r = validator.check(ap, selected_parts=selected, hand=hand,
                        requirements={**req, "tool_shaft_shape": "round", "tool_d_mm": att["tool_d_mm"]},
                        user_override_keys=overrides | (set(changed) if override else set()))
    clamped += [{**c, "attachment_id": att["id"]} for c in r.clamped if c.get("part_id") == "c_clip"]
    q = next((p for p in r.params if p.key() == ("c_clip", "angle_deg")), None)
    if r.fatal or q is None or q.clamped or q.value == att["angle_deg"]:
        return
    att.update(angle_deg=q.value, angle_source=q.source, reason_ja=q.reason_ja or "")


def _split_clip(changes: list[dict]) -> tuple[list[dict], list[dict]]:
    """(c_clip の変更, それ以外の変更)"""
    clip = [c for c in changes if c.get("part_id") == "c_clip"]
    return clip, [c for c in changes if c.get("part_id") != "c_clip"]


def _review_passed(r: dict) -> bool:
    ok_checks = len(r.get("checks", [])) == 5 and all(c.get("pass") for c in r["checks"])
    serious = [i for i in r.get("issues", []) if i.get("severity") in ("high", "medium")]
    return r.get("verdict") == "ok" and ok_checks and not serious and not r.get("changes")


def run(case_id: str, *, origin: str = "initial", parent: dict | None = None, style: dict | None = None,
        instruction: str | None = None, param_changes: list[dict] | None = None, clip_angle: int | None = None,
        attachment_id: str | None = None, add_attachment: dict | None = None, tool_d: float | None = None) -> dict:
    """1つの版を作る。呼ぶ前に権限と回数の確認（足すときは数・平たい柄・太さの範囲も）を済ませておくこと。
    attachment_id は直す取り付け具（なければ主な取り付け具）"""
    ops.require_generation_enabled()
    case = db.get(f"cases/{case_id}")
    if not case or not case.get("hand_model"):
        raise ApiError("CONFLICT", "先に採寸を保存してください")
    case["_id"] = case_id
    prev_status = case.get("status")
    design_id = "d_" + uuid.uuid4().hex[:8]
    kind = "design" if origin == "initial" else "refine"
    op_id = ops.begin(case_id, kind, design_id)
    deadline = Deadline(settings.request_timeout_s)
    usage = gemini.Usage()
    revision = (parent or {}).get("revision", 0) + 1 if parent else 1
    base = {"revision": revision, "parent_design_id": (parent or {}).get("design_id"), "origin": origin,
            "status": "running", "style": style or (parent or {}).get("style") or {"color": "#2A9D8F", "pattern": "none"},
            "approval": {"status": "none"}, "created_at": now(), "warnings": [],
            "model": {"id": settings.gemini_model, "location": settings.gemini_location},
            "prompt_versions": gemini.PROMPT_VERSIONS}
    db.set(f"cases/{case_id}/designs/{design_id}", base)
    db.update(f"cases/{case_id}", {"current_design_id": design_id, "status": "designing"})
    workdir = tempfile.mkdtemp(prefix="jijogu_")
    try:
        req = case["requirements"]
        hand = hand_summary(case)
        baseline = {(b["part_id"], b["name"]): Param(b["part_id"], b["name"], b["value"], b.get("source", "default"), "", b["value"])
                    for b in case.get("baseline", [])}
        req_d = req.get("tool_d_mm")   # 道具の太さは今の要求（主な道具）の値を正にする（採寸のあとで直した太さも。measurement.py と同じ）
        if req_d and ("c_clip", "tool_d_mm") in baseline:
            baseline[("c_clip", "tool_d_mm")] = Param("c_clip", "tool_d_mm", req_d, "interview", "", req_d)
        clamped: list = []
        review_rounds: list = []
        summary_ja = ""
        overrides: set = set()
        notes: list = []   # 取り付け具の知らせ（平たい柄・作れなかったクリップ）。画像での確認のあとで unresolved に足す
        strict: set = set()   # 落ちたら外さずにエラーにする取り付け具（足す取り付け具。ADR-0014 §4 足すのに失敗したとき）
        new_req = None        # 成功したらケースに保存する要求（足す・太さの直し）

        if origin == "initial":
            # 取り付け具（道具ごとのクリップ）。平たい柄は作らずに知らせる（ADR-0014 §1）
            atts, skipped = build_attachments(req)
            notes += [{"severity": "medium", "description_ja": x["reason_ja"]} for x in skipped]
            others = [{"attachment_id": a["id"], "tool_type": a["tool_type"], "activity": a["activity"],
                       "tool_d_mm": a["tool_d_mm"]} for a in atts if not a["primary"]]
            _progress(case_id, design_id, "selecting", "部品を選んでいます")
            sel = gemini.select(req, hand, _catalog_summary(), usage)
            parts = sel["parts"]
            selected = [p["part_id"] for p in parts]
            for need in validator.REQUIRED_PARTS:  # 必須の部品が抜けていたら足す（R1）
                if need not in selected:
                    parts.append({"part_id": need, "variant": "standard", "reason_ja": "必須の部品です"})
                    selected.append(need)
            deadline.check()
            _progress(case_id, design_id, "dimensioning", "寸法を決めています")
            defs = _param_defs_for_prompt(selected, baseline)
            params = [p for k, p in baseline.items() if k[0] in selected]
            def apply_dim(dim):
                ps = [p for k, p in baseline.items() if k[0] in selected]
                ps, _ = validator.merge_changes(ps, [c for c in dim["params"]], source="ai")
                for p in ps:  # Gemini が書いた source と理由を残す（聞き直したあとも。前は2回目で抜けていた）
                    g = next((c for c in dim["params"] if (c["part_id"], c["name"]) == p.key()), None)
                    if g:
                        p.source, p.reason_ja = g.get("source", p.source), g.get("reason_ja", "")
                return ps

            dim = gemini.dimension(req, hand, parts, defs, None, usage, attachments=others)
            params = apply_dim(dim)
            res = validator.check(params, selected_parts=selected, hand=hand, requirements=req, allow_clamp=False)
            if res.violations and res.fatal != "AI_OUTPUT_INVALID":  # 1回だけ聞き直す（R2〜R4）
                dim = gemini.dimension(req, hand, parts, defs, res.violations, usage, attachments=others)
                params = apply_dim(dim)
            summary_ja = dim.get("summary_ja", "")
            _apply_angles(atts, dim.get("attachments"), clamped)
        else:
            atts = _attachments_of(parent, req)
            target = next((a for a in atts if a["id"] == attachment_id), atts[0])
            on_extra = not target["primary"]   # 主でない取り付け具を直す（c_clip の値はその取り付け具にだけ効かせる）
            parts = parent["parts"]
            selected = [p["part_id"] for p in parts]
            params = validator.params_from_records(parent["params"])
            tools = [dict(t) for t in stored_tools(req)]
            if instruction or param_changes:
                if instruction:
                    sent = attachment_params(params, target) if on_extra else params
                    rf = gemini.refine(req, validator.param_records(sent), instruction, usage)
                    if rf.get("clarify_ja"):
                        db.delete(f"cases/{case_id}/designs/{design_id}")
                        db.update(f"cases/{case_id}", {"current_design_id": parent["design_id"], "status": "previewing"})
                        return {"clarify_ja": rf["clarify_ja"]}
                    changes, src, ov = rf["changes"], "ai", bool(rf.get("override_by_user"))
                    summary_ja = rf.get("message_ja", "")
                else:
                    changes, src, ov = param_changes, "user", True
                clip_ch, rest = _split_clip(changes) if on_extra else ([], changes)
                params, changed = validator.merge_changes(params, rest, source=src, override_by_user=ov)
                if ov:
                    overrides |= set(changed)
                if clip_ch:
                    _refine_attachment(params, target, clip_ch, source=src, override=ov, selected=selected, hand=hand,
                                       req=req, overrides=overrides, clamped=clamped)
            elif clip_angle is not None:
                if on_extra:
                    target.update(angle_deg=clip_angle, angle_source="user", reason_ja="画面で角度を選びました")
                else:
                    params, _ = validator.merge_changes(params, [{"part_id": "c_clip", "name": "angle_deg", "value": clip_angle,
                                                                  "reason_ja": "画面で角度を選びました"}], source="user")
            elif tool_d is not None:
                # 太さの直し：その取り付け具と要求の道具を直す。主なら要求の今までの項目と params の c_clip（値と基準値）も
                target.update(tool_d_mm=tool_d, tool_d_source="user")
                if not on_extra:
                    for q in params:
                        if q.key() == ("c_clip", "tool_d_mm"):
                            q.value = q.baseline = tool_d
                            q.source, q.reason_ja, q.clamped = "user", "画面で太さを直しました", False
                i = target.get("tool_index", 0)
                if i < len(tools):
                    tools[i] = normalize_tool({**tools[i], "tool_d_mm": tool_d})
                new_req = {**req, "tools": tools, "assumptions": requirement_assumptions(tools)}
                if not on_extra:
                    new_req.update(tool_d_mm=tool_d, tool_d_source="user")
            elif add_attachment is not None:
                # 足す：要求の道具の一覧の最後に足す。角度だけ Gemini が選ぶ（選択肢になければ道具の目安）
                tool = normalize_tool(add_attachment)
                new, _ = build_attachments({"tools": [tool]})
                new = new[0]
                new.update(id=next_attachment_id(atts), tool_index=len(tools), primary=False)
                ans = gemini.attachment_angle(req, hand, {"attachment_id": new["id"], "tool_type": new["tool_type"],
                                                          "activity": new["activity"], "tool_d_mm": new["tool_d_mm"]}, usage)
                _apply_angles([new], [{"attachment_id": new["id"], **ans}], clamped)
                atts.append(new)
                strict.add(new["id"])
                tools.append(tool)
                new_req = {**req, "tools": tools, "assumptions": requirement_assumptions(tools)}
        res = validator.check(params, selected_parts=selected, hand=hand, requirements=req, user_override_keys=overrides)
        clamped += res.clamped
        if res.fatal:
            raise ApiError(res.fatal, details=res.violations)
        if not atts:
            raise ApiError("DESIGN_INFEASIBLE", details=[{"rule": "R4", "message": "平たい柄は、いまのC字クリップでは挟めません"}])
        params = res.params
        _sync_primary(atts[0], params)
        labels = {a["id"]: attachment_label(a, atts) for a in atts}   # 外す前の一覧で名前をつける（同じ道具なら太さも）

        def drop(a: dict, why: str, code: str = "RENDER_FAILED", details: list | None = None) -> None:
            """この取り付け具だけ版から外して知らせる（ADR-0014 §3 取り付け具だけが落ちたとき）。
            足す取り付け具は外さずにエラーにする（details に検査の名前。ADR-0014 §4）"""
            if a["id"] in strict:
                raise ApiError(code, f"{labels[a['id']]}のクリップは作れませんでした（{why}）", details=details or [])
            atts.remove(a)
            notes.append({"severity": "medium", "description_ja": f"{labels[a['id']]}のクリップは作れませんでした（{why}）"})

        att_params, bad, cl = _check_attachments(params, atts, selected, hand, req, overrides)
        clamped += cl
        for a in [a for a in atts if a["id"] in bad]:
            drop(a, "寸法の決まりに合いませんでした", "DESIGN_INFEASIBLE", [{**v, "attachment_id": a["id"]} for v in bad[a["id"]]])
        for a in atts[1:]:
            cv = _clip_values(att_params[a["id"]])
            a["tool_d_mm"], a["angle_deg"] = cv.get("tool_d_mm", a["tool_d_mm"]), cv.get("angle_deg", a["angle_deg"])
        deadline.check()

        _progress(case_id, design_id, "shelling", "カバーの形を作っています")
        while True:
            extras = {a["id"]: _clip_values(att_params[a["id"]]) for a in atts[1:]}
            why = None
            try:
                result, rendered, failed = _render_attachments(case, params, selected, workdir, clamped, extras)
            except ApiError as e:
                if e.code != "RENDER_FAILED" or len(atts) == 1 or strict:   # 足すときは主を繰り上げない
                    raise
                why = "形を描けませんでした"
            if why is None:
                params = rendered
                for a in list(atts[1:]):
                    ex = (result.get("extra_clips") or {}).get(a["id"])
                    if a["id"] in failed or ex is None:
                        drop(a, "形を描けませんでした",
                             details=[{"rule": "render", "attachment_id": a["id"], "message": "形を描けませんでした"}])
                    elif ex.get("violations"):
                        drop(a, "、".join(v.get("message_ja") or v.get("rule") for v in ex["violations"]),
                             details=[{**v, "attachment_id": a["id"]} for v in ex["violations"]])
                bad_clip = [v for v in result.get("violations", []) if str(v.get("rule", "")).startswith("R6f")]
                if not bad_clip or len(atts) == 1 or strict:
                    break   # 取り付け具が1つ（または足すとき）なら、今までどおり（R6f は下で needs_attention にする）
                why = "、".join(v.get("message_ja") or v.get("rule") for v in bad_clip)
            # 主なクリップが落ちたので、次の取り付け具を主に繰り上げ、今までの項目（params の c_clip）をうめ直す
            drop(atts[0], why)
            atts[0]["primary"] = True
            nxt = {q.name: q for q in att_params.pop(atts[0]["id"]) if q.part_id == "c_clip"}
            params = [copy.deepcopy(nxt.get(q.name, q)) if q.part_id == "c_clip" else q for q in params]
            for q in params:   # 角度の出どころと理由は、繰り上げた取り付け具のもの
                if q.key() == ("c_clip", "angle_deg"):
                    q.source, q.reason_ja = atts[0].get("angle_source") or q.source, atts[0].get("reason_ja", "")
            deadline.check()
        _sync_primary(atts[0], params)
        deadline.check()
        angle = _clip_values(params).get("angle_deg", 70)
        file_refs = _upload_preview(case_id, design_id, result, atts)
        multi = len(atts) > 1
        status = "ready"
        warnings = sorted(set((case.get("hand_model") or {}).get("warnings", [])))
        unresolved: list = []
        if [v for v in result.get("violations", []) if v.get("rule") in SAFETY_RULES]:
            status = "needs_attention"
            unresolved.append({"severity": "high", "description_ja": "手のひら側か手首を覆うおそれがあります。印刷用のデータは作れません"})
        other = [v for v in result.get("violations", []) if v.get("rule") not in SAFETY_RULES]
        if other:
            # R6a/R6b/R6e/R6f の不合格（閉じていない・分かれている・手に近い・クリップの開き）。印刷用は RENDER_FAILED になるので先に知らせる
            status = "needs_attention"
            unresolved.append({"severity": "high", "description_ja": "形の検査に通らない所があります（"
                               + "、".join(v.get("message_ja") or v.get("rule") for v in other) + "）。印刷用のデータは作れません"})
        r6h = [(atts[0], result.get("checks", []))] + [(a, result["extra_clips"][a["id"]].get("checks", [])) for a in atts[1:]]
        for a, checks in r6h:
            if [c for c in checks if c.get("rule") == "R6h" and not c.get("ok")]:
                # 道具が手やカバーに当たる、または机に届かない（11/8 の設計変更の核心なので、黙って ready にしない）
                status = "needs_attention"
                if multi:   # どの道具のクリップかを書く
                    msg = f"{labels[a['id']]}が手やカバーに当たるか、先が机に届きません。{labels[a['id']]}のクリップの角度を立ててみてください"
                else:
                    msg = "道具（ペン・筆）が手やカバーに当たるか、先が机に届きません。クリップの角度を立ててみてください"
                unresolved.append({"severity": "medium", "description_ja": msg})
        if [c for c in result.get("checks", []) if c.get("rule") in ("R6e_slits", "R6e_slit_open") and not c.get("ok")]:
            # ベルトを通せないカバーは使えないので、OTに見せる（側面が低い手の形で起きる。11/8）
            status = "needs_attention"
            unresolved.append({"severity": "medium", "description_ja": "ベルトのスリットを置けない所、またはふさがれている所があります（カバーの側面が低いため）。"
                               "ベルトの幅を狭くするか、OTに相談してください"})

        # 画像での確認（最初は最大3回、言葉の微調整は1回、数値・角度だけの変更は確認しない）
        max_rounds = MAX_ROUNDS if origin == "initial" else (1 if instruction else 0)
        last_values = {}
        for rnd in range(1, max_rounds + 1):
            if status != "ready":
                break
            if deadline.left() < 100:  # 確認1回（最大90秒）と描き直しの時間が残っていなければ、ここで止める
                status = "needs_attention"
                unresolved.append({"severity": "medium", "description_ja": "時間が足りず、AIによる画像の確認を最後までできませんでした（形と安全の検査は通っています）"})
                break
            _progress(case_id, design_id, "reviewing", f"できた形を確かめています（{rnd}/{max_rounds}回目）", rnd)
            imgs = [Path(p).read_bytes() for p in result.get("views", [])]
            try:
                rv = gemini.review(imgs, req, hand, validator.param_records(params), review_rounds, rnd, usage)
            except ApiError as e:
                if e.code not in ("AI_UNAVAILABLE", "AI_OUTPUT_INVALID"):
                    raise
                # AIが混んでいて確認できなくても、形と安全の検査は決まった計算で通っているので、生成は失敗にしない
                status = "needs_attention"
                unresolved.append({"severity": "medium", "description_ja": "AIが混んでいて、画像の確認ができませんでした（形と安全の検査は通っています）。必要なら作り直してください"})
                break
            review_rounds.append({"round": rnd, "verdict": rv["verdict"], "checks": rv.get("checks", []),
                                  "issues": rv.get("issues", []), "changes": rv.get("changes", [])})
            if _review_passed(rv):
                break
            if rv["verdict"] == "ok" or not rv.get("changes") or rnd == max_rounds:
                status = "needs_attention"
                unresolved += [i for i in rv.get("issues", []) if i.get("severity") in ("high", "medium")] or \
                    [{"severity": "medium", "description_ja": "AIは修正が必要と判定しましたが、修正案を出せませんでした"}]
                break
            prev = {p.key(): p.value for p in params}
            new_params, changed = validator.merge_changes(params, rv["changes"], source="ai")
            if any(last_values.get(k) == dict((q.key(), q.value) for q in new_params).get(k) for k in changed):
                status = "needs_attention"  # 行ったり来たりを防ぐ
                unresolved += rv.get("issues", [])
                break
            last_values.update(prev)
            res2 = validator.check(new_params, selected_parts=selected, hand=hand, requirements=req, user_override_keys=overrides)
            ap2, bad2, cl2 = _check_attachments(res2.params, atts, selected, hand, req, overrides) if not res2.fatal else ({}, [], [])
            if res2.fatal or bad2:
                status = "needs_attention"
                unresolved.append({"severity": "medium", "description_ja": "AIの直し方が決まりに合わなかったので、前の形のままにしました"})
                break
            deadline.check()
            _progress(case_id, design_id, "rendering", "直した形を作っています", rnd)
            try:
                r2, p2 = _render_safe(case, res2.params, selected, workdir, clamped,
                                      {a["id"]: _clip_values(ap2[a["id"]]) for a in atts[1:]})
            except ApiError as e:
                if e.code != "RENDER_FAILED" or len(atts) == 1:
                    raise
                r2 = None
            if r2 is not None and [v for v in r2.get("violations", []) if v.get("rule") in SAFETY_RULES]:
                status = "needs_attention"
                unresolved.append({"severity": "high", "description_ja": "直した形が安全の検査に通らなかったので、前の形のままにしました"})
                break
            if r2 is None or any(not (r2.get("extra_clips") or {}).get(a["id"]) or r2["extra_clips"][a["id"]].get("violations")
                                 for a in atts[1:]):
                # 取り付け具が複数のとき：直した形でどれかのクリップを描けない・検査に通らないなら、前の形にとどめる
                status = "needs_attention"
                unresolved.append({"severity": "medium", "description_ja": "直した形では、道具ごとのクリップが描けないか検査に通らなかったので、前の形のままにしました"})
                break
            result, params = r2, p2
            clamped += res2.clamped + cl2
            _sync_primary(atts[0], params)
            angle = _clip_values(params).get("angle_deg", 70)
            file_refs = _upload_preview(case_id, design_id, result, atts)

        if notes:   # 作らなかった・作れなかった取り付け具を知らせる（形の確認とは別なので、画像での確認のあとで足す）
            status = "needs_attention"
            unresolved += notes
        for a in atts:
            a["print_key"] = print_key(a)
            src = result if a["primary"] else result["extra_clips"][a["id"]]
            checks = src.get("checks", [])
            if a["primary"]:
                checks = [c for c in checks if str(c.get("rule", "")).startswith(("R6f", "R6h"))]
            a.update(tool=src.get("tool"), clip=src.get("clip"), checks=checks)

        if origin != "initial":
            _reuse_parent_cover(case, parent, params, result, file_refs)
        if not ops.is_mine(case_id, op_id):
            return {"design": {"design_id": design_id, "status": "failed"}}
        if new_req is not None:   # 足した道具・直した太さを聞き取りの記録に残す（次に作り直したときも同じクリップにする）
            db.update(f"cases/{case_id}", {"requirements": {**new_req, "__replace__": True}, "updated_at": now()})
        final = {
            "status": status, "parts": parts, "params": validator.param_records(params),
            "review": {"rounds": review_rounds, "final_verdict": "ok" if status == "ready" else "revise",
                       "unresolved_issues": unresolved},
            "warnings": warnings, "clamped": clamped, "files": file_refs,
            "hand_overlay": {"mesh_path": case["hand_model"]["mesh_path"], "frame": "hand"},
            "hand_measurement_id": case.get("measurement_id"),
            "scale_factor": case["hand_model"].get("scale_factor"),
            "hand_clearance_mm": validator.fixed("HAND_CLEARANCE_MM", 1.5),
            "cover_shell_sha256": result.get("cover_shell_sha256"),
            "clip_angle_deg": angle, "clip": result.get("clip"), "tool": result.get("tool"), "checks": result.get("checks", []),
            "attachments": atts,
            "summary_ja": summary_ja or "こぶしの外側に沿うカバーと、道具の太さに合わせたクリップにしました。手のひら側と手首は開けてあります。",
            "input_snapshot": {"requirements": new_req or req, "measurement_id": case.get("measurement_id"),
                               "hand_model": case.get("hand_model")},
            "usage": {**usage.as_dict(), "openscad_ms": (result.get("timings_ms") or {}).get("openscad", 0)},
            "progress": {"step": "done", "round": len(review_rounds), "max_rounds": MAX_ROUNDS, "message_ja": "できました"},
        }
        db.update(f"cases/{case_id}/designs/{design_id}", final)
        db.update(f"cases/{case_id}", {"status": "previewing"})
        return {"design": design_view(case_id, design_id)}
    except ApiError as e:
        if not _discard_added(case_id, design_id, origin, parent, prev_status):
            db.update(f"cases/{case_id}/designs/{design_id}", {"status": "failed", "error": {"code": e.code, "message": e.message}})
            db.update(f"cases/{case_id}", {"status": "previewing" if parent else "designing",
                                           "current_design_id": (parent or {}).get("design_id") or design_id})
        raise
    except Exception:  # noqa: BLE001 - 予期しない例外（Gemini の答えの欠け、数値の例外など）でも版を「処理中」のまま残さない
        log.exception("design run failed")
        if not _discard_added(case_id, design_id, origin, parent, prev_status):
            db.update(f"cases/{case_id}/designs/{design_id}",
                      {"status": "failed", "error": {"code": "INTERNAL", "message": "形を作る途中で止まりました。もう一度作ってください"}})
            db.update(f"cases/{case_id}", {"status": "previewing" if parent else "designing",
                                           "current_design_id": (parent or {}).get("design_id") or design_id})
        raise ApiError("INTERNAL")
    finally:
        ops.end(case_id, op_id)
        if usage.calls and settings.gemini_mode == "live":
            ops.add_gemini_cost(usage.as_dict())
        shutil.rmtree(workdir, ignore_errors=True)


def _discard_added(case_id: str, design_id: str, origin: str, parent: dict | None, prev_status: str | None) -> bool:
    """足すのに失敗したら、作りかけの版を消して、ケースを前の版・前の状態に戻す（ADR-0014 §4。
    要求の道具は成功したときだけ足すので戻さなくてよい）"""
    if origin != "refine_add_attachment" or not parent:
        return False
    files.delete_prefix(f"cases/{case_id}/designs/{design_id}/")
    db.delete(f"cases/{case_id}/designs/{design_id}")
    db.update(f"cases/{case_id}", {"current_design_id": parent["design_id"], "status": prev_status or "previewing"})
    return True


def design_view(case_id: str, design_id: str) -> dict:
    d = db.get(f"cases/{case_id}/designs/{design_id}") or {}
    keep = ("revision", "status", "parts", "params", "review", "warnings", "hand_overlay", "files", "approval",
            "summary_ja", "progress", "style", "clip_angle_deg", "clip", "tool", "error", "clamped", "geometry_hash", "origin",
            "parent_design_id", "print_prepared_at", "attachments")
    return {"design_id": design_id, **{k: d.get(k) for k in keep if k in d}}


def prepare_print(case_id: str, design_id: str, kind: str) -> dict:
    """部品ごとの印刷用STL（review_request / prepare_print）。引数は変えず、R6 に落ちたら RENDER_FAILED"""
    case = db.get(f"cases/{case_id}")
    case["_id"] = case_id
    d = db.get(f"cases/{case_id}/designs/{design_id}")
    params = validator.params_from_records(d["params"])
    selected = [p["part_id"] for p in d["parts"]]
    atts = _attachments_of(d, case.get("requirements") or {})
    stems = clip_stems(atts)
    extras = {a["id"]: {"tool_d_mm": a["tool_d_mm"], "angle_deg": a["angle_deg"]} for a in atts[1:]}
    workdir = tempfile.mkdtemp(prefix="jijogu_print_")
    try:
        res = _make(case, params, selected, workdir, quality="print", extra_clips=extras)
        viol = list(res.get("violations") or [])
        for aid, ex in (res.get("extra_clips") or {}).items():
            viol += [{**v, "attachment_id": aid} for v in ex.get("violations") or []]
        if viol:
            raise ApiError("RENDER_FAILED", details=viol)
        srcs = {}   # 印刷用のキー → (名前, ファイル)
        for part, path in res["files"].items():
            if part == "c_clip":
                srcs[atts[0].get("print_key") or print_key(atts[0])] = (f"{stems[atts[0]['id']]}.stl", path)
            else:
                srcs[part] = (f"{part}.stl", path)
        for a in atts[1:]:
            srcs[a.get("print_key") or print_key(a)] = (f"{stems[a['id']]}.stl", res["extra_clips"][a["id"]]["file"])
        shas, keys = {}, {}
        for pk, (name, path) in srcs.items():
            key = f"internal/cases/{case_id}/designs/{design_id}/print/{name}"
            data = Path(path).read_bytes()
            files.put(key, data, "model/stl")
            shas[pk] = hashlib.sha256(data).hexdigest()
            keys[pk] = key
        return {"print_sha256": shas, "internal_keys": keys,
                "geometry_hash": geometry_hash(selected, params, d.get("cover_shell_sha256"), atts)}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def publish_print(case_id: str, design_id: str, internal_keys: dict, shas: dict) -> dict:
    """internal/ の印刷用STLのハッシュを確かめて、読める場所（print/）にコピーする"""
    out = {}
    for part, key in internal_keys.items():
        data = files.get(key)
        if data is None or hashlib.sha256(data).hexdigest() != shas.get(part):
            raise ApiError("STALE_DESIGN", "印刷用のデータが確認したものと違います")
        dst = key.replace("internal/", "", 1)
        files.put(dst, data, "model/stl")
        out[part] = dst
    return out
