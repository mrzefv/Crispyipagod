# godseye-tiles

Hand-rolled, keyless tile stacks for GodsEye, built on GitHub Actions and served from GitHub Pages.

| Stack | Source | Output |
|---|---|---|
| `naip` | USDA NAIP aerial imagery (public domain) via Planetary Computer | XYZ raster tiles `{z}/{x}/{y}.png` |
| `lidar` | USGS 3DEP lidar COPC via Planetary Computer | 3D Tiles point cloud (`tileset.json` + `.pnts`) |
| `buildings` | OpenStreetMap footprints + heights via Overpass | 3D Tiles 1.1 extruded glTF (`tileset.json` + `.glb`) |

## Setup (phone only)
1. New repo `godseye-tiles` → upload this folder.
2. Settings → Pages → Source: **Deploy from a branch** → branch `gh-pages` / root. (First run creates the branch.)
3. Actions → **Build tiles** → Run workflow: name, lat, lon, radius, which stacks.
4. `https://<you>.github.io/godseye-tiles/catalog.json` lists everything built. GodsEye reads it (Settings → 3D Scene → catalog URL) and shows each stack as a basemap pill / tileset toggle.

Each run adds an area; existing areas on `gh-pages` are kept. Keep radius ≤ 3 km for z19 raster (Pages soft limit ~1 GB).
