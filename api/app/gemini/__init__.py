"""Gemini の5種類の呼び出し（docs/generation-pipeline.md §2・§3）。GEMINI_MODE=mock なら決まった答えを返す。
プロンプトの本文は api/prompts/<名前>.v<版>.md。版は PROMPT_VERSIONS で版に記録する。"""
from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path
from string import Template

from ..config import PROMPT_DIR, settings
from ..errors import ApiError
from . import mock, schemas

log = logging.getLogger("gemini")
PROMPT_VERSIONS = {"system": "v1", "interview": "v1", "select": "v1", "dimension": "v1", "review": "v1", "refine": "v1"}
THINKING = {"interview": "LOW", "select": "LOW", "dimension": "MEDIUM", "review": "MEDIUM", "refine": "LOW"}


class Usage:
    def __init__(self):
        self.input_tokens = 0
        self.output_tokens = 0
        self.calls = 0

    def as_dict(self) -> dict:
        return {"input_tokens": self.input_tokens, "output_tokens": self.output_tokens, "gemini_calls": self.calls}


@lru_cache(maxsize=None)
def _prompt(name: str) -> str:
    return (PROMPT_DIR / f"{name}.{PROMPT_VERSIONS[name]}.md").read_text(encoding="utf-8")


def _j(v) -> str:
    return json.dumps(v, ensure_ascii=False, indent=1)


@lru_cache(maxsize=1)
def _client():
    from google import genai
    from google.genai import types

    if not settings.project:
        raise ApiError("AI_UNAVAILABLE", details=[{"reason": "GOOGLE_CLOUD_PROJECT が設定されていません"}])
    return genai.Client(vertexai=True, project=settings.project, location=settings.gemini_location,
                        http_options=types.HttpOptions(retry_options=types.HttpRetryOptions(
                            attempts=5, initial_delay=1.0, http_status_codes=[408, 429, 500, 502, 503, 504])))


def _live(name: str, text: str, schema: dict, usage: Usage, images: list[bytes] | None = None) -> dict:
    from google.genai import types

    parts: list = []
    for b in images or []:
        parts.append(types.Part.from_bytes(data=b, mime_type="image/png"))
    parts.append(text)
    cfg = types.GenerateContentConfig(
        system_instruction=_prompt("system"),
        response_mime_type="application/json",
        response_json_schema=schema,
        thinking_config=types.ThinkingConfig(thinking_level=THINKING[name]),
        media_resolution=types.MediaResolution.MEDIA_RESOLUTION_MEDIUM,
    )
    last = None
    for _ in range(2):  # 形が崩れていたら1回だけ聞き直す（R1）
        try:
            resp = _client().models.generate_content(model=settings.gemini_model, contents=parts, config=cfg)
        except ApiError:
            raise
        except Exception as e:  # noqa: BLE001 - SDK の再試行のあとでもだめなとき
            log.warning("gemini %s failed: %s", name, type(e).__name__)
            raise ApiError("AI_UNAVAILABLE")
        um = resp.usage_metadata
        if um:
            usage.input_tokens += um.prompt_token_count or 0
            usage.output_tokens += (um.candidates_token_count or 0) + (um.thoughts_token_count or 0)
        usage.calls += 1
        try:
            return json.loads(resp.text)
        except (TypeError, json.JSONDecodeError) as e:
            last = e
            parts = parts + [f"前の出力はJSONとして読めませんでした（{e}）。スキーマどおりのJSONだけを出してください。"]
    raise ApiError("AI_OUTPUT_INVALID", details=[{"request": name, "reason": str(last)}])


def _run(name: str, vars: dict, schema: dict, usage: Usage, images=None, mock_fn=None) -> dict:
    if settings.gemini_mode != "live":
        usage.calls += 1
        return mock_fn()
    text = Template(_prompt(name)).safe_substitute({k: (v if isinstance(v, str) else _j(v)) for k, v in vars.items()})
    return _live(name, text, schema, usage, images)


# ---------------------------------------------------------------- 5種類
def interview(requirements: dict, history: list[dict], message: str, turn: int, usage: Usage) -> dict:
    return _run("interview", {"requirements": requirements, "history": history, "message": message, "turn": str(turn)},
                schemas.INTERVIEW, usage, mock_fn=lambda: mock.interview(requirements, message, turn))


def select(requirements: dict, hand: dict, catalog_summary: list, usage: Usage) -> dict:
    return _run("select", {"requirements": requirements, "hand": hand, "catalog": catalog_summary},
                schemas.SELECT, usage, mock_fn=lambda: mock.select(requirements))


def dimension(requirements: dict, hand: dict, parts: list, param_defs: list, violations: list | None,
              usage: Usage) -> dict:
    v = ("\n前の答えの問題（直してください）：\n" + _j(violations)) if violations else ""
    return _run("dimension", {"requirements": requirements, "hand": hand, "parts": parts, "params": param_defs,
                              "violations": v}, schemas.DIMENSION, usage,
                mock_fn=lambda: mock.dimension(requirements, param_defs))


def review(images: list[bytes], requirements: dict, hand: dict, params: list, history: list, round_no: int,
           usage: Usage) -> dict:
    return _run("review", {"requirements": requirements, "hand": hand, "params": params, "history": history,
                           "round": str(round_no)}, schemas.REVIEW, usage, images=images,
                mock_fn=lambda: mock.review(params, round_no))


def refine(requirements: dict, params: list, instruction: str, usage: Usage) -> dict:
    return _run("refine", {"requirements": requirements, "params": params, "instruction": instruction},
                schemas.REFINE, usage, mock_fn=lambda: mock.refine(params, instruction))
