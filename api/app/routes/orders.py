"""発注（docs/superpowers/specs/2026-11-21-in-app-ordering-design.md §6.3）。
頼む側（ケースの持ち主）の入口。注文は orders/{orderId}（ケースの外）に置き、ブラウザからは読み書きさせない。"""
from __future__ import annotations

import hashlib
import re
import unicodedata
import uuid

from fastapi import APIRouter, Body, Depends
from fastapi.responses import Response

from .. import fabrication
from ..attachments import TOOL_JA, print_key
from ..auth import User, current_user, fabricator_ids_for
from ..errors import ApiError
from ..store import db, files, now
from .common import owned_case

router = APIRouter()

STATUSES = ("received", "printing", "shipped", "delivered", "cancelled")
_CONFLICT_MSG = "注文の状態が変わりました。読み込み直してください"
_HYPHENS = "－ー‐−—–―"


# ---------------------------------------------------------------- 版と目安


def _design(case_id: str, design_id: str) -> dict:
    d = db.get(f"cases/{case_id}/designs/{design_id}")
    if not d:
        raise ApiError("NOT_FOUND")
    return d


def orderable_design(case_id: str, design_id: str, user: User) -> tuple[dict, dict]:
    """持ち主で、今の版で、OTの確認済み（またはデモのケースで印刷用データを作った版）"""
    case = owned_case(case_id, user)
    d = _design(case_id, design_id)
    if case.get("current_design_id") != design_id:
        raise ApiError("FORBIDDEN", "形が新しくなっています。今の版の画面から頼んでください")
    approved = (d.get("approval") or {}).get("status") == "approved"
    demo_ready = bool(case.get("demo")) and bool(d.get("print_prepared_at"))
    if not (approved or demo_ready) or not (d.get("files") or {}).get("print"):
        raise ApiError("FORBIDDEN", "OTの確認が済んだ版だけ発注できます")
    return case, d


def ensure_estimates(case_id: str, design_id: str, d: dict) -> dict[str, dict]:
    """印刷用STLごとの重さ・時間の目安。なければ STL から計算して版に書き足す"""
    prints = (d.get("files") or {}).get("print") or {}
    est = dict(d.get("print_estimates") or {})
    added = {}
    for key, path in prints.items():
        if key in est:
            continue
        data = files.get(path)
        if data is None:
            continue
        added[key] = fabrication.estimate_part(data, key)
    if added:
        est.update(added)
        db.update(f"cases/{case_id}/designs/{design_id}", {"print_estimates": est})
    return {k: est[k] for k in prints if k in est}


def _grams(est: dict[str, dict]) -> dict[str, float]:
    return {k: float(e["grams"]) for k, e in est.items()}


def _part_name(key: str, d: dict) -> str:
    part = fabrication.part_of(key)
    if part == "cover":
        return "カバー"
    if part == "tpu_sleeve":
        return "TPUの筒"
    for a in d.get("attachments") or []:
        if (a.get("print_key") or print_key(a)) == key:
            return f"C字クリップ（{TOOL_JA.get(a.get('tool_type'), '道具')}・{a.get('angle_deg')}度）"
    return "C字クリップ"


@router.get("/v1/cases/{case_id}/designs/{design_id}/fabricators")
def list_fabricators(case_id: str, design_id: str, user: User = Depends(current_user)):
    _, d = orderable_design(case_id, design_id, user)
    est = ensure_estimates(case_id, design_id, d)
    grams = _grams(est)
    keys = list(est)
    out = [{**f, "price": fabrication.quote(f, grams, keys, 1, False)} for f in fabrication.fabricators()]
    out.sort(key=lambda f: f["price"]["total_yen"])
    cfg = fabrication.config()
    return {"fabricators": out, "estimates": est, "printer": cfg["printer"],
            "materials": {k: fabrication.material_of(k) for k in keys},
            "names": {k: _part_name(k, d) for k in keys},
            "color": fabrication.color_of((d.get("style") or {}).get("color")),
            "felt": cfg["felt"], "delivery_days_after_ship": cfg["delivery_days_after_ship"]}


# ---------------------------------------------------------------- 届け先


def _digits(s: str) -> str:
    """全角の数字・ハイフン類・空白・先頭の〒を直す（日本語入力でそのまま入れた値を受け付ける）"""
    s = unicodedata.normalize("NFKC", s or "").strip().lstrip("〒").strip()
    for h in _HYPHENS:
        s = s.replace(h, "-")
    return re.sub(r"\s+", "", s)


def _bad(field: str, message: str) -> ApiError:
    return ApiError("INVALID_ARGUMENT", message, details=[{"field": f"shipping.{field}"}])


def _shipping(raw) -> dict:
    if not isinstance(raw, dict):
        raise ApiError("INVALID_ARGUMENT", "届け先を入れてください")
    name = unicodedata.normalize("NFKC", str(raw.get("name") or "")).strip()
    address = unicodedata.normalize("NFKC", str(raw.get("address") or "")).strip()
    postal = _digits(str(raw.get("postal_code") or ""))
    phone = _digits(str(raw.get("phone") or ""))
    if not 1 <= len(name) <= 40:
        raise _bad("name", "お名前を1〜40字で入れてください")
    if not re.fullmatch(r"[0-9-]{1,10}", postal):
        raise _bad("postal_code", "郵便番号は数字とハイフンで入れてください（10字まで）")
    if not 1 <= len(address) <= 200:
        raise _bad("address", "住所を1〜200字で入れてください")
    if not re.fullmatch(r"[0-9-]{1,40}", phone):
        raise _bad("phone", "電話番号は数字とハイフンで入れてください（40字まで）")
    return {"name": name, "postal_code": postal, "address": address, "phone": phone}


# ---------------------------------------------------------------- 注文


def owner_view(order_id: str, o: dict) -> dict:
    return {"order_id": order_id, **o}


def _get_order(order_id: str) -> dict:
    o = db.get(f"orders/{order_id}")
    if not o:
        raise ApiError("NOT_FOUND")
    return o


@router.post("/v1/cases/{case_id}/designs/{design_id}/orders", status_code=201)
def create_order(case_id: str, design_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case, d = orderable_design(case_id, design_id, user)
    fab = fabrication.fabricator(str(body.get("fabricator_id") or ""))
    if fab is None:
        raise ApiError("INVALID_ARGUMENT", "受託者が見つかりません")
    prints = d["files"]["print"]
    keys = body.get("print_keys")
    if not isinstance(keys, list) or not keys or len(set(keys)) != len(keys) or any(k not in prints for k in keys):
        raise ApiError("INVALID_ARGUMENT", "刷る部品を選んでください")
    qty = body.get("quantity")
    if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= 3:
        raise ApiError("INVALID_ARGUMENT", "個数は1〜3です")
    felt = body.get("felt") is True
    if felt and not (fab["felt_service"] and "cover" in keys):
        raise ApiError("INVALID_ARGUMENT", "この受託者・部品では、フェルトを貼って送れません")
    shipping = _shipping(body.get("shipping"))
    est = ensure_estimates(case_id, design_id, d)
    shas = d.get("print_sha256") or {}
    items = [{"print_key": k, "name_ja": _part_name(k, d), "material": fabrication.material_of(k), "path": prints[k],
              "sha256": shas.get(k), "grams": (est.get(k) or {}).get("grams"),
              "minutes": (est.get(k) or {}).get("minutes")} for k in keys]
    ap = d.get("approval") or {}
    approval = ({"kind": "ot", "reviewer_email": ap.get("reviewer_email"), "decided_at": ap.get("decided_at")}
                if ap.get("status") == "approved" else {"kind": "demo"})
    order_id = "o_" + uuid.uuid4().hex[:8]
    t = now()
    cfg = fabrication.config()
    o = {"owner_uid": user.uid, "case_id": case_id, "design_id": design_id, "display_id": order_id[2:6].upper(),
         "fabricator_id": fab["id"],
         "fabricator_snapshot": {k: fab[k] for k in ("name", "region", "base_fee_yen", "yen_per_gram", "lead_days",
                                                     "felt_service", "felt_fee_yen", "fictional")},
         "status": "received", "items": items, "quantity": qty,
         "color": fabrication.color_of((d.get("style") or {}).get("color")), "felt": felt,
         "price": fabrication.quote(fab, _grams(est), keys, qty, felt), "lead_days": fab["lead_days"],
         "printer": cfg["printer"], "approval": approval, "shipping": shipping, "demo": bool(case.get("demo")),
         "created_at": t, "printing_at": None, "shipped_at": None, "delivered_at": None, "cancelled_at": None,
         "updated_at": t}
    db.set(f"orders/{order_id}", o)
    return {"order": owner_view(order_id, db.get(f"orders/{order_id}") or o)}


@router.get("/v1/cases/{case_id}/orders")
def list_case_orders(case_id: str, user: User = Depends(current_user)):
    owned_case(case_id, user)
    out = [owner_view(oid, o) for oid, o in db.list("orders") if o.get("case_id") == case_id]
    out.sort(key=lambda o: str(o.get("created_at", "")), reverse=True)
    return {"orders": out}


def transition(order_id: str, allowed_from: str, to: str, check=None) -> dict:
    """今の状態を読んでから書く（同時に来ても片方だけ通る）"""
    def fn(tx):
        o = tx.get(f"orders/{order_id}")
        if not o:
            raise ApiError("NOT_FOUND")
        if check:
            check(o)
        if o.get("status") != allowed_from:
            raise ApiError("CONFLICT", _CONFLICT_MSG)
        t = now()
        patch = {"status": to, f"{to}_at": t, "updated_at": t}
        tx.update(f"orders/{order_id}", patch)
        return {**o, **patch}
    return db.transaction(fn)


def _owner_check(user: User):
    def check(o):
        if o.get("owner_uid") != user.uid:
            raise ApiError("FORBIDDEN")
    return check


@router.post("/v1/orders/{order_id}/cancel")
def cancel_order(order_id: str, user: User = Depends(current_user)):
    _get_order(order_id)
    o = transition(order_id, "received", "cancelled", _owner_check(user))
    return {"order": owner_view(order_id, o)}


@router.post("/v1/orders/{order_id}/delivered")
def deliver_order(order_id: str, user: User = Depends(current_user)):
    _get_order(order_id)
    o = transition(order_id, "shipped", "delivered", _owner_check(user))
    return {"order": owner_view(order_id, o)}


# ---------------------------------------------------------------- 受託する側

_FAB_KEYS = ("display_id", "fabricator_id", "fabricator_snapshot", "status", "quantity", "color", "felt", "price",
             "lead_days", "printer", "approval", "shipping", "demo", "created_at", "printing_at", "shipped_at",
             "delivered_at", "cancelled_at", "updated_at")


def fabricator_view(order_id: str, o: dict) -> dict:
    """受託者に見せてよい中身だけ（ケース・版・持ち主・Storage のパスは返さない）"""
    v = {"order_id": order_id, **{k: o.get(k) for k in _FAB_KEYS}}
    ap = o.get("approval") or {}
    # OTのメールは見せない。確認したかどうかと日時だけ
    v["approval"] = {"kind": ap.get("kind")} | ({"decided_at": ap.get("decided_at")} if ap.get("kind") == "ot" else {})
    if o.get("status") == "cancelled":
        v["shipping"] = None  # 取り消した注文の届け先は残さない
    v["items"] = [{k: val for k, val in i.items() if k != "path"} for i in o.get("items") or []]
    return v


def _staff_ids(user: User) -> list[str]:
    ids = fabricator_ids_for(user)
    if ids is None:
        raise ApiError("FORBIDDEN", "受託者のアカウントではありません")
    return ids


def _staff_order(order_id: str, user: User) -> dict:
    ids = _staff_ids(user)
    o = _get_order(order_id)
    if o.get("fabricator_id") not in ids:
        raise ApiError("FORBIDDEN")
    return o


@router.get("/v1/fabricator/me")
def fabricator_me(user: User = Depends(current_user)):
    ids = _staff_ids(user)
    return {"fabricators": [{"id": f["id"], "name": f["name"]} for f in fabrication.fabricators() if f["id"] in ids]}


@router.get("/v1/fabricator/orders")
def fabricator_orders(fabricator_id: str, user: User = Depends(current_user)):
    if fabricator_id not in _staff_ids(user):
        raise ApiError("FORBIDDEN")
    out = [fabricator_view(oid, o) for oid, o in db.list("orders") if o.get("fabricator_id") == fabricator_id]
    out.sort(key=lambda o: str(o.get("created_at", "")), reverse=True)
    return {"orders": out}


@router.get("/v1/fabricator/orders/{order_id}")
def fabricator_order(order_id: str, user: User = Depends(current_user)):
    return {"order": fabricator_view(order_id, _staff_order(order_id, user))}


@router.get("/v1/fabricator/orders/{order_id}/files/{key}")
def fabricator_file(order_id: str, key: str, user: User = Depends(current_user)):
    o = _staff_order(order_id, user)
    if o.get("status") == "cancelled":
        raise ApiError("FORBIDDEN", "取り消された注文です")
    item = next((i for i in o.get("items") or [] if i.get("print_key") == key), None)
    if item is None:
        raise ApiError("NOT_FOUND")
    data = files.get(item["path"])
    if data is None:
        raise ApiError("NOT_FOUND")
    if item.get("sha256") and hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise ApiError("STALE_DESIGN", "印刷用のデータが、頼まれたときのものと違います")
    name = item["path"].rsplit("/", 1)[-1]
    return Response(content=data, media_type="model/stl",
                    headers={"Content-Disposition": f'attachment; filename="{name}"', "Cache-Control": "no-store"})


@router.post("/v1/fabricator/orders/{order_id}/status")
def fabricator_status(order_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    _staff_order(order_id, user)
    to = body.get("status")
    if to not in ("printing", "shipped"):
        raise ApiError("INVALID_ARGUMENT", "変えられる状態は「造形中」と「発送済み」だけです")
    o = transition(order_id, "received" if to == "printing" else "printing", to)
    return {"order": fabricator_view(order_id, o)}
