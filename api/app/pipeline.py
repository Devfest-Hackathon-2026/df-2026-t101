"""形を作る流れ（docs/generation-pipeline.md §1・§4・§5、api.md §3.4〜§3.6・§3.11）。
部品選び → 寸法決め → 範囲チェック → 殻と描画（geometry）→ 描いたあとの検査 → 画像での確認（最大3回）。"""
from __future__ import annotations

import hashlib
import json
import logging
import shutil
import tempfile
import time
import uuid
from pathlib import Path

from . import gemini, ops, validator
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


def geometry_hash(parts: list[str], params: list[Param], shell_sha: str | None) -> str:
    body = {"parts": sorted(parts), "params": sorted([[p.part_id, p.name, p.value] for p in params]),
            "cover_shell_sha256": shell_sha, "catalog_version": validator.catalog().get("version")}
    return "sha256:" + hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _upload_preview(case_id: str, design_id: str, result: dict, angle) -> dict:
    out = {"parts": {}, "views": {}}
    for part, path in (result.get("files") or {}).items():
        name = f"c_clip_{int(angle)}.preview.stl" if part == "c_clip" else f"{part}.preview.stl"
        key = f"cases/{case_id}/designs/{design_id}/{name}"
        files.put(key, Path(path).read_bytes(), "model/stl")
        out["parts"][part] = {"preview_stl": key}
    for i, path in enumerate(result.get("views") or []):
        name = Path(path).stem if Path(path).stem in ("front", "side", "top", "iso") else ("front", "side", "top", "iso")[i % 4]
        key = f"cases/{case_id}/designs/{design_id}/views/{name}.png"
        files.put(key, Path(path).read_bytes(), "image/png")
        out["views"][name] = key
    return out


def _make(case: dict, params: list[Param], selected: list[str], workdir: str, quality: str = "preview") -> dict:
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
                                       parts=tuple(p for p in ("cover", "c_clip", "tpu_sleeve") if p in selected))
    except ApiError:
        raise
    except Exception as e:  # noqa: BLE001
        code = getattr(e, "code", None)
        if code:
            raise ApiError(code, getattr(e, "message_ja", None), getattr(e, "details", None))
        log.exception("make_design failed")
        raise ApiError("RENDER_FAILED")


def _render_safe(case: dict, params: list[Param], selected: list[str], workdir: str, clamped: list) -> tuple[dict, list[Param]]:
    """描いて、手のひら側・手首の安全の検査（R6c・R6d）に落ちたら、切る位置を動かして最大2回作り直す"""
    for attempt in range(3):
        res = _make(case, params, selected, workdir)
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


def _review_passed(r: dict) -> bool:
    ok_checks = len(r.get("checks", [])) == 5 and all(c.get("pass") for c in r["checks"])
    serious = [i for i in r.get("issues", []) if i.get("severity") in ("high", "medium")]
    return r.get("verdict") == "ok" and ok_checks and not serious and not r.get("changes")


def run(case_id: str, *, origin: str = "initial", parent: dict | None = None, style: dict | None = None,
        instruction: str | None = None, param_changes: list[dict] | None = None, clip_angle: int | None = None) -> dict:
    """1つの版を作る。呼ぶ前に権限と回数の確認を済ませておくこと"""
    ops.require_generation_enabled()
    case = db.get(f"cases/{case_id}")
    if not case or not case.get("hand_model"):
        raise ApiError("CONFLICT", "先に採寸を保存してください")
    case["_id"] = case_id
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
        clamped: list = []
        review_rounds: list = []
        summary_ja = ""
        overrides: set = set()

        if origin == "initial":
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

            dim = gemini.dimension(req, hand, parts, defs, None, usage)
            params = apply_dim(dim)
            res = validator.check(params, selected_parts=selected, hand=hand, requirements=req, allow_clamp=False)
            if res.violations and res.fatal != "AI_OUTPUT_INVALID":  # 1回だけ聞き直す（R2〜R4）
                dim = gemini.dimension(req, hand, parts, defs, res.violations, usage)
                params = apply_dim(dim)
            summary_ja = dim.get("summary_ja", "")
        else:
            parts = parent["parts"]
            selected = [p["part_id"] for p in parts]
            params = validator.params_from_records(parent["params"])
            if instruction:
                rf = gemini.refine(req, validator.param_records(params), instruction, usage)
                if rf.get("clarify_ja"):
                    db.delete(f"cases/{case_id}/designs/{design_id}")
                    db.update(f"cases/{case_id}", {"current_design_id": parent["design_id"], "status": "previewing"})
                    return {"clarify_ja": rf["clarify_ja"]}
                ov = bool(rf.get("override_by_user"))
                params, changed = validator.merge_changes(params, rf["changes"], source="ai", override_by_user=ov)
                if ov:
                    overrides |= set(changed)
                summary_ja = rf.get("message_ja", "")
            elif param_changes:
                params, changed = validator.merge_changes(params, param_changes, source="user", override_by_user=True)
                overrides |= set(changed)
            elif clip_angle is not None:
                params, _ = validator.merge_changes(params, [{"part_id": "c_clip", "name": "angle_deg", "value": clip_angle,
                                                              "reason_ja": "画面で角度を選びました"}], source="user")
        res = validator.check(params, selected_parts=selected, hand=hand, requirements=req, user_override_keys=overrides)
        clamped += res.clamped
        if res.fatal:
            raise ApiError(res.fatal, details=res.violations)
        params = res.params
        deadline.check()

        _progress(case_id, design_id, "shelling", "カバーの形を作っています")
        result, params = _render_safe(case, params, selected, workdir, clamped)
        deadline.check()
        angle = validator.to_dict(params).get("c_clip", {}).get("angle_deg", 70)
        file_refs = _upload_preview(case_id, design_id, result, angle)
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
        if [c for c in result.get("checks", []) if c.get("rule") == "R6h" and not c.get("ok")]:
            # 道具が手やカバーに当たる、または机に届かない（11/8 の設計変更の核心なので、黙って ready にしない）
            status = "needs_attention"
            unresolved.append({"severity": "medium", "description_ja": "道具（ペン・筆）が手やカバーに当たるか、先が机に届きません。"
                               "クリップの角度を立ててみてください"})
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
            if res2.fatal:
                status = "needs_attention"
                unresolved.append({"severity": "medium", "description_ja": "AIの直し方が決まりに合わなかったので、前の形のままにしました"})
                break
            deadline.check()
            _progress(case_id, design_id, "rendering", "直した形を作っています", rnd)
            r2, p2 = _render_safe(case, res2.params, selected, workdir, clamped)
            if [v for v in r2.get("violations", []) if v.get("rule") in SAFETY_RULES]:
                status = "needs_attention"
                unresolved.append({"severity": "high", "description_ja": "直した形が安全の検査に通らなかったので、前の形のままにしました"})
                break
            result, params = r2, p2
            clamped += res2.clamped
            angle = validator.to_dict(params).get("c_clip", {}).get("angle_deg", 70)
            file_refs = _upload_preview(case_id, design_id, result, angle)

        if not ops.is_mine(case_id, op_id):
            return {"design": {"design_id": design_id, "status": "failed"}}
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
            "summary_ja": summary_ja or "こぶしの外側に沿うカバーと、道具の太さに合わせたクリップにしました。手のひら側と手首は開けてあります。",
            "input_snapshot": {"requirements": req, "measurement_id": case.get("measurement_id"),
                               "hand_model": case.get("hand_model")},
            "usage": {**usage.as_dict(), "openscad_ms": (result.get("timings_ms") or {}).get("openscad", 0)},
            "progress": {"step": "done", "round": len(review_rounds), "max_rounds": MAX_ROUNDS, "message_ja": "できました"},
        }
        db.update(f"cases/{case_id}/designs/{design_id}", final)
        db.update(f"cases/{case_id}", {"status": "previewing"})
        return {"design": design_view(case_id, design_id)}
    except ApiError as e:
        db.update(f"cases/{case_id}/designs/{design_id}", {"status": "failed", "error": {"code": e.code, "message": e.message}})
        db.update(f"cases/{case_id}", {"status": "previewing" if parent else "designing",
                                       "current_design_id": (parent or {}).get("design_id") or design_id})
        raise
    except Exception:  # noqa: BLE001 - 予期しない例外（Gemini の答えの欠け、数値の例外など）でも版を「処理中」のまま残さない
        log.exception("design run failed")
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


def design_view(case_id: str, design_id: str) -> dict:
    d = db.get(f"cases/{case_id}/designs/{design_id}") or {}
    keep = ("revision", "status", "parts", "params", "review", "warnings", "hand_overlay", "files", "approval",
            "summary_ja", "progress", "style", "clip_angle_deg", "clip", "tool", "error", "clamped", "geometry_hash", "origin",
            "parent_design_id", "print_prepared_at")
    return {"design_id": design_id, **{k: d.get(k) for k in keep if k in d}}


def prepare_print(case_id: str, design_id: str, kind: str) -> dict:
    """部品ごとの印刷用STL（review_request / prepare_print）。引数は変えず、R6 に落ちたら RENDER_FAILED"""
    case = db.get(f"cases/{case_id}")
    case["_id"] = case_id
    d = db.get(f"cases/{case_id}/designs/{design_id}")
    params = validator.params_from_records(d["params"])
    selected = [p["part_id"] for p in d["parts"]]
    workdir = tempfile.mkdtemp(prefix="jijogu_print_")
    try:
        res = _make(case, params, selected, workdir, quality="print")
        if res.get("violations"):
            raise ApiError("RENDER_FAILED", details=res["violations"])
        angle = int(d.get("clip_angle_deg") or 70)
        shas, keys = {}, {}
        for part, path in res["files"].items():
            name = f"c_clip_{angle}.stl" if part == "c_clip" else f"{part}.stl"
            key = f"internal/cases/{case_id}/designs/{design_id}/print/{name}"
            data = Path(path).read_bytes()
            files.put(key, data, "model/stl")
            shas[part] = hashlib.sha256(data).hexdigest()
            keys[part] = key
        return {"print_sha256": shas, "internal_keys": keys,
                "geometry_hash": geometry_hash(selected, params, d.get("cover_shell_sha256"))}
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
