"""形の入口（impl_contract §4）。C（生成API）は、ここの3つだけを使う。

- prepare_measurement(raw_glb, measurement, hand_side, requirements=None) -> dict
- make_design(scaled_glb, joints_mm, hand_side, params, workdir, cache, quality="preview", parts=("cover","c_clip")) -> dict
- GeometryError

cache は get(key)->bytes|None と put(key, bytes) を持つもの。キーは "sdf"・"keepout/c1.50"・"shell/<24桁>" で、
どれも同じ採寸の版（実寸の手のメッシュ）の中で決まる。C は採寸の版ごとのフォルダ
（例 internal/cases/{caseId}/cover/{measurementId}/）の下に、キーをそのままパスとして置けばよい。
"""
from .design import DictCache, DirCache, make_clearance_test, make_design, prepare_measurement
from .errors import GeometryError

__all__ = ["prepare_measurement", "make_design", "make_clearance_test", "GeometryError", "DictCache", "DirCache"]
