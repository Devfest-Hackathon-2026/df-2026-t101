"""手のメッシュの符号付き距離場（generation-pipeline.md §6.2 の手順1〜6）。採寸の版ごとに1回作り、使い回す。

落とし穴（11/7のスパイク）：
- 表面から2mm以内の内外と距離は、一番近い面の法線と平面までの距離で決める（ボクセルだけでは面が階段になり、
  拾った点までの距離だけではざらつく）
- 2mmより遠い点の内外は、閉じた手のメッシュ全体をボクセルにして塗る（手は計算の箱からはみ出すので、箱の中だけでは塗れない）
- 最後にガウスで少しぼかす
"""
from __future__ import annotations

import io
from dataclasses import dataclass

import numpy as np
import trimesh
from scipy import ndimage
from scipy.spatial import cKDTree

from .consts import FIELD_VERSION, LONG_FINGERS, fixed

NEAR_BAND_MM = 2.0
N_SAMPLES = 300_000
INSIDE_PITCH_MM = 1.0   # 遠い点の内外を決めるボクセル（2mmより遠い点だけに使うので粗くてよい）


@dataclass
class Field:
    origin: np.ndarray      # 格子の (0,0,0) の座標（正準形、mm）
    voxel: float
    sdf: np.ndarray         # float32 [nx,ny,nz]。手の中が負
    nz: np.ndarray          # int8 [nx,ny,nz]。一番近い面の法線の z（+z＝手のひら側）× 127
    version: str = FIELD_VERSION

    @property
    def shape(self):
        return self.sdf.shape

    def axes(self):
        return [self.origin[i] + self.voxel * np.arange(self.shape[i], dtype=np.float32) for i in range(3)]

    def to_bytes(self) -> bytes:
        buf = io.BytesIO()
        np.savez_compressed(buf, origin=self.origin, voxel=np.float32(self.voxel), sdf=self.sdf, nz=self.nz,
                            version=np.array(self.version))
        return buf.getvalue()

    @classmethod
    def from_bytes(cls, data: bytes) -> "Field":
        z = np.load(io.BytesIO(data), allow_pickle=False)
        return cls(origin=z["origin"].astype(np.float64), voxel=float(z["voxel"]), sdf=z["sdf"], nz=z["nz"],
                   version=str(z["version"]))


def field_bounds(vertices: np.ndarray, Jc: dict, radii: dict) -> tuple[np.ndarray, np.ndarray]:
    """距離場の箱（正準形）。殻が取りうる一番外側（c と t の最大＋余白）まで広げ、手首側・手のひら側は切る。"""
    m = 3.0 + 3.5 + 4.0                     # c の最大（仮）＋ t の最大 ＋ 余白
    lo = vertices.min(axis=0) - m
    hi = vertices.max(axis=0) + m
    lo[1] = max(lo[1], fixed("WRIST_FREE_MM") - 4.0)
    rmax = max(max(radii[f]) for f in LONG_FINGERS)
    y_far = max(max(Jc[f][1][1], Jc[f][0][1]) for f in LONG_FINGERS) + rmax + m + 6.0
    hi[1] = min(hi[1], y_far)
    z_pip = float(np.mean([Jc[f][1][2] for f in LONG_FINGERS]))
    hi[2] = min(hi[2], z_pip + 8.0 + 4.0)
    return lo, hi


def compute_field(vertices_c: np.ndarray, faces_c: np.ndarray, Jc: dict, radii: dict,
                  voxel: float | None = None) -> Field:
    voxel = float(voxel or fixed("CAVITY_VOXEL_MM"))
    mesh = trimesh.Trimesh(vertices_c, faces_c, process=False)
    if mesh.volume < 0:
        mesh.invert()
    lo, hi = field_bounds(np.asarray(mesh.vertices), Jc, radii)
    axes = [np.arange(lo[i], hi[i] + voxel * 0.5, voxel, dtype=np.float64) for i in range(3)]
    shape = tuple(len(a) for a in axes)
    G = np.stack(np.meshgrid(*axes, indexing="ij"), -1).reshape(-1, 3)

    pts, fidx = trimesh.sample.sample_surface(mesh, N_SAMPLES, seed=0)
    pts = np.vstack([pts, mesh.vertices])
    nrm = np.vstack([mesh.face_normals[fidx], mesh.vertex_normals])
    tree = cKDTree(pts)
    dist = np.empty(len(G), dtype=np.float32)
    sd = np.empty(len(G), dtype=np.float32)
    nzv = np.empty(len(G), dtype=np.float32)
    step = 1_000_000
    for s in range(0, len(G), step):
        g = G[s:s + step]
        d, i = tree.query(g, workers=-1)
        dist[s:s + step] = d
        sd[s:s + step] = ((g - pts[i]) * nrm[i]).sum(1)
        nzv[s:s + step] = nrm[i, 2]

    # 遠い点の内外：手全体のボクセルを塗る
    vg = mesh.voxelized(pitch=INSIDE_PITCH_MM).fill()
    occ = vg.matrix
    vi = np.round(trimesh.transformations.transform_points(G, np.linalg.inv(vg.transform))).astype(np.int64)
    ok = np.all((vi >= 0) & (vi < np.array(occ.shape)), axis=1)
    inside = np.zeros(len(G), dtype=bool)
    inside[ok] = occ[vi[ok, 0], vi[ok, 1], vi[ok, 2]]
    near = dist < NEAR_BAND_MM
    inside = np.where(near, sd < 0, inside)
    dist = np.where(near, np.abs(sd), dist)
    sdf = np.where(inside, -dist, dist).reshape(shape).astype(np.float32)
    sdf = ndimage.gaussian_filter(sdf, float(fixed("CAVITY_SMOOTH_SIGMA"))).astype(np.float32)
    nz = ndimage.gaussian_filter(nzv.reshape(shape), 1.0)
    nz = np.clip(np.round(nz * 127), -127, 127).astype(np.int8)
    return Field(origin=np.asarray(lo, dtype=np.float64), voxel=voxel, sdf=sdf, nz=nz)


def sample_sdf(field: Field, P: np.ndarray) -> np.ndarray:
    """点 P（正準形）での距離（3次の補間ではなく1次）。箱の外は大きな値。"""
    idx = (np.asarray(P) - field.origin) / field.voxel
    return ndimage.map_coordinates(field.sdf, idx.T, order=1, mode="constant", cval=99.0)
