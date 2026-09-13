# godseye-tiles

Hand-rolled, keyless tile stacks for GodsEye, built on GitHub Actions and served from GitHub Pages.

| Stack | Source | Output |
|---|---|---|
| `naip` | USDA NAIP aerial imagery (public domain) via Planetary Computer | XYZ raster tiles `{z}/{x}/{y}.png` |
| `lidar` | USGS 3DEP lidar COPC via Planetary Computer | 3D Tiles point cloud (`tileset.json` + `.pnts`) |
| `buildings` | OpenStreetMap footprints + heights via Overpass | 3D Tiles 1.1 extruded glTF (`tileset.json` + `.glb`) |
| `mesh` | 3DEP lidar DSM textured with the NAIP orthophoto | 3D Tiles 1.1 textured mesh — our own photorealistic tiles |
| `trees` | OSM trees + forest/wood/park polygons | 3D Tiles 1.1 instanced low-poly vegetation |
| `models` | procedural (trimesh) | `models/*.glb` library: airliner, heavy, regional, bizjet, ga, heli, fighter, tanker, drone, ships, train, sats, camera, infra, trees |

## Setup (phone only)
1. New repo `godseye-tiles` → upload this folder.
2. Settings → Pages → Source: **Deploy from a branch** → branch `gh-pages` / root. (First run creates the branch.)
3. Actions → **Build tiles** → Run workflow: name, lat, lon, radius, which stacks.
4. `https://<you>.github.io/godseye-tiles/catalog.json` lists everything built. GodsEye reads it (Settings → 3D Scene → catalog URL) and shows each stack as a basemap pill / tileset toggle.

Each run adds an area; existing areas on `gh-pages` are kept. Keep radius ≤ 3 km for z19 raster (Pages soft limit ~1 GB).

## Free keys for every install
Edit `keys.json` on `main` (ion token, Google Map Tiles key, AISStream, FIRMS). Every tiles run copies it to
`https://<you>.github.io/godseye-tiles/keys.json`, and GodsEye fills empty Settings fields from it on launch.
Rotate or blank a key there to revoke it for everyone without a rebuild. Restrict the Google key to the
HTTP referrer `https://mrzefv.com/godseye/*` — that is the base URL the scene page loads under.
