#!/usr/bin/env python3
"""OSM building footprints -> PBR-textured buildings (glass, brick, siding, metal, stone; window grids; gabled house roofs;
emissive night windows) -> 3D Tiles 1.1 glb tiles. Keyless, hand-rolled."""
import argparse, os, json, math, requests
import numpy as np, trimesh
from shapely.geometry import Polygon
from PIL import Image, ImageDraw, ImageFilter
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
rng = np.random.default_rng(3)

# ---------------- procedural facade textures ----------------
TEX = 256
def facade_tex(style):
    img = Image.new("RGB", (TEX, TEX)); d = ImageDraw.Draw(img)
    em = Image.new("RGB", (TEX, TEX), (0, 0, 0)); de = ImageDraw.Draw(em)
    cols, rows = 4, 4
    if style == "glass":
        img.paste((70, 95, 120), [0, 0, TEX, TEX])
        for i in range(cols):
            for j in range(rows):
                x0, y0 = i * 64, j * 64
                d.rectangle([x0 + 2, y0 + 2, x0 + 62, y0 + 62], fill=(120 + int(rng.integers(-15, 15)), 150 + int(rng.integers(-15, 15)), 185 + int(rng.integers(-10, 10))))
                d.line([x0 + 2, y0 + 2, x0 + 62, y0 + 2], fill=(200, 215, 230), width=2)
                if rng.random() < 0.45: de.rectangle([x0 + 4, y0 + 4, x0 + 60, y0 + 60], fill=(255, 220, 150))
        mr = (0.85, 0.18)
    elif style == "office":
        img.paste((190, 186, 178), [0, 0, TEX, TEX])
        for i in range(cols):
            for j in range(rows):
                x0, y0 = i * 64, j * 64
                d.rectangle([x0 + 10, y0 + 12, x0 + 54, y0 + 56], fill=(60, 80, 100)); d.rectangle([x0 + 10, y0 + 12, x0 + 54, y0 + 20], fill=(90, 110, 130))
                if rng.random() < 0.55: de.rectangle([x0 + 12, y0 + 22, x0 + 52, y0 + 54], fill=(255, 225, 160))
        mr = (0.05, 0.75)
    elif style == "brick":
        img.paste((150, 78, 62), [0, 0, TEX, TEX])
        for yy in range(0, TEX, 8):
            off = 8 if (yy // 8) % 2 else 0
            for xx in range(-8, TEX, 16):
                d.rectangle([xx + off, yy, xx + off + 14, yy + 6], fill=(150 + int(rng.integers(-18, 18)), 78 + int(rng.integers(-12, 12)), 62 + int(rng.integers(-10, 10))))
        for i in range(cols):
            for j in range(rows):
                x0, y0 = i * 64, j * 64
                d.rectangle([x0 + 18, y0 + 12, x0 + 46, y0 + 52], fill=(40, 55, 70)); d.rectangle([x0 + 16, y0 + 10, x0 + 48, y0 + 13], fill=(220, 220, 215))
                d.line([x0 + 32, y0 + 12, x0 + 32, y0 + 52], fill=(220, 220, 215), width=2)
                if rng.random() < 0.5: de.rectangle([x0 + 20, y0 + 14, x0 + 44, y0 + 50], fill=(255, 210, 140))
        mr = (0.0, 0.9)
    elif style == "siding":
        img.paste((226, 222, 210), [0, 0, TEX, TEX])
        for yy in range(0, TEX, 10): d.line([0, yy, TEX, yy], fill=(200, 196, 186), width=2)
        for i in range(cols):
            for j in range(rows):
                x0, y0 = i * 64, j * 64
                if (i + j) % 2 == 0:
                    d.rectangle([x0 + 18, y0 + 14, x0 + 46, y0 + 50], fill=(55, 70, 85)); d.rectangle([x0 + 15, y0 + 11, x0 + 49, y0 + 53], outline=(250, 250, 250), width=3)
                    d.line([x0 + 32, y0 + 14, x0 + 32, y0 + 50], fill=(250, 250, 250), width=2)
                    if rng.random() < 0.4: de.rectangle([x0 + 19, y0 + 15, x0 + 45, y0 + 49], fill=(255, 215, 150))
        mr = (0.0, 0.85)
    elif style == "metal":
        img.paste((165, 170, 178), [0, 0, TEX, TEX])
        for xx in range(0, TEX, 12): d.line([xx, 0, xx, TEX], fill=(140, 145, 152), width=3)
        d.rectangle([0, 200, TEX, 256], fill=(120, 124, 130))
        for i in range(cols): x0 = i * 64; d.rectangle([x0 + 14, 40, x0 + 50, 70], fill=(50, 60, 70))
        mr = (0.6, 0.55)
    else:  # stone
        img.paste((185, 175, 155), [0, 0, TEX, TEX])
        for yy in range(0, TEX, 24):
            off = 16 if (yy // 24) % 2 else 0
            for xx in range(-32, TEX, 32): d.rectangle([xx + off, yy, xx + off + 30, yy + 22], fill=(185 + int(rng.integers(-14, 14)), 175 + int(rng.integers(-12, 12)), 155 + int(rng.integers(-10, 10))), outline=(140, 130, 115))
        for i in range(cols):
            x0 = i * 64; d.rounded_rectangle([x0 + 22, 30, x0 + 42, 120], radius=10, fill=(60, 50, 90)); d.rounded_rectangle([x0 + 22, 150, x0 + 42, 240], radius=10, fill=(60, 50, 90))
        mr = (0.0, 0.95)
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    return img, em, mr[0], mr[1]

def roof_tex(kind):
    img = Image.new("RGB", (TEX, TEX), (95, 95, 98) if kind == "flat" else (78, 60, 52)); d = ImageDraw.Draw(img)
    if kind == "flat":
        for _ in range(180): x, y = rng.integers(0, TEX, 2); d.point((int(x), int(y)), fill=(110, 110, 112))
        for _ in range(4): x, y = rng.integers(20, 220, 2); d.rectangle([int(x), int(y), int(x) + 24, int(y) + 16], fill=(150, 150, 152), outline=(70, 70, 72))
    else:
        for yy in range(0, TEX, 14): d.line([0, yy, TEX, yy], fill=(58, 44, 38), width=3)
    return img

STYLES = {}
def material(style):
    if style in STYLES: return STYLES[style]
    if style.startswith("roof_"):
        m = trimesh.visual.material.PBRMaterial(name=style, baseColorTexture=roof_tex(style[5:]), metallicFactor=0.0, roughnessFactor=0.9)
    else:
        img, em, met, rough = facade_tex(style)
        m = trimesh.visual.material.PBRMaterial(name=style, baseColorTexture=img, emissiveTexture=em, emissiveFactor=[1.0, 1.0, 1.0], metallicFactor=met, roughnessFactor=rough)
    STYLES[style] = m; return m

def style_of(t, h, area):
    b = t.get("building", "yes"); mat = (t.get("building:material") or "").lower(); lv = float(t.get("building:levels") or 0)
    if "glass" in mat or (b in ("commercial", "office", "hotel") and (lv >= 6 or h >= 22)): return "glass"
    if b in ("church", "cathedral", "chapel", "civic", "public", "university", "government") or "stone" in mat: return "stone"
    if b in ("industrial", "warehouse", "hangar", "garage", "garages", "shed", "barn", "farm_auxiliary") or "metal" in mat: return "metal"
    if b in ("apartments", "dormitory", "hospital", "school", "retail", "commercial", "office") or "brick" in mat or h > 12: return "brick" if (lv <= 5 and h <= 18) else "office"
    if b in ("house", "detached", "semidetached_house", "terrace", "residential", "bungalow", "cabin", "yes") and area < 420: return "siding"
    return "brick"

def height_of(t):
    for k in ("height", "building:height"):
        if k in t:
            try: return float(str(t[k]).replace("m", "").split()[0])
            except Exception: pass
    if "building:levels" in t:
        try: return max(3.0, float(t["building:levels"]) * 3.3)
        except Exception: pass
    b = t.get("building", "yes")
    return {"house": 6.5, "detached": 6.5, "residential": 7.0, "garage": 3.0, "shed": 2.8, "church": 14.0, "industrial": 9.0, "commercial": 8.0,
            "retail": 6.0, "school": 8.0, "apartments": 12.0, "hospital": 16.0, "office": 14.0, "hotel": 20.0}.get(b, 6.0)

# ---------------- geometry ----------------
tiles = {}
BID = [0]
def add_mesh(key, style, m):
    m.metadata["bid"] = BID[0]
    tiles.setdefault(key, {}).setdefault(style, []).append(m)

def walls(poly, h, style, key):
    rings = [list(poly.exterior.coords)] + [list(i.coords) for i in poly.interiors]
    V, F, UV = [], [], []
    for ring in rings:
        u = 0.0
        for (x0, y0), (x1, y1) in zip(ring[:-1], ring[1:]):
            L = math.hypot(x1 - x0, y1 - y0)
            if L < 0.3: continue
            n = len(V)
            V += [(x0, y0, 0), (x1, y1, 0), (x1, y1, h), (x0, y0, h)]
            UV += [(u / 3.0, 0), ((u + L) / 3.0, 0), ((u + L) / 3.0, h / 3.3), (u / 3.0, h / 3.3)]
            F += [(n, n + 1, n + 2), (n, n + 2, n + 3)]
            u += L
    if not V: return
    m = trimesh.Trimesh(vertices=np.array(V, dtype=np.float64), faces=np.array(F), process=False)
    m.visual = trimesh.visual.TextureVisuals(uv=np.array(UV), material=material(style))
    add_mesh(key, style, m)

def flat_roof(poly, h, key):
    try: V2, F = trimesh.creation.triangulate_polygon(poly, engine="earcut")
    except Exception: return
    V = np.column_stack([V2[:, 0], V2[:, 1], np.full(len(V2), h)])
    uv = (V2 - V2.min(axis=0)) / 12.0
    m = trimesh.Trimesh(vertices=V, faces=F, process=False); m.visual = trimesh.visual.TextureVisuals(uv=uv, material=material("roof_flat"))
    add_mesh(key, "roof_flat", m)
    lip = list(poly.exterior.coords); Vp, Fp = [], []
    for (x0, y0), (x1, y1) in zip(lip[:-1], lip[1:]):
        n = len(Vp); Vp += [(x0, y0, h), (x1, y1, h), (x1, y1, h + 0.6), (x0, y0, h + 0.6)]; Fp += [(n, n + 1, n + 2), (n, n + 2, n + 3)]
    if Vp:
        mp = trimesh.Trimesh(vertices=np.array(Vp, dtype=np.float64), faces=np.array(Fp), process=False)
        mp.visual = trimesh.visual.TextureVisuals(uv=np.zeros((len(Vp), 2)), material=material("roof_flat")); add_mesh(key, "roof_flat", mp)

def gabled_roof(poly, h, key):
    rect = poly.minimum_rotated_rectangle
    if rect.geom_type != "Polygon" or rect.area <= 0: return flat_roof(poly, h, key)
    c = list(rect.exterior.coords)[:4]
    e0 = math.hypot(c[1][0] - c[0][0], c[1][1] - c[0][1]); e1 = math.hypot(c[2][0] - c[1][0], c[2][1] - c[1][1])
    if e0 >= e1: A, B, C, D = c[0], c[1], c[2], c[3]
    else: A, B, C, D = c[1], c[2], c[3], c[0]
    ridge_h = h + min(4.0, max(1.8, 0.45 * min(e0, e1)))
    rA = ((A[0] + D[0]) / 2, (A[1] + D[1]) / 2); rB = ((B[0] + C[0]) / 2, (B[1] + C[1]) / 2)
    V = [(A[0], A[1], h), (B[0], B[1], h), (rB[0], rB[1], ridge_h), (rA[0], rA[1], ridge_h), (D[0], D[1], h), (C[0], C[1], h)]
    F = [(0, 1, 2), (0, 2, 3), (5, 4, 3), (5, 3, 2), (0, 3, 4), (1, 5, 2)]
    L = max(e0, e1); UV = [(0, 0), (L / 6, 0), (L / 6, 1), (0, 1), (0, 0), (L / 6, 0)]
    m = trimesh.Trimesh(vertices=np.array(V, dtype=np.float64), faces=np.array(F), process=False)
    m.fix_normals()
    m.visual = trimesh.visual.TextureVisuals(uv=np.array(UV), material=material("roof_pitched")); add_mesh(key, "roof_pitched", m)

def add(outer, holes, tags):
    pts = [enu(x, y) for x, y in outer]
    if len(pts) < 4: return
    p = Polygon(pts, [[enu(x, y) for x, y in hh] for hh in holes if len(hh) >= 4]).buffer(0)
    if p.is_empty or p.area < 4: return
    h = height_of(tags)
    for pp in ([p] if p.geom_type == "Polygon" else list(p.geoms)):
        if pp.area < 4: continue
        pp = pp if pp.exterior.is_ccw else Polygon(list(pp.exterior.coords)[::-1], [list(i.coords) for i in pp.interiors])
        key = (int(math.floor(pp.centroid.x / a.tile_m)), int(math.floor(pp.centroid.y / a.tile_m)))
        BID[0] += 1
        style = style_of(tags, h, pp.area)
        walls(pp, h, style, key)
        rs = (tags.get("roof:shape") or "").lower()
        pitched = rs in ("gabled", "hipped", "gambrel", "pyramidal") or (rs == "" and style == "siding" and pp.area < 320 and len(pp.exterior.coords) <= 7 and not pp.interiors)
        if pitched: gabled_roof(pp, h, key)
        else: flat_roof(pp, h, key)

for e in els:
    tags = e.get("tags", {})
    if e["type"] == "way" and "geometry" in e: add([(g["lon"], g["lat"]) for g in e["geometry"]], [], tags)
    elif e["type"] == "relation":
        mem = e.get("members", [])
        outers = [[(g["lon"], g["lat"]) for g in m["geometry"]] for m in mem if m.get("role") == "outer" and "geometry" in m]
        inners = [[(g["lon"], g["lat"]) for g in m["geometry"]] for m in mem if m.get("role") == "inner" and "geometry" in m]
        for o in outers: add(o, inners, tags)

# ---------------- export ----------------
out = f"site/{a.name}/buildings"; os.makedirs(out, exist_ok=True)
children = []
def write_textures():
    for style, mat in STYLES.items():
        mat.baseColorTexture.save(os.path.join(out, f"tex_{style}.png"))
        if mat.emissiveTexture is not None: mat.emissiveTexture.save(os.path.join(out, f"tex_{style}_em.png"))
def write_obj(stem, by_style):
    # per-building groups so the native viewer can drop each one onto the terrain
    with open(os.path.join(out, stem + ".mtl"), "w") as f:
        for style in by_style:
            f.write(f"newmtl {style}\nKd 1 1 1\nKa 1 1 1\nKs 0 0 0\nmap_Kd tex_{style}.png\n")
            if not style.startswith("roof_"): f.write(f"map_Ke tex_{style}_em.png\n")
    vo = 0
    with open(os.path.join(out, stem + ".obj"), "w") as f:
        f.write(f"mtllib {stem}.mtl\n")
        for style, ms in by_style.items():
            for m in ms:
                v = m.vertices; uv = m.visual.uv if m.visual.uv is not None else np.zeros((len(v), 2))
                f.write(f"g b{m.metadata.get('bid', 0)}_{style}\nusemtl {style}\n")
                f.write("".join(f"v {x:.3f} {z:.3f} {-y:.3f}\n" for x, y, z in v))
                f.write("".join(f"vt {u:.4f} {1.0 - w:.4f}\n" for u, w in uv))
                f.write("".join(f"f {a1+vo+1}/{a1+vo+1} {b1+vo+1}/{b1+vo+1} {c1+vo+1}/{c1+vo+1}\n" for a1, b1, c1 in m.faces))
                vo += len(v)
for (i, j), by_style in tiles.items():
    write_obj(f"b_{i}_{j}", by_style)
    scene = trimesh.Scene(); zmax = 1.0
    for style, ms in by_style.items():
        m = trimesh.util.concatenate(ms)
        v = m.vertices.copy(); zmax = max(zmax, float(v[:, 2].max()))
        m.vertices = np.column_stack([v[:, 0], v[:, 2], -v[:, 1]])
        m.visual.material = material(style)
        scene.add_geometry(m, node_name=style, geom_name=style)
    fn = f"b_{i}_{j}.glb"
    scene.export(os.path.join(out, fn))
    x0, y0 = i * a.tile_m, j * a.tile_m
    children.append({"boundingVolume": {"box": [x0 + a.tile_m / 2, y0 + a.tile_m / 2, zmax / 2, a.tile_m / 2, 0, 0, 0, a.tile_m / 2, 0, 0, 0, zmax / 2]}, "geometricError": 0, "content": {"uri": fn}})
half = a.radius_km * 1000 + a.tile_m
tileset = {"asset": {"version": "1.1", "generator": "godseye-tiles buildings.py v2 (PBR)"}, "geometricError": 800,
           "root": {"transform": enu_to_ecef_matrix(lat0, lon0, 0.0), "boundingVolume": {"box": [0, 0, 40, half, 0, 0, 0, half, 0, 0, 0, 40]}, "geometricError": 200, "refine": "ADD", "children": children}}
json.dump(tileset, open(os.path.join(out, "tileset.json"), "w"))
write_textures()
write_meta(out, {"kind": "tileset", "name": f"{a.name} · buildings (PBR)", "url": "tileset.json", "bbox": bbox, "tiles": len(children),
                 "center": [lat0, lon0], "tileM": a.tile_m, "half": a.radius_km * 1000, "credit": "© OpenStreetMap contributors · MRzefv"})
print("done", out, len(children), "tiles")
