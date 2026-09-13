#!/usr/bin/env python3
"""Our own photorealistic tiles: 3DEP lidar -> DSM surface mesh, textured with the NAIP orthophoto -> 3D Tiles 1.1 (glb)."""
import argparse, os, sys, json, math, subprocess
import numpy as np
from common import bbox_from, stac_search, sign, write_meta, enu_to_ecef_matrix

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True); ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True); ap.add_argument("--radius-km", type=float, default=1.0)
ap.add_argument("--cell", type=float, default=1.0, help="DSM cell size in metres")
ap.add_argument("--tile-m", type=float, default=256)
ap.add_argument("--max-points", type=float, default=25)
ap.add_argument("--geoid-m", type=float, default=-32.0, help="NAVD88 -> ellipsoid offset (CONUS interior ≈ -30..-36 m)")
a = ap.parse_args()

import laspy, trimesh
from laspy import CopcReader, Bounds
from pyproj import CRS, Transformer
from PIL import Image
from scipy import ndimage

bbox = bbox_from(a.lat, a.lon, a.radius_km)
lat0, lon0 = a.lat, a.lon
kx = 111320.0 * math.cos(math.radians(lat0)); ky = 110540.0
half = a.radius_km * 1000
W = int(math.ceil(2 * half / a.cell)); H = W
print(f"grid {W}x{H} @ {a.cell} m")

# ---------- 1. DSM from lidar (max z per cell, in local ENU metres) ----------
items = stac_search("3dep-lidar-copc", bbox, limit=20)
if not items: print("No 3DEP coverage"); sys.exit(0)
dsm = np.full((H, W), -np.inf, dtype=np.float32)
cap = int(a.max_points * 1e6); total = 0; epsg = None
for it in items:
    try:
        with CopcReader.open(sign(it["assets"]["data"]["href"])) as r:
            crs = r.header.parse_crs()
            if crs is None: continue
            e = crs.to_epsg() or crs.to_2d().to_epsg()
            if e is None: continue
            if epsg is None: epsg = e
            if e != epsg: continue
            fwd = Transformer.from_crs(CRS.from_epsg(4326), CRS.from_epsg(e), always_xy=True)
            inv = Transformer.from_crs(CRS.from_epsg(e), CRS.from_epsg(4326), always_xy=True)
            xs, ys = fwd.transform([bbox[0], bbox[2], bbox[0], bbox[2]], [bbox[1], bbox[1], bbox[3], bbox[3]])
            pts = r.query(bounds=Bounds(mins=np.array([min(xs), min(ys)]), maxs=np.array([max(xs), max(ys)])))
            n = len(pts.x); print(it["id"], n)
            if n == 0: continue
            if total + n > cap:
                keep = np.random.default_rng(1).choice(n, size=max(1, cap - total), replace=False); pts = pts[np.sort(keep)]; n = len(pts.x)
            total += n
            lon, lat = inv.transform(np.asarray(pts.x), np.asarray(pts.y))
            z = np.asarray(pts.z, dtype=np.float32)
            # vertical unit sanity: US feet CRSs
            unit = str(crs.axis_info[-1].unit_name).lower() if crs.axis_info else "metre"
            if "foot" in unit or "ft" in unit: z = z * 0.3048
            ex = (lon - lon0) * kx + half; ny = (lat - lat0) * ky + half
            ci = np.clip((ex / a.cell).astype(int), 0, W - 1); rj = np.clip(((2 * half - ny) / a.cell).astype(int), 0, H - 1)
            flat = rj * W + ci
            cur = dsm.ravel()
            np.maximum.at(cur, flat, z)
            dsm = cur.reshape(H, W)
            if total >= cap: break
    except Exception as ex: print("skip", it["id"], repr(ex))
if total == 0: print("no points"); sys.exit(0)
# fill holes (nearest) and light smoothing on ground only
mask = np.isinf(dsm)
if mask.all(): print("empty dsm"); sys.exit(0)
idx = ndimage.distance_transform_edt(mask, return_distances=False, return_indices=True)
dsm = dsm[tuple(idx)]
dsm = ndimage.median_filter(dsm, size=3)
zmin = float(np.percentile(dsm, 0.5)); dsm = dsm - zmin      # local up = 0 at lowest ground
base = zmin + a.geoid_m
print("dsm range", float(dsm.min()), float(dsm.max()))

# ---------- 2. NAIP orthophoto on the same grid ----------
os.makedirs("work", exist_ok=True)
naip = stac_search("naip", bbox, limit=30)
tex_ok = False
if naip:
    def yr(i): return str(i["properties"].get("naip:year") or i["properties"]["datetime"][:4])
    year = yr(naip[0]); hrefs = [sign(i["assets"]["image"]["href"]) for i in naip if yr(i) == year]
    env = dict(os.environ, GDAL_HTTP_MULTIRANGE="YES", GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR")
    # warp straight into an equirect grid that matches our ENU grid closely enough at this scale
    subprocess.check_call(["gdalwarp", "-q", "-t_srs", "EPSG:4326", "-te", *map(str, bbox), "-ts", str(W), str(H), "-r", "bilinear", "-ot", "Byte",
                           "-co", "TILED=YES", *[f"/vsicurl/{h}" for h in hrefs], "work/tex.tif"], env=env)
    subprocess.check_call(["gdal_translate", "-q", "-b", "1", "-b", "2", "-b", "3", "-of", "JPEG", "-co", "QUALITY=88", "work/tex.tif", "work/tex.jpg"], env=env)
    tex_ok = True
tex = Image.open("work/tex.jpg").convert("RGB") if tex_ok else Image.new("RGB", (W, H), (110, 120, 90))

# ---------- 2b. coarse ground grid (DTM-ish via minimum filter) for placing buildings/trees in the native viewer ----------
gcell = 10
gmin = ndimage.minimum_filter(dsm, size=int(max(3, 16 / a.cell)))
gs = int(gcell / a.cell)
ground = gmin[::gs, ::gs]
os.makedirs(f"site/{a.name}/mesh", exist_ok=True)
json.dump({"cell": gcell, "half": half, "rows": int(ground.shape[0]), "cols": int(ground.shape[1]), "z": [[round(float(v), 2) for v in row] for row in ground]},
          open(f"site/{a.name}/mesh/ground.json", "w"))

# ---------- 3. mesh tiles ----------
out = f"site/{a.name}/mesh"; os.makedirs(out, exist_ok=True)
step = int(max(1, round(a.tile_m / a.cell)))
children = []
for ty in range(0, H, step):
    for tx in range(0, W, step):
        r0, r1 = ty, min(H - 1, ty + step); c0, c1 = tx, min(W - 1, tx + step)
        if r1 - r0 < 2 or c1 - c0 < 2: continue
        sub = dsm[r0:r1 + 1, c0:c1 + 1]
        hh, ww = sub.shape
        # grid vertices in ENU: x east, y north, z up
        cols = np.arange(c0, c1 + 1) * a.cell - half; rows = half - np.arange(r0, r1 + 1) * a.cell
        X, Y = np.meshgrid(cols, rows)
        V = np.column_stack([X.ravel(), Y.ravel(), sub.ravel()])
        i = np.arange(hh * ww).reshape(hh, ww)
        q = np.stack([i[:-1, :-1], i[1:, :-1], i[1:, 1:], i[:-1, 1:]], axis=-1).reshape(-1, 4)
        F = np.vstack([q[:, [0, 1, 2]], q[:, [0, 2, 3]]])
        # glTF is Y-up: (x, z, -y)
        Vg = np.column_stack([V[:, 0], V[:, 2], -V[:, 1]])
        m = trimesh.Trimesh(vertices=Vg, faces=F, process=False)
        # UVs: tile crop of the ortho
        crop = tex.crop((c0, r0, c1 + 1, r1 + 1))
        u = (np.arange(ww) + 0.5) / ww; v = (np.arange(hh) + 0.5) / hh   # glTF UV origin is top-left
        UU, VV = np.meshgrid(u, v)
        m.visual = trimesh.visual.TextureVisuals(uv=np.column_stack([UU.ravel(), VV.ravel()]), image=crop)
        fn = f"m_{tx // step}_{ty // step}.glb"
        m.export(os.path.join(out, fn))
        # OBJ + MTL + JPG twin for the native (SceneKit) structure viewer
        stem = fn[:-4]
        crop.convert("RGB").save(os.path.join(out, stem + ".jpg"), quality=85)
        with open(os.path.join(out, stem + ".mtl"), "w") as f: f.write(f"newmtl ortho\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nmap_Kd {stem}.jpg\n")
        uvs = np.column_stack([UU.ravel(), 1.0 - VV.ravel()])
        with open(os.path.join(out, stem + ".obj"), "w") as f:
            f.write(f"mtllib {stem}.mtl\nusemtl ortho\n")
            f.write("".join(f"v {x:.3f} {y:.3f} {z:.3f}\n" for x, y, z in Vg))
            f.write("".join(f"vt {u:.5f} {v:.5f}\n" for u, v in uvs))
            f.write("".join(f"f {a1+1}/{a1+1} {b1+1}/{b1+1} {c1+1}/{c1+1}\n" for a1, b1, c1 in F))
        cx = (cols[0] + cols[-1]) / 2; cy = (rows[0] + rows[-1]) / 2; zc = float((sub.max() + sub.min()) / 2); zh = float((sub.max() - sub.min()) / 2 + 1)
        children.append({"boundingVolume": {"box": [float(cx), float(cy), zc, (cols[-1] - cols[0]) / 2 + 1, 0, 0, 0, (rows[0] - rows[-1]) / 2 + 1, 0, 0, 0, zh]},
                         "geometricError": 0, "content": {"uri": fn}})
tileset = {"asset": {"version": "1.1", "generator": "godseye-tiles mesh.py"}, "geometricError": 600,
           "root": {"transform": enu_to_ecef_matrix(lat0, lon0, base), "boundingVolume": {"box": [0, 0, float(dsm.max() / 2), half + 2, 0, 0, 0, half + 2, 0, 0, 0, float(dsm.max() / 2 + 2)]},
                    "geometricError": 120, "refine": "ADD", "children": children}}
json.dump(tileset, open(os.path.join(out, "tileset.json"), "w"))
write_meta(out, {"kind": "tileset", "name": f"{a.name} · realism mesh", "url": "tileset.json", "bbox": bbox, "tiles": len(children), "baseHeight": base,
                 "center": [lat0, lon0], "tileM": a.tile_m, "half": half, "cell": a.cell, "credit": "USGS 3DEP + USDA NAIP · MRzefv"})
print("done", out, len(children), "tiles")
