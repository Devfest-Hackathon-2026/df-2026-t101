"""発注の入口（docs/superpowers/specs/2026-11-21-in-app-ordering-design.md §6.3）。
準備（環境変数・仮の geometry・client）は test_api_flow.py のものを使い回す。"""
from __future__ import annotations

from test_api_flow import H, _put_measurement, _setup_case, client  # noqa: F401（client は fixture）

from app import fabrication
from app.store import db, files

SHIP = {"name": "見本 太郎", "postal_code": "000-0000", "address": "見本の住所", "phone": "000-0000-0000"}


def _ready(client):
    """デモのケースで、印刷用データまで作った版"""
    cid, raw, mesh_id = _setup_case(client)
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", headers=H, json={}).json()["design"]
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H)
    assert r.status_code == 200, r.text
    return cid, d["design_id"]


def _order(client, cid, did, headers=H, **kw):
    body = {"fabricator_id": "umikaze", "print_keys": ["cover", "c_clip"], "quantity": 1, "felt": False,
            "shipping": dict(SHIP)} | kw
    return client.post(f"/v1/cases/{cid}/designs/{did}/orders", headers=headers, json=body)


def _set_status(order_id: str, status: str) -> None:
    db.update(f"orders/{order_id}", {"status": status})


# ---------------------------------------------------------------- 頼む側


def test_fabricators_sorted_with_estimates(client):
    cid, did = _ready(client)
    r = client.get(f"/v1/cases/{cid}/designs/{did}/fabricators", headers=H)
    assert r.status_code == 200, r.text
    body = r.json()
    assert [f["id"] for f in body["fabricators"]] == ["hoshizora", "umikaze", "komorebi"]
    est = body["estimates"]
    assert set(est) >= {"cover", "c_clip"} and all(e["grams"] > 0 for e in est.values())
    grams = {k: e["grams"] for k, e in est.items()}
    for f in body["fabricators"]:
        want = fabrication.quote(fabrication.fabricator(f["id"]), grams, list(grams), 1, False)
        assert f["price"] == want
    assert body["printer"]["model"] == "Bambu Lab A1"
    assert body["materials"]["cover"] == "PLA" and body["materials"]["c_clip"] == "PETG"
    assert set(db.get(f"cases/{cid}/designs/{did}")["print_estimates"]) >= {"cover", "c_clip"}


def test_order_requires_approval_or_demo(client):
    cid, did = _ready(client)
    db.update(f"cases/{cid}", {"demo": False})
    assert _order(client, cid, did).status_code == 403
    assert client.get(f"/v1/cases/{cid}/designs/{did}/fabricators", headers=H).status_code == 403


def test_order_on_old_design_is_refused(client):
    cid, did = _ready(client)
    db.update(f"cases/{cid}", {"current_design_id": "d_other"})
    assert _order(client, cid, did).status_code == 403


def test_only_owner_can_order(client):
    cid, did = _ready(client)
    assert _order(client, cid, did, headers={"X-User": "someone"}).status_code == 403


def test_create_order_snapshot(client):
    cid, did = _ready(client)
    r = _order(client, cid, did)
    assert r.status_code == 201, r.text
    o = r.json()["order"]
    d = db.get(f"cases/{cid}/designs/{did}")
    assert o["status"] == "received" and o["order_id"].startswith("o_") and len(o["display_id"]) == 4
    grams = {k: e["grams"] for k, e in d["print_estimates"].items()}
    assert o["price"] == fabrication.quote(fabrication.fabricator("umikaze"), grams, ["cover", "c_clip"], 1, False)
    assert [i["print_key"] for i in o["items"]] == ["cover", "c_clip"]
    assert all(i["sha256"] == d["print_sha256"][i["print_key"]] for i in o["items"])
    assert o["items"][0]["material"] == "PLA" and o["items"][1]["material"] == "PETG"
    assert o["items"][0]["name_ja"] == "カバー" and o["items"][1]["name_ja"].startswith("留め具")
    assert o["color"]["hex"] == d["style"]["color"]
    assert o["approval"] == {"kind": "demo"}
    assert o["fabricator_snapshot"]["name"] == "うみかぜ3D工房"
    assert o["printer"]["model"] == "Bambu Lab A1"
    assert o["lead_days"] == 3 and o["demo"] is True and o["quantity"] == 1
    assert o["case_id"] == cid and o["design_id"] == did


def test_felt_rules(client):
    cid, did = _ready(client)
    assert _order(client, cid, did, fabricator_id="hoshizora", felt=True).status_code == 400
    assert _order(client, cid, did, print_keys=["c_clip"], felt=True).status_code == 400
    r = _order(client, cid, did, felt=True)
    assert r.status_code == 201, r.text
    assert r.json()["order"]["price"]["felt_yen"] == 200 and r.json()["order"]["felt"] is True


def test_invalid_order_inputs_are_400(client):
    cid, did = _ready(client)
    bad = [
        {"quantity": 0}, {"quantity": 4},
        {"print_keys": []}, {"print_keys": ["cover", "nope"]},
        {"fabricator_id": "nope"},
        {"shipping": SHIP | {"name": ""}}, {"shipping": SHIP | {"address": "あ" * 201}},
        {"shipping": SHIP | {"postal_code": "abc-0000"}}, {"shipping": {"name": "見本"}},
    ]
    for kw in bad:
        r = _order(client, cid, did, **kw)
        assert r.status_code == 400, (kw, r.text)


def test_shipping_accepts_fullwidth_digits(client):
    cid, did = _ready(client)
    r = _order(client, cid, did, shipping=SHIP | {"postal_code": "０００－００００", "phone": "０９０ー１２３４ー５６７８"})
    assert r.status_code == 201, r.text
    s = r.json()["order"]["shipping"]
    assert s["postal_code"] == "000-0000" and s["phone"] == "090-1234-5678"


def test_multiple_orders_allowed(client):
    cid, did = _ready(client)
    a = _order(client, cid, did).json()["order"]
    b = _order(client, cid, did, print_keys=["c_clip"]).json()["order"]
    r = client.get(f"/v1/cases/{cid}/orders", headers=H)
    assert r.status_code == 200
    assert [o["order_id"] for o in r.json()["orders"]] == [b["order_id"], a["order_id"]]


def test_cancel_only_when_received(client):
    cid, did = _ready(client)
    a = _order(client, cid, did).json()["order"]
    r = client.post(f"/v1/orders/{a['order_id']}/cancel", headers=H)
    assert r.status_code == 200 and r.json()["order"]["status"] == "cancelled"
    assert r.json()["order"]["cancelled_at"]
    b = _order(client, cid, did).json()["order"]
    _set_status(b["order_id"], "printing")
    r = client.post(f"/v1/orders/{b['order_id']}/cancel", headers=H)
    assert r.status_code == 409 and r.json()["error"]["code"] == "CONFLICT"


def test_delivered_only_when_shipped(client):
    cid, did = _ready(client)
    a = _order(client, cid, did).json()["order"]
    assert client.post(f"/v1/orders/{a['order_id']}/delivered", headers=H).status_code == 409
    _set_status(a["order_id"], "shipped")
    r = client.post(f"/v1/orders/{a['order_id']}/delivered", headers=H)
    assert r.status_code == 200
    assert r.json()["order"]["status"] == "delivered" and r.json()["order"]["delivered_at"]


def test_other_user_cannot_touch_order(client):
    cid, did = _ready(client)
    a = _order(client, cid, did).json()["order"]
    other = {"X-User": "someone"}
    assert client.post(f"/v1/orders/{a['order_id']}/cancel", headers=other).status_code == 403
    assert client.post(f"/v1/orders/{a['order_id']}/delivered", headers=other).status_code == 403
    assert client.get(f"/v1/cases/{cid}/orders", headers=other).status_code == 403
    assert client.post("/v1/orders/o_nothere/cancel", headers=H).status_code == 404


# ---------------------------------------------------------------- 受託する側

FAB = {"X-User": "fab1", "X-User-Email": "fab@example.com"}


def _staff(ids=("*",)):
    db.set("fabricator_staff/fab@example.com", {"fabricator_ids": list(ids), "name": "受託者役"})


def _no_staff():
    db.delete("fabricator_staff/fab@example.com")


def _placed(client, **kw):
    cid, did = _ready(client)
    o = _order(client, cid, did, **kw).json()["order"]
    return cid, did, o


def test_non_staff_gets_403_everywhere(client):
    _no_staff()
    _, _, o = _placed(client)
    oid = o["order_id"]
    assert client.get("/v1/fabricator/me", headers=FAB).status_code == 403
    assert client.get("/v1/fabricator/orders?fabricator_id=umikaze", headers=FAB).status_code == 403
    assert client.get(f"/v1/fabricator/orders/{oid}", headers=FAB).status_code == 403
    assert client.get(f"/v1/fabricator/orders/{oid}/files/cover", headers=FAB).status_code == 403
    assert client.post(f"/v1/fabricator/orders/{oid}/status", headers=FAB, json={"status": "printing"}).status_code == 403


def test_staff_scope_by_fabricator(client):
    _staff(["hoshizora"])
    _, _, o = _placed(client)  # umikaze あて
    me = client.get("/v1/fabricator/me", headers=FAB).json()["fabricators"]
    assert [f["id"] for f in me] == ["hoshizora"]
    assert client.get("/v1/fabricator/orders?fabricator_id=umikaze", headers=FAB).status_code == 403
    assert client.get(f"/v1/fabricator/orders/{o['order_id']}", headers=FAB).status_code == 403
    _staff()
    me = client.get("/v1/fabricator/me", headers=FAB).json()["fabricators"]
    assert [f["id"] for f in me] == ["umikaze", "hoshizora", "komorebi"]
    lst = client.get("/v1/fabricator/orders?fabricator_id=umikaze", headers=FAB).json()["orders"]
    assert o["order_id"] in [x["order_id"] for x in lst]


def test_fabricator_view_hides_case_data(client):
    _staff()
    _, _, o = _placed(client)
    r = client.get(f"/v1/fabricator/orders/{o['order_id']}", headers=FAB)
    assert r.status_code == 200, r.text
    v = r.json()["order"]
    assert not {"case_id", "design_id", "owner_uid"} & set(v)
    assert all("path" not in i for i in v["items"])
    assert {"shipping", "color", "printer", "approval", "price", "items", "status"} <= set(v)
    lst = client.get("/v1/fabricator/orders?fabricator_id=umikaze", headers=FAB).json()["orders"]
    assert all(not {"case_id", "design_id", "owner_uid"} & set(x) for x in lst)


def test_fabricator_status_flow(client):
    _staff()
    _, _, o = _placed(client)
    url = f"/v1/fabricator/orders/{o['order_id']}/status"
    assert client.post(url, headers=FAB, json={"status": "shipped"}).status_code == 409
    r = client.post(url, headers=FAB, json={"status": "printing"})
    assert r.status_code == 200 and r.json()["order"]["status"] == "printing" and r.json()["order"]["printing_at"]
    assert client.post(url, headers=FAB, json={"status": "printing"}).status_code == 409
    r = client.post(url, headers=FAB, json={"status": "shipped"})
    assert r.status_code == 200 and r.json()["order"]["shipped_at"]
    assert client.post(url, headers=FAB, json={"status": "delivered"}).status_code == 400


def test_cancel_vs_printing_race_is_single_winner(client):
    _staff()
    _, _, o = _placed(client)
    assert client.post(f"/v1/fabricator/orders/{o['order_id']}/status", headers=FAB,
                       json={"status": "printing"}).status_code == 200
    assert client.post(f"/v1/orders/{o['order_id']}/cancel", headers=H).status_code == 409


def test_fabricator_file_download(client):
    _staff()
    cid, did, o = _placed(client)
    r = client.get(f"/v1/fabricator/orders/{o['order_id']}/files/cover", headers=FAB)
    assert r.status_code == 200, r.text
    assert r.headers["content-type"].startswith("model/stl")
    assert r.content == files.get(f"cases/{cid}/designs/{did}/print/cover.stl")
    assert client.get(f"/v1/fabricator/orders/{o['order_id']}/files/nope", headers=FAB).status_code == 404


def test_fabricator_file_sha_mismatch(client):
    _staff()
    cid, did, o = _placed(client)
    files.put(f"cases/{cid}/designs/{did}/print/cover.stl", b"changed")
    r = client.get(f"/v1/fabricator/orders/{o['order_id']}/files/cover", headers=FAB)
    assert r.status_code == 409 and r.json()["error"]["code"] == "STALE_DESIGN"


def test_fabricator_file_missing_is_404(client):
    _staff()
    cid, did, o = _placed(client)
    files.delete_prefix(f"cases/{cid}/designs/{did}/print/cover.stl")
    assert client.get(f"/v1/fabricator/orders/{o['order_id']}/files/cover", headers=FAB).status_code == 404


def test_cancelled_order_file_is_403(client):
    _staff()
    _, _, o = _placed(client)
    client.post(f"/v1/orders/{o['order_id']}/cancel", headers=H)
    assert client.get(f"/v1/fabricator/orders/{o['order_id']}/files/cover", headers=FAB).status_code == 403


# ---------------------------------------------------------------- ケースとのつながり


def _latest(client, cid):
    return next(c for c in client.get("/v1/cases", headers=H).json()["cases"] if c["case_id"] == cid)["latest_order"]


def test_case_list_has_latest_order(client):
    cid, did = _ready(client)
    assert _latest(client, cid) is None
    a = _order(client, cid, did).json()["order"]
    b = _order(client, cid, did).json()["order"]
    assert _latest(client, cid) == {"order_id": b["order_id"], "status": "received"}
    client.post(f"/v1/orders/{b['order_id']}/cancel", headers=H)
    assert _latest(client, cid) == {"order_id": a["order_id"], "status": "received"}


def test_delete_case_deletes_orders(client):
    cid, did = _ready(client)
    _order(client, cid, did)
    assert any(o.get("case_id") == cid for _, o in db.list("orders"))
    assert client.delete(f"/v1/cases/{cid}", headers=H).status_code == 200
    assert not any(o.get("case_id") == cid for _, o in db.list("orders"))


def test_fabricator_sees_404_after_case_deleted(client):
    _staff()
    cid, did, o = _placed(client)
    client.delete(f"/v1/cases/{cid}", headers=H)
    assert client.get(f"/v1/fabricator/orders/{o['order_id']}", headers=FAB).status_code == 404
    assert client.get(f"/v1/fabricator/orders/{o['order_id']}/files/cover", headers=FAB).status_code == 404


# ---------------------------------------------------------------- 最後のレビューで見つかった点


def test_fabricator_view_hides_reviewer_email(client):
    """OTの確認済みの注文でも、受託者には確認した日時だけを見せ、OTのメールは見せない（設計 §2）"""
    _staff()
    cid, did = _ready(client)
    db.update(f"cases/{cid}", {"demo": False})
    db.update(f"cases/{cid}/designs/{did}", {"approval": {"status": "approved", "reviewer_email": "ot@example.com",
                                                         "decided_at": "2026-11-22T10:00:00Z"}})
    o = _order(client, cid, did).json()["order"]
    assert o["approval"]["kind"] == "ot"
    for url in (f"/v1/fabricator/orders/{o['order_id']}", "/v1/fabricator/orders?fabricator_id=umikaze"):
        r = client.get(url, headers=FAB)
        assert r.status_code == 200
        assert "ot@example.com" not in r.text
    v = client.get(f"/v1/fabricator/orders/{o['order_id']}", headers=FAB).json()["order"]
    assert v["approval"] == {"kind": "ot", "decided_at": "2026-11-22T10:00:00Z"}


def test_old_design_gets_its_own_reason(client):
    cid, did = _ready(client)
    db.update(f"cases/{cid}", {"current_design_id": "d_other"})
    r = _order(client, cid, did)
    assert r.status_code == 403 and "今の版" in r.json()["error"]["message"]


def test_shipping_accepts_spaces_and_postal_mark(client):
    cid, did = _ready(client)
    r = _order(client, cid, did, shipping=SHIP | {"postal_code": "〒123 4567", "phone": "０９０―１２３４ ５６７８"})
    assert r.status_code == 201, r.text
    s = r.json()["order"]["shipping"]
    assert s["postal_code"] == "1234567" and s["phone"] == "090-12345678"


def test_shipping_error_names_the_field(client):
    cid, did = _ready(client)
    r = _order(client, cid, did, shipping=SHIP | {"postal_code": "abc"})
    assert r.status_code == 400
    assert "郵便番号" in r.json()["error"]["message"]
    assert r.json()["error"]["details"] == [{"field": "shipping.postal_code"}]


def test_cancelled_order_hides_shipping_from_fabricator(client):
    _staff()
    _, _, o = _placed(client)
    client.post(f"/v1/orders/{o['order_id']}/cancel", headers=H)
    v = client.get(f"/v1/fabricator/orders/{o['order_id']}", headers=FAB).json()["order"]
    assert v["shipping"] is None
    assert v["status"] == "cancelled"
