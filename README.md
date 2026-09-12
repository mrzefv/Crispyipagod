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

## Feeds (no keys)

| Layer | Source |
|---|---|
| Flights | adsb.lol `/v2/lat/lon/dist/250` around map center |
| Military | adsb.lol `/v2/mil` |
| Earthquakes | USGS `all_day.geojson` |
| ISS | wheretheiss.at |
| Space missions | Launch Library 2 (previous 10 + upcoming 15) |

Last good payload of every feed is cached to disk; offline mode serves cache only.
