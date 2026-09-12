# GodsEye — iOS (IPA)

Native SwiftUI port of the God's Eye View concept: live globe, keyless public feeds, timeline replay, bookmarks. Built unsigned on GitHub Actions; sign with your own signer.

## Build (phone-only, GitHub web)

1. New repo → upload this folder's contents (keep `.github/workflows/build.yml` and `project.yml` at the root).
2. Actions → **Build GodsEye IPA** → Run workflow (also runs on every push to `main`).
3. Download `GodsEye.ipa` from the run artifacts, or the stable link:
   `https://github.com/<you>/<repo>/releases/download/latest/GodsEye.ipa`
4. Sign + install with your signer.

Target: iOS 17+. Bundle id `party.mrvek.godseye`.

## Screens

- **Splash** — animated globe, status line, auto-transitions when feeds are primed.
- **Home** — MapKit 3D globe (imagery / hybrid / standard), top bar Search · Layers · Time, bottom panel (center name, coords, LIVE/REPLAY, counts, quick actions). Tap any marker or empty ground for details.
- **Detail sheet** — half-sheet, expandable to full: title, coords, summary, metadata, Save / Timeline / Share, source link, open in Maps.
- **Timeline** — −24h → +72h scrubber, play/pause, event markers (M4.5+ quakes, launches), prev/next jump, GO LIVE. Time state persists on the globe.
- **Saved** — bookmarks, swipe to delete, tap to fly back.
- **Settings** — accent theme, map style, labels, performance mode, offline mode, cache size/clear, sources, about.

## v1.1 additions

- **Layers:** Live Vessels (AISStream key), Satellites (CelesTrak GP + on-device SGP4, ~200 objects incl. stations/visual/weather, ground-track when tracked), Public CCTV (TfL JamCams, live stills), Traffic flow (Apple basemap).
- **Tracking:** Track any aircraft/ship/satellite — camera lock, fading trail, 1 Hz dead-reckoning between polls, contact feed follows the target. Cockpit/chase camera (pitch 74°, heading-locked). Prev/Next steps through the nearest-first roster.
- **Contacts roster:** sheet listing everything trackable near map center, filter by kind, one-tap track.
- **Nearest cam handoff:** any detail sheet → nearest public camera.
- **Sensor modes:** Normal / NVG / FLIR / CRT / Noir / Snow over the live map and camera stills. Military HUD with telemetry, crosshair, target block. Detection overlay (boxes + IDs on every marker).
- **Scene director:** auto cinematic tour across ISS, quakes, next launch, live contacts, ships. Any manual pan stops it.
- **Missions:** Live Contacts · Space Missions · Environmental · London Watch (layers + camera preset).
- **Deep links:** `godseye://view?lat=&lon=&d=&h=&p=&layers=&sensor=&target=` — Share includes it; opening the link restores camera, layers, sensor, and re-acquires the target.
- **Voice (on-device, no key):** mic button — "take me to LAX and track the nearest aircraft", "cockpit", "switch to thermal", "turn on ships", "HUD on", "start director", "mark this as target alpha", "clear the map", "nearest camera", "reset globe".
- Aircraft glyphs by class (heli / light / jet / heavy / drone) from ADS-B type codes.

## Feeds (no keys)

| Layer | Source |
|---|---|
| Flights | adsb.lol `/v2/lat/lon/dist/250` around map center |
| Military | adsb.lol `/v2/mil` |
| Earthquakes | USGS `all_day.geojson` |
| ISS | wheretheiss.at |
| Space missions | Launch Library 2 (previous 10 + upcoming 15) |

Last good payload of every feed is cached to disk; offline mode serves cache only.
