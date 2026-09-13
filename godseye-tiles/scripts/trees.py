#!/usr/bin/env python3
"""Vegetation: OSM trees + forest/wood polygons -> instanced low-poly trees merged per tile -> 3D Tiles 1.1."""
import argparse, os, json, math, requests
import numpy as np, trimesh
from shapely.geometry import Polygon, Point
from common import bbox_from, enu_to_ecef_matrix, write_meta

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True); ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True); ap.add_argument("--radius-km", type=float, default=1.5)
ap.add_argument("--tile-m", type=float, default=300); ap.add_argument("--density", type=float, default=110, help="m² per tree inside forest polygons")
ap.add_argument("--max-trees", type=int, default=40000)
a = ap.parse_args()
bbox = bbox_from(a.lat, a.lon, a.radius_km)
bb = f"({bbox[1]},{bbox[0]},{bbox[3]},{bbox[2]})"
q = f'[out:json][timeout:120];(node["natural"="tree"]{bb};way["landuse"="forest"]{bb};way["natural"="wood"]{bb};way["leisure"="park"]{bb};way["natural"="scrub"]{bb};);out geom;'
r = requests.post("https://overpass-api.de/api/interpreter", data={"data": q}, timeout=180, headers={"User-Agent": "GodsEye-tiles (MRzefv)"}); r.raise_for_status()
els = r.json()["elements"]
lat0, lon0 = a.lat, a.lon; kx = 111320.0 * math.cos(math.radians(lat0)); ky = 110540.0
def enu(lon, lat): return ((lon - lon0) * kx, (lat - lat0) * ky)
rng = np.random.default_rng(7)
trees = []   # (x, y, kind, scale)
for e in els:
    t = e.get("tags", {})
    if e["type"] == "node":
        x, y = enu(e["lon"], e["lat"]); kind = "conifer" if t.get("leaf_type") == "needleleaved" else "broadleaf"
        trees.append((x, y, kind, float(rng.uniform(0.8, 1.3))))
    elif e["type"] == "way" and "geometry" in e:
        pts = [enu(g["lon"], g["lat"]) for g in e["geometry"]]
        if len(pts) < 4: continue
        p = Polygon(pts).buffer(0)
        if p.is_empty: continue
        dens = a.density * (3.0 if t.get("leisure") == "park" else 1.6 if t.get("natural") == "scrub" else 1.0)
        n = int(p.area / dens)
        kind = "conifer" if t.get("leaf_type") == "needleleaved" else "broadleaf"
        minx, miny, maxx, maxy = p.bounds
        cand = rng.uniform([minx, miny], [maxx, maxy], size=(int(n * 1.8) + 4, 2))
        got = 0
        for x, y in cand:
            if got >= n: break
            if p.contains(Point(x, y)): trees.append((x, y, kind if rng.random() > 0.15 else ("broadleaf" if kind == "conifer" else "conifer"), float(rng.uniform(0.6, 1.4)))); got += 1
    if len(trees) > a.max_trees: break
print(f"{len(trees)} trees")
if not trees: raise SystemExit(0)

def tree_mesh(kind):
    if kind == "conifer":
        trunk = trimesh.creation.cylinder(radius=0.25, height=3, sections=6).apply_translation([0, 0, 1.5])
        crown = trimesh.creation.cone(radius=2.2, height=7, sections=7).apply_translation([0, 0, 3])
        cols = [(90, 60, 35), (40, 95, 45)]
    else:
        trunk = trimesh.creation.cylinder(radius=0.3, height=3.5, sections=6).apply_translation([0, 0, 1.75])
        crown = trimesh.creation.icosphere(subdivisions=1, radius=3.0).apply_translation([0, 0, 6])
        cols = [(95, 65, 40), (55, 125, 55)]
    for m, c in zip((trunk, crown), cols): m.visual.vertex_colors = np.tile(np.array(list(c) + [255], dtype=np.uint8), (len(m.vertices), 1))
    return trimesh.util.concatenate([trunk, crown])   # z-up ENU
proto = {k: tree_mesh(k) for k in ("conifer", "broadleaf")}
tiles = {}
for x, y, kind, s in trees:
    key = (int(math.floor(x / a.tile_m)), int(math.floor(y / a.tile_m)))
    m = proto[kind].copy(); m.apply_scale(s); m.apply_transform(trimesh.transformations.rotation_matrix(rng.uniform(0, 6.28), [0, 0, 1])); m.apply_translation([x, y, 0])
    jitter = rng.integers(-18, 18); m.visual.vertex_colors = np.clip(m.visual.vertex_colors.astype(int) + [0, jitter, 0, 0], 0, 255).astype(np.uint8)
    tiles.setdefault(key, []).append(m)
out = f"site/{a.name}/trees"; os.makedirs(out, exist_ok=True)
children = []
for (i, j), ms in tiles.items():
    m = trimesh.util.concatenate(ms); v = m.vertices.copy(); m.vertices = np.column_stack([v[:, 0], v[:, 2], -v[:, 1]])
    fn = f"t_{i}_{j}.glb"; m.export(os.path.join(out, fn))
    children.append({"boundingVolume": {"box": [i * a.tile_m + a.tile_m / 2, j * a.tile_m + a.tile_m / 2, 6, a.tile_m / 2, 0, 0, 0, a.tile_m / 2, 0, 0, 0, 7]}, "geometricError": 0, "content": {"uri": fn}})
half = a.radius_km * 1000 + a.tile_m
json.dump({"asset": {"version": "1.1", "generator": "godseye-tiles trees.py"}, "geometricError": 500,
           "root": {"transform": enu_to_ecef_matrix(lat0, lon0, 0.0), "boundingVolume": {"box": [0, 0, 6, half, 0, 0, 0, half, 0, 0, 0, 7]}, "geometricError": 80, "refine": "ADD", "children": children}},
          open(os.path.join(out, "tileset.json"), "w"))
write_meta(out, {"kind": "tileset", "name": f"{a.name} · vegetation", "url": "tileset.json", "bbox": bbox, "tiles": len(children), "trees": len(trees), "credit": "© OpenStreetMap contributors · MRzefv"})
print("done", out, len(children), "tiles")
