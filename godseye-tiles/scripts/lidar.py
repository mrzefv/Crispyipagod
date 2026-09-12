#!/usr/bin/env python3
"""USGS 3DEP lidar (public) -> 3D Tiles point cloud via Planetary Computer COPC + laspy + py3dtiles."""
import argparse, os, subprocess, sys
import numpy as np
from common import bbox_from, stac_search, sign, write_meta

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True); ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True); ap.add_argument("--radius-km", type=float, default=1.5)
ap.add_argument("--max-points", type=float, default=12)
a = ap.parse_args()

import laspy
from laspy import CopcReader, Bounds
from pyproj import CRS, Transformer

bbox = bbox_from(a.lat, a.lon, a.radius_km)
items = stac_search("3dep-lidar-copc", bbox, limit=30)
if not items:
    print("No 3DEP COPC coverage here"); sys.exit(0)
cap = int(a.max_points * 1e6)
chunks, epsg, total = [], None, 0
rng = np.random.default_rng(1)
for it in items:
    href = sign(it["assets"]["data"]["href"])
    try:
        with CopcReader.open(href) as r:
            crs = r.header.parse_crs()
            if crs is None:
                print("skip (no CRS)", it["id"]); continue
            e = crs.to_epsg() or (crs.to_2d().to_epsg() if hasattr(crs, "to_2d") else None)
            if e is None: print("skip (no EPSG)", it["id"]); continue
            if epsg is None: epsg = e
            if e != epsg: continue
            tr = Transformer.from_crs(CRS.from_epsg(4326), CRS.from_epsg(e), always_xy=True)
            xs, ys = tr.transform([bbox[0], bbox[2], bbox[0], bbox[2]], [bbox[1], bbox[1], bbox[3], bbox[3]])
            b = Bounds(mins=np.array([min(xs), min(ys)]), maxs=np.array([max(xs), max(ys)]))
            pts = r.query(bounds=b)
            n = len(pts.x)
            print(f"{it['id']}: {n} pts in bbox (EPSG:{e})")
            if n == 0: continue
            if total + n > cap:
                keep = rng.choice(n, size=max(1, cap - total), replace=False)
                pts = pts[np.sort(keep)]; n = len(pts.x)
            chunks.append(pts); total += n
            if total >= cap: break
    except Exception as ex:
        print("skip", it["id"], repr(ex))
if not chunks:
    print("No points"); sys.exit(0)
os.makedirs("work", exist_ok=True)
base = chunks[0]
hdr = laspy.LasHeader(point_format=base.point_format, version=base.header.version)
hdr.scales = base.header.scales; hdr.offsets = base.header.offsets
with laspy.open("work/lidar.laz", mode="w", header=hdr) as w:
    for c in chunks: w.write_points(c.points)
print(f"wrote {total} pts, EPSG:{epsg}")
out = f"site/{a.name}/lidar"
subprocess.check_call(["py3dtiles", "convert", "work/lidar.laz", "--out", out, "--overwrite", "--srs_in", str(epsg), "--srs_out", "4978"])
write_meta(out, {"kind": "tileset", "name": f"{a.name} · 3DEP lidar", "url": "tileset.json", "bbox": bbox, "points": total, "credit": "USGS 3DEP"})
print("done", out)
