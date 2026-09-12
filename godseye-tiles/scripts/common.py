import math, json, os

def bbox_from(lat, lon, radius_km):
    dlat = radius_km / 110.574
    dlon = radius_km / (111.320 * math.cos(math.radians(lat)))
    return [lon - dlon, lat - dlat, lon + dlon, lat + dlat]

def stac_search(collection, bbox, limit=50, extra=None):
    import requests
    body = {"collections": [collection], "bbox": bbox, "limit": limit,
            "sortby": [{"field": "datetime", "direction": "desc"}]}
    if extra: body.update(extra)
    r = requests.post("https://planetarycomputer.microsoft.com/api/stac/v1/search", json=body, timeout=60)
    r.raise_for_status()
    return r.json().get("features", [])

def sign(href):
    import planetary_computer as pc
    return pc.sign(href)

def write_meta(folder, meta):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

# ENU (east, north, up) -> ECEF 4x4, column-major flat list (== Cesium eastNorthUpToFixedFrame)
def enu_to_ecef_matrix(lat, lon, h=0.0):
    a, e2 = 6378137.0, 6.69437999014e-3
    la, lo = math.radians(lat), math.radians(lon)
    sl, cl, sp, cp = math.sin(lo), math.cos(lo), math.sin(la), math.cos(la)
    N = a / math.sqrt(1 - e2 * sp * sp)
    x0 = (N + h) * cp * cl; y0 = (N + h) * cp * sl; z0 = (N * (1 - e2) + h) * sp
    east = (-sl, cl, 0.0); north = (-sp * cl, -sp * sl, cp); up = (cp * cl, cp * sl, sp)
    return [east[0], east[1], east[2], 0, north[0], north[1], north[2], 0, up[0], up[1], up[2], 0, x0, y0, z0, 1]
