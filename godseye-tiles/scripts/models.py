#!/usr/bin/env python3
"""Procedural low-poly glTF model library for GodsEye. Nose = +Z, up = +Y, span = X (glTF convention; Cesium rotates)."""
import os, json, math
import numpy as np, trimesh

OUT = "site/models"
os.makedirs(OUT, exist_ok=True)

def paint(m, rgb):
    m.visual.vertex_colors = np.tile(np.array(list(rgb) + [255], dtype=np.uint8), (len(m.vertices), 1)); return m
def box(sz, pos, rgb): return paint(trimesh.creation.box(extents=sz).apply_translation(pos), rgb)
def cylz(r, h, pos, rgb, sec=14): return paint(trimesh.creation.cylinder(radius=r, height=h, sections=sec).apply_translation(pos), rgb)
def cylx(r, h, pos, rgb, sec=12):
    m = trimesh.creation.cylinder(radius=r, height=h, sections=sec); m.apply_transform(trimesh.transformations.rotation_matrix(math.pi/2, [0,1,0])); return paint(m.apply_translation(pos), rgb)
def cyly(r, h, pos, rgb, sec=12):
    m = trimesh.creation.cylinder(radius=r, height=h, sections=sec); m.apply_transform(trimesh.transformations.rotation_matrix(math.pi/2, [1,0,0])); return paint(m.apply_translation(pos), rgb)
def cone(r, h, pos, rgb, sec=14): return paint(trimesh.creation.cone(radius=r, height=h, sections=sec).apply_translation(pos), rgb)
def sphere(r, pos, rgb): return paint(trimesh.creation.icosphere(subdivisions=1, radius=r).apply_translation(pos), rgb)
def wing(span, chord, thick, sweep, pos, rgb, taper=0.5):
    # swept tapered wing as a convex hull of two box sections
    root = trimesh.creation.box(extents=[0.2, thick, chord]).apply_translation([0, 0, 0])
    tipL = trimesh.creation.box(extents=[0.2, thick*0.6, chord*taper]).apply_translation([span/2, 0, -sweep])
    tipR = trimesh.creation.box(extents=[0.2, thick*0.6, chord*taper]).apply_translation([-span/2, 0, -sweep])
    m = trimesh.util.concatenate([root, tipL]).convex_hull
    m2 = trimesh.util.concatenate([root, tipR]).convex_hull
    return paint(trimesh.util.concatenate([m, m2]).apply_translation(pos), rgb)

W = (235, 238, 242); G = (150, 155, 165); D = (60, 68, 84); B = (100, 150, 220); R = (200, 60, 50); K = (30, 32, 36); O = (220, 140, 40)

def airframe(length, fus_r, span, chord, sweep, tail_span, fin_h, engines, wing_y=-0.3, wing_z=0.0, body=W, accent=B, tail_engines=False, hi_wing=False):
    parts = [cylz(fus_r, length, [0, 0, 0], body), cone(fus_r, length*0.16, [0, 0, length/2], body)]
    # tail cone
    tc = trimesh.creation.cone(radius=fus_r, height=length*0.22, sections=14); tc.apply_transform(trimesh.transformations.rotation_matrix(math.pi, [1,0,0])); parts.append(paint(tc.apply_translation([0, 0, -length/2]), body))
    wy = fus_r*0.9 if hi_wing else wing_y
    parts.append(wing(span, chord, chord*0.12, sweep, [0, wy, wing_z], accent))
    parts.append(wing(tail_span, chord*0.55, chord*0.08, sweep*0.6, [0, fus_r*0.6, -length*0.42], accent))
    parts.append(box([0.25, fin_h, chord*0.6], [0, fus_r + fin_h/2, -length*0.42], accent))
    for ex in engines:
        if tail_engines: parts.append(cylz(fus_r*0.45, chord*0.9, [ex, fus_r*0.6, -length*0.32], D))
        else: parts.append(cylz(fus_r*0.5, chord*0.9, [ex, wy - fus_r*0.55, wing_z + chord*0.2], D))
    parts.append(paint(trimesh.creation.box(extents=[fus_r*1.6, fus_r*0.5, fus_r*1.2]).apply_translation([0, fus_r*0.7, length*0.36]), K))  # cockpit glass
    return trimesh.util.concatenate(parts)

def heli():
    parts = [paint(trimesh.creation.capsule(radius=1.3, height=5).apply_transform(trimesh.transformations.rotation_matrix(math.pi/2,[1,0,0])), B)]
    parts.append(box([0.6, 0.7, 6], [0, 0.4, -5.5], B)); parts.append(box([0.2, 1.4, 0.8], [0, 1.2, -8.3], B))
    parts.append(cyly(0.25, 1.0, [0, 1.8, 0], D)); parts.append(box([11, 0.08, 0.35], [0, 2.3, 0], G)); parts.append(box([0.35, 0.08, 11], [0, 2.3, 0], G))
    parts.append(box([0.08, 1.6, 0.25], [0.4, 1.2, -8.3], G)); parts.append(box([3.2, 0.1, 0.1], [0, -1.6, 0.5], K)); parts.append(box([0.1, 0.9, 0.1], [1.2, -1.2, 0.5], K)); parts.append(box([0.1, 0.9, 0.1], [-1.2, -1.2, 0.5], K))
    return trimesh.util.concatenate(parts)

def drone():
    parts = [cylz(0.5, 11, [0,0,0], G), sphere(0.7, [0,0,5], G), wing(20, 1.2, 0.15, 0.2, [0, 0, 0.5], G, taper=0.7), box([0.15, 1.6, 1.2], [0, 0.9, -5], G), box([0.15, 1.6, 1.2], [1.2, -0.6, -5], G), box([0.15, 1.6, 1.2], [-1.2, -0.6, -5], G)]
    return trimesh.util.concatenate(parts)

def fighter():
    parts = [cylz(1.0, 16, [0,0,0], G), cone(1.0, 3.5, [0,0,8], G), wing(11, 5, 0.3, 3.5, [0, -0.2, -2], G, taper=0.3), wing(5, 2.5, 0.2, 1.5, [0, 0, -6.5], G, taper=0.4), box([0.2, 3.5, 3], [0.9, 2.0, -6], G), box([0.2, 3.5, 3], [-0.9, 2.0, -6], G), cylz(0.8, 3, [0.9, -0.1, -8], K), cylz(0.8, 3, [-0.9, -0.1, -8], K), paint(trimesh.creation.box(extents=[1.2, 0.8, 3]).apply_translation([0, 1.1, 3]), K)]
    return trimesh.util.concatenate(parts)

def ship(length, beam, hull=(70, 90, 130), deck=(200, 205, 210), house_len=None, house_h=None, house_z=None, extra=None):
    parts = [box([beam, 3, length], [0, 1.5, 0], hull), paint(trimesh.creation.cone(radius=beam/2, height=length*0.12, sections=6).apply_transform(trimesh.transformations.rotation_matrix(math.pi/2, [1,0,0])).apply_translation([0, 1.5, length/2]), hull)]
    parts.append(box([beam*0.98, 0.3, length*0.98], [0, 3.1, 0], deck))
    hl = house_len or length*0.18; hh = house_h or 8; hz = house_z if house_z is not None else -length*0.32
    parts.append(box([beam*0.7, hh, hl], [0, 3 + hh/2, hz], deck)); parts.append(box([beam*0.5, 2, hl*0.5], [0, 3 + hh + 1, hz], deck)); parts.append(box([0.4, 6, 0.4], [0, 3 + hh + 4, hz], D))
    if extra: parts += extra(length, beam)
    return trimesh.util.concatenate(parts)
def containers(L, Bm):
    out = []; z = -L*0.15
    while z < L*0.36:
        for x in (-Bm*0.3, 0, Bm*0.3):
            for y in range(3): out.append(box([Bm*0.26, 2.4, 6], [x, 3.3 + 1.2 + y*2.5, z], [(200,70,60),(60,110,200),(90,160,90),(220,150,50)][(y + int(z//6)) % 4]))
        z += 6.5
    return out
def tanks(L, Bm): return [cylz(Bm*0.42, 1.6, [0, 3.9, z], (170, 60, 60)) if False else box([Bm*0.8, 1.2, 5], [0, 3.8, z], (150, 60, 60)) for z in np.arange(-L*0.25, L*0.38, 7)] + [box([0.5, 0.5, L*0.7], [0, 5, 0], (230,230,230))]
def cruise(L, Bm): return [box([Bm*0.86, 12, L*0.7], [0, 9, -L*0.02], (245, 245, 245)), box([Bm*0.6, 3, L*0.2], [0, 16.5, -L*0.1], (245,245,245)), cylz(1.2, 4, [0, 19, -L*0.2], (220, 40, 40))]

def train():
    parts = [box([3.2, 3.6, 22], [0, 2.4, 0], (215, 200, 60)), box([3.2, 0.8, 6], [0, 4.4, 8], (90,90,90)), box([2.6, 1.2, 0.6], [0, 3.6, 11.2], K)]
    for z in (-7, 7): parts.append(cylx(0.6, 3.2, [0, 0.6, z], K))
    return trimesh.util.concatenate(parts)

def sat_generic(): return trimesh.util.concatenate([box([1.5, 1.5, 2.5], [0,0,0], (200,180,60)), box([8, 0.05, 1.6], [5.5, 0, 0], (40, 60, 140)), box([8, 0.05, 1.6], [-5.5, 0, 0], (40, 60, 140))])
def iss():
    parts = [cylz(2.2, 40, [0,0,0], (200,200,205)), box([0.6, 0.6, 108], [0, 0, 0], (120,120,130))]
    for x in (-40, -20, 20, 40): parts.append(box([0.05, 12, 34], [x, 0, 0], (60, 70, 140)))
    return trimesh.util.concatenate(parts)
def starlink(): return trimesh.util.concatenate([box([1.3, 0.2, 2.8], [0,0,0], (150,150,160)), box([2.8, 0.05, 8.5], [0, 1.2, 0], (40,60,140))])

def camera(): return trimesh.util.concatenate([cyly(0.12, 6, [0, 3, 0], G), box([0.8, 0.3, 0.3], [0, 6.2, 0], G), sphere(0.35, [0, 5.8, 0.4], K)])
def substation(): return trimesh.util.concatenate([box([20, 0.2, 20], [0,0.1,0], (120,120,120))] + [box([0.5, 8, 0.5], [x, 4, z], (170,170,175)) for x in (-6, 6) for z in (-6, 6)] + [box([2, 3, 4], [0, 1.5, 0], (100,100,110))])
def datacenter(): return trimesh.util.concatenate([box([40, 8, 60], [0, 4, 0], (140, 145, 150))] + [box([3, 1.5, 3], [x, 8.8, z], (90,90,95)) for x in range(-15, 16, 10) for z in range(-24, 25, 12)])
def dam(): return trimesh.util.concatenate([box([60, 20, 8], [0, 10, 0], (170, 165, 155))] + [box([4, 6, 2], [x, 22, 0], (120,120,120)) for x in range(-24, 25, 12)])
def tree(kind):
    if kind == "conifer": return trimesh.util.concatenate([cyly(0.25, 3, [0, 1.5, 0], (90, 60, 35)), cone(2.2, 6, [0,0,0], (40, 95, 45)).apply_transform(trimesh.transformations.rotation_matrix(-math.pi/2, [1,0,0])).apply_translation([0, 3, 0])])
    return trimesh.util.concatenate([cyly(0.3, 3.5, [0, 1.75, 0], (95, 65, 40)), sphere(3.0, [0, 6, 0], (55, 125, 55))])

MODELS = {
    # aircraft (scale ~ real metres)
    "airliner":   lambda: airframe(38, 1.9, 36, 6.5, 6, 13, 6, [-6.5, 6.5]),
    "heavy":      lambda: airframe(64, 3.2, 62, 10, 12, 22, 10, [-12, -22, 12, 22]),
    "regional":   lambda: airframe(30, 1.5, 26, 4.5, 4, 10, 5, [-3, 3], tail_engines=True),
    "bizjet":     lambda: airframe(19, 1.0, 18, 3.2, 3, 7, 4, [-1.8, 1.8], tail_engines=True),
    "ga":         lambda: airframe(8.5, 0.7, 11, 1.6, 0.2, 3.6, 1.8, [], hi_wing=True, body=W, accent=(200,60,50)),
    "heli":       heli,
    "fighter":    fighter,
    "tanker":     lambda: airframe(46, 2.2, 40, 7, 8, 14, 7, [-8, -14, 8, 14], accent=G, body=G),
    "drone":      drone,
    # ships
    "container":  lambda: ship(300, 42, extra=containers),
    "tanker_ship":lambda: ship(250, 44, extra=tanks),
    "cruise":     lambda: ship(290, 36, hull=(30,40,70), extra=cruise),
    "tug":        lambda: ship(30, 11, hull=(40,40,45), house_len=8, house_h=6, house_z=2),
    "fishing":    lambda: ship(24, 7, hull=(60,90,140), house_len=6, house_h=4, house_z=4),
    "yacht":      lambda: ship(40, 9, hull=(240,240,245), deck=(230,225,215), house_len=14, house_h=5, house_z=-2),
    "vessel":     lambda: ship(90, 16),
    # others
    "train": train, "sat": sat_generic, "iss": iss, "starlink": starlink,
    "camera": camera, "substation": substation, "datacenter": datacenter, "dam": dam,
    "tree_conifer": lambda: tree("conifer"), "tree_broadleaf": lambda: tree("broadleaf"),
}

index = {}
for name, fn in MODELS.items():
    m = fn()
    m.export(os.path.join(OUT, f"{name}.glb"))
    ext = m.bounding_box.extents
    index[name] = {"file": f"{name}.glb", "length_m": round(float(ext[2]), 1), "span_m": round(float(ext[0]), 1)}
json.dump({"models": index, "generator": "godseye-tiles models.py"}, open(os.path.join(OUT, "index.json"), "w"), indent=1)
print("models:", len(index))
