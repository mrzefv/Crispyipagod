#!/usr/bin/env python3
"""Scan site/<area>/<layer>/meta.json -> site/catalog.json consumed by the GodsEye app."""
import argparse, os, json, glob
ap = argparse.ArgumentParser(); ap.add_argument("--site", default="site"); ap.add_argument("--base", required=True)
a = ap.parse_args()
rasters, tilesets = [], []
for mp in sorted(glob.glob(os.path.join(a.site, "*", "*", "meta.json"))):
    rel = os.path.relpath(os.path.dirname(mp), a.site).replace(os.sep, "/")
    m = json.load(open(mp))
    base = f"{a.base}/{rel}"
    if m["kind"] == "raster":
        rasters.append({"id": rel, "name": m["name"], "url": f"{base}/{m['template']}", "minZoom": m["minZoom"], "maxZoom": m["maxZoom"], "bbox": m["bbox"], "credit": m.get("credit", "")})
    else:
        tilesets.append({"id": rel, "name": m["name"], "url": f"{base}/{m['url']}", "bbox": m["bbox"], "credit": m.get("credit", ""), "baseHeight": m.get("baseHeight"), "kind": rel.split("/")[-1]})
models = f"{a.base}/models/" if os.path.exists(os.path.join(a.site, "models", "index.json")) else None
cat = {"rasters": rasters, "tilesets": tilesets, "models": models}
json.dump(cat, open(os.path.join(a.site, "catalog.json"), "w"), indent=2)
open(os.path.join(a.site, "index.html"), "w").write("<pre>" + json.dumps(cat, indent=2) + "</pre>")
print(json.dumps({"rasters": len(rasters), "tilesets": len(tilesets)}))
