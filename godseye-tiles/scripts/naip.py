#!/usr/bin/env python3
"""NAIP (USDA, public domain) -> XYZ raster tiles via Planetary Computer STAC + GDAL."""
import argparse, os, subprocess, sys
from common import bbox_from, stac_search, sign, write_meta

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True); ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True); ap.add_argument("--radius-km", type=float, default=1.5)
ap.add_argument("--zoom", default="12-19")
a = ap.parse_args()

bbox = bbox_from(a.lat, a.lon, a.radius_km)
items = stac_search("naip", bbox, limit=40)
if not items:
    print("No NAIP coverage here"); sys.exit(0)
def yr(i): return str(i["properties"].get("naip:year") or i["properties"]["datetime"][:4])
year = yr(items[0])
hrefs = [sign(i["assets"]["image"]["href"]) for i in items if yr(i) == year]
print(f"NAIP {year}: {len(hrefs)} scenes")
os.makedirs("work", exist_ok=True)
srcs = [f"/vsicurl/{h}" for h in hrefs]
env = dict(os.environ, GDAL_HTTP_MULTIRANGE="YES", GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF")
# Mosaic + crop + reproject to Web Mercator, RGB from bands 1-3 (NAIP is RGBN), alpha for nodata
subprocess.check_call(["gdalwarp", "-q", "-t_srs", "EPSG:3857", "-te", *map(str, bbox), "-te_srs", "EPSG:4326",
                       "-r", "bilinear", "-dstalpha", "-ot", "Byte", "-multi", "-wo", "NUM_THREADS=ALL_CPUS",
                       "-co", "TILED=YES", "-co", "COMPRESS=DEFLATE", *srcs, "work/naip_rgbn.tif"], env=env)
subprocess.check_call(["gdal_translate", "-q", "-b", "1", "-b", "2", "-b", "3", "-b", "5", "-colorinterp", "red,green,blue,alpha",
                       "-co", "TILED=YES", "-co", "COMPRESS=DEFLATE", "work/naip_rgbn.tif", "work/naip_rgba.tif"], env=env)
out = f"site/{a.name}/naip"
os.makedirs(out, exist_ok=True)
subprocess.check_call(["gdal2tiles.py", "--xyz", "-z", a.zoom, "-r", "bilinear", "--processes=4", "-w", "none", "-q", "work/naip_rgba.tif", out])
zmin, zmax = a.zoom.split("-")
write_meta(out, {"kind": "raster", "name": f"{a.name} · NAIP {year}", "bbox": bbox, "minZoom": int(zmin), "maxZoom": int(zmax),
                 "template": "{z}/{x}/{y}.png", "credit": f"USDA NAIP {year}"})
print("done", out)
