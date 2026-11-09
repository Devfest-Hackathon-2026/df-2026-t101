"""Gemini の出力スキーマ（docs/generation-pipeline.md §3）"""
from __future__ import annotations

PARAM_CHANGES = {
    "type": "array", "maxItems": 8,
    "items": {"type": "object", "required": ["part_id", "name", "value", "reason_ja"],
              "properties": {"part_id": {"type": "string"}, "name": {"type": "string"},
                             "value": {"anyOf": [{"type": "number"}, {"type": "boolean"}, {"type": "string"}]},
                             "reason_ja": {"type": "string"}}},
}

INTERVIEW = {
    "type": "object",
    "required": ["status", "message_ja", "choices", "notes", "suggested_changes", "out_of_scope_reason"],
    "properties": {
        "status": {"enum": ["ask", "done", "out_of_scope"]},
        "message_ja": {"type": "string"},
        "choices": {"type": "array", "items": {"type": "string"}, "maxItems": 4},
        "notes": {"type": "array", "items": {"type": "string"}},
        "suggested_changes": {"type": "array", "items": {
            "type": "object", "required": ["field", "value", "reason_ja"],
            "properties": {"field": {"enum": ["activity", "tool_type", "hand_side", "tool_d_mm", "tool_shaft_shape",
                                              "finger_state", "donning_by", "capture_by"]},
                           "value": {"type": "string"}, "reason_ja": {"type": "string"}}}},
        "activity_ja": {"type": "string"},
        "out_of_scope_reason": {"enum": ["orthosis", "mouth_contact", "unsupported_tool", "medical_claim", "none"]},
    },
}

SELECT = {
    "type": "object", "required": ["parts"],
    "properties": {"parts": {"type": "array", "minItems": 5, "maxItems": 6, "items": {
        "type": "object", "required": ["part_id", "variant", "reason_ja"],
        "properties": {"part_id": {"enum": ["cover", "air_holes", "strap_slits", "rail", "c_clip", "tpu_sleeve"]},
                       "variant": {"enum": ["standard"]}, "reason_ja": {"type": "string"}}}}},
}

DIMENSION = {
    "type": "object", "required": ["params", "summary_ja"],
    "properties": {
        "params": {"type": "array", "items": {
            "type": "object", "required": ["part_id", "name", "value", "source", "reason_ja"],
            "properties": {"part_id": {"type": "string"}, "name": {"type": "string"},
                           "value": {"anyOf": [{"type": "number"}, {"type": "boolean"}, {"type": "string"}]},
                           "source": {"enum": ["measured", "rule", "interview", "ai", "default"]},
                           "reason_ja": {"type": "string"}}}},
        "summary_ja": {"type": "string"},
        # 主でない取り付け具ごとの角度（任意。複数の取り付け具があるときだけ）
        "attachments": {"type": "array", "items": {
            "type": "object", "required": ["attachment_id", "angle_deg", "reason_ja"],
            "properties": {"attachment_id": {"type": "string"}, "angle_deg": {"type": "number"},
                           "reason_ja": {"type": "string"}}}},
    },
}

ATTACHMENT = {
    "type": "object", "required": ["angle_deg", "reason_ja"],
    "properties": {"angle_deg": {"type": "number"}, "reason_ja": {"type": "string"}},
}

REVIEW = {
    "type": "object", "required": ["verdict", "checks", "issues", "changes"],
    "properties": {
        "verdict": {"enum": ["ok", "revise"]},
        "checks": {"type": "array", "items": {"type": "object", "required": ["id", "pass", "note_ja"],
                                              "properties": {"id": {"enum": ["C1", "C2", "C3", "C4", "C5"]},
                                                             "pass": {"type": "boolean"}, "note_ja": {"type": "string"}}}},
        "issues": {"type": "array", "items": {"type": "object", "required": ["severity", "description_ja"],
                                              "properties": {"severity": {"enum": ["high", "medium", "low"]},
                                                             "description_ja": {"type": "string"}}}},
        "changes": PARAM_CHANGES,
    },
}

REFINE = {
    "type": "object", "required": ["changes", "message_ja", "clarify_ja", "override_by_user"],
    "properties": {"changes": PARAM_CHANGES, "message_ja": {"type": "string"}, "clarify_ja": {"type": "string"},
                   "override_by_user": {"type": "boolean"}},
}
