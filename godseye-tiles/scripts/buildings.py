#!/usr/bin/env python3
"""OSM building footprints -> extruded glTF tiles -> 3D Tiles 1.1 tileset (keyless, hand-rolled)."""
import argparse, os, json, math, requests
import numpy as np, trimesh
from shapely.geometry import Polygon
from common import bbox_from, enu_to_ecef_matrix, write_meta

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True); ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True); ap.add_argument("--radius-km", type=float, default=1.5)
ap.add_argument("--tile-m", type=float, default=400)
a = ap.parse_args()
bbox = bbox_from(a.lat, a.lon, a.radius_km)
bb = f"({bbox[1]},{bbox[0]},{bbox[3]},{bbox[2]})"
q = f'[out:json][timeout:120];(way["building"]{bb};relation["building"]["type"="multipolygon"]{bb};);out geom;'
r = requests.post("https://overpass-api.de/api/interpreter", data={"data": q}, timeout=180, headers={"User-Agent": "GodsEye-tiles (MRzefv)"})
r.raise_for_status()
els = r.json()["elements"]
print(f"{len(els)} building elements")

lat0, lon0 = a.lat, a.lon
kx = 111320.0 * math.cos(math.radians(lat0)); ky = 110540.0
def enu(lon, lat): return ((lon - lon0) * kx, (lat - lat0) * ky)

def height_of(t):
    for k in ("height", "building:height"):
        if k in t:
            try: return float(str(t[k]).replace("m", "").split()[0])
            except Exception: pass
    if "building:levels" in t:
        try: return max(3.0, float(t["building:levels"]) * 3.2)
        except Exception: pass
    b = t.get("building", "yes")
    return {"house": 6.5, "detached": 6.5, "residential": 7.0, "garage": 3.0, "shed": 2.8, "church": 14.0,
            "industrial": 9.0, "commercial": 8.0, "retail": 6.0, "school": 8.0, "apartments": 12.0, "hospital": 16.0}.get(b, 6.0)

def color_of(t):
    b = t.get("building", "yes")
    return {"church": [200, 180, 140], "industrial": [150, 150, 160], "commercial": [170, 160, 150],
            "retail": [175, 165, 150], "garage": [140, 140, 140], "shed": [140, 130, 120]}.get(b, [190, 175, 160])

meshes = {}
def add(outer, holes, tags):
    pts = [enu(x, y) for x, y in outer]
    if len(pts) < 4: return
    p = Polygon(pts, [[enu(x, y) for x, y in h] for h in holes if len(h) >= 4]).buffer(0)
    if p.is_empty or p.area < 4: return
    h = height_of(tags)
    for pp in ([p] if p.geom_type == "Polygon" else list(p.geoms)):
        try: m = trimesh.creation.extrude_polygon(pp, h)
        except Exception: continue
        c = color_of(tags)
        m.visual.vertex_colors = np.tile(np.array(c + [255], dtype=np.uint8), (len(m.vertices), 1))
        key = (int(math.floor(pp.centroid.x / a.tile_m)), int(math.floor(pp.centroid.y / a.tile_m)))
        meshes.setdefault(key, []).append(m)

for e in els:
    tags = e.get("tags", {})
    if e["type"] == "way" and "geometry" in e:
        add([(g["lon"], g["lat"]) for g in e["geometry"]], [], tags)
    elif e["type"] == "relation":
        mem = e.get("members", [])
        outers = [[(g["lon"], g["lat"]) for g in m["geometry"]] for m in mem if m.get("role") == "outer" and "geometry" in m]
        inners = [[(g["lon"], g["lat"]) for g in m["geometry"]] for m in mem if m.get("role") == "inner" and "geometry" in m]
        for o in outers: add(o, inners, tags)

out = f"site/{a.name}/buildings"
os.makedirs(out, exist_ok=True)
children = []
for (i, j), ms in meshes.items():
    m = trimesh.util.concatenate(ms)
    v = m.vertices.copy()
    zmax = float(v[:, 2].max())
    # glTF is Y-up; the 3D Tiles runtime rotates content to Z-up. Author in ENU (x east, y north, z up) -> glTF (x, z, -y).
    m.vertices = np.column_stack([v[:, 0], v[:, 2], -v[:, 1]])
    fn = f"b_{i}_{j}.glb"
    m.export(os.path.join(out, fn))
    x0, y0 = i * a.tile_m, j * a.tile_m
    children.append({
        "boundingVolume": {"box": [x0 + a.tile_m / 2, y0 + a.tile_m / 2, zmax / 2, a.tile_m / 2, 0, 0, 0, a.tile_m / 2, 0, 0, 0, zmax / 2]},
        "geometricError": 0, "content": {"uri": fn}})
half = a.radius_km * 1000 + a.tile_m
tileset = {
    "asset": {"version": "1.1", "generator": "godseye-tiles buildings.py"},
    "geometricError": 800,
    "root": {
        "transform": enu_to_ecef_matrix(lat0, lon0, 0.0),
        "boundingVolume": {"box": [0, 0, 40, half, 0, 0, 0, half, 0, 0, 0, 40]},
        "geometricError": 200, "refine": "ADD", "children": children}}
with open(os.path.join(out, "tileset.json"), "w") as f: json.dump(tileset, f)
write_meta(out, {"kind": "tileset", "name": f"{a.name} · OSM buildings", "url": "tileset.json", "bbox": bbox, "tiles": len(children), "credit": "© OpenStreetMap contributors"})
print("done", out, len(children), "tiles")
