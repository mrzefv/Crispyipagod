import SwiftUI

// MARK: - Saved

struct SavedView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        NavigationStack {
            Group {
                if s.bookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing saved", systemImage: "bookmark")
                    } description: {
                        Text("Tap any contact, event, camera, or location on the globe and hit Save.")
                    }
                } else {
                    List {
                        ForEach(s.bookmarks) { b in
                            Button { open(b) } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9).fill(b.kind.color.opacity(0.15))
                                        Image(systemName: b.kind.icon).foregroundStyle(b.kind.color)
                                    }
                                    .frame(width: 38, height: 38)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(b.title).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                        Text(b.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(Fmt.coord(b.lat, b.lon) + " · " + Fmt.rel.localizedString(for: b.savedAt, relativeTo: Date()))
                                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onDelete { s.removeBookmarks(at: $0) }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Saved")
            .toolbar { if !s.bookmarks.isEmpty { EditButton() } }
        }
    }

    private func open(_ b: Bookmark) {
        let e = s.entity(forBookmark: b)
        s.tab = 0
        Task { try? await Task.sleep(nanoseconds: 250_000_000); s.select(e) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var s: AppState
    @State private var confirmClear = false
    @State private var keyDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Theme") {
                    Picker("Accent", selection: $s.accentRaw) {
                        Text("NVG Green").tag("green")
                        Text("Amber").tag("amber")
                        Text("Cyan").tag("cyan")
                        Text("White").tag("white")
                    }
                    Toggle("Show labels on globe", isOn: $s.showLabels)
                }

                Section {
                    Picker("Map style", selection: $s.mapStyleRaw) {
                        Text("Satellite imagery").tag("imagery")
                        Text("Hybrid (imagery + roads)").tag("hybrid")
                        Text("Standard dark").tag("standard")
                    }
                    .pickerStyle(.inline).labelsHidden()
                } header: { Text("Map style") } footer: {
                    Text("Traffic layer switches imagery to hybrid automatically so flow colors can render.")
                }

                Section {
                    Picker("Sensor", selection: $s.sensor) {
                        ForEach(SensorMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    Toggle("Military HUD", isOn: $s.hud)
                    Toggle("Detection overlay", isOn: $s.detection)
                } header: { Text("Sensor & overlays") }

                Section {
                    SecureField("AISStream API key", text: $keyDraft)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Save key") { s.aisKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .disabled(keyDraft.isEmpty)
                        Spacer()
                        if !s.aisKey.isEmpty { Button("Remove", role: .destructive) { s.aisKey = ""; keyDraft = "" } }
                    }
                    LabeledContent("Status", value: s.aisKey.isEmpty ? "no key" : s.aisStatus)
                } header: { Text("Power up — Live Vessels") } footer: {
                    Text("Free key at aisstream.io. Stored on-device only; the socket connects straight from your phone to AISStream.")
                }

                Section {
                    Picker("Default basemap", selection: $s.basemap) { ForEach(Basemap.allCases) { Text($0.title).tag($0) } }
                    SecureField("Google Map Tiles API key (Photorealistic 3D without ion)", text: $s.googleMapsKey).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Cesium ion access token", text: $s.ionToken).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Extra ion asset IDs (comma-separated)", text: $s.ionAssets).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                    Toggle("World Terrain", isOn: $s.sceneTerrain)
                    Toggle("OSM Buildings", isOn: $s.sceneBuildings)
                    Toggle("Live contacts in scene", isOn: $s.sceneEntities)
                    Toggle("Property lines in scene", isOn: $s.sceneLines)
                    Button("Open 3D scene") { s.show3D = true }
                } header: { Text("3D Scene — Esri · OSM · Google 3D · ion") } footer: {
                    Text("Esri World Imagery and OSM need no key. Google Photorealistic 3D Tiles, Bing, World Terrain, OSM Buildings and your own ion-hosted tilesets need a free Cesium ion token (ion.cesium.com). Stays on-device.")
                }

                Section {
                    TextField("Catalog URL (godseye-tiles on GitHub Pages)", text: $s.tilesCatalogURL).font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Extra raster template …/{z}/{x}/{y}.png", text: $s.customTileURL).font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Extra tileset.json URLs (comma-separated)", text: $s.customTilesets).font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Hand-rolled tiles") } footer: {
                    Text("Built by the godseye-tiles Actions workflow: NAIP aerial raster, USGS 3DEP lidar point cloud, and OSM extruded buildings, served keyless from GitHub Pages. Every stack in the catalog shows up in the 3D scene as a basemap pill or tileset toggle.")
                }

                Section {
                    SecureField("NASA FIRMS map key", text: $s.firmsKey).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("Fires loaded", value: "\(s.fires.count)")
                } header: { Text("Power up — Active Fires") } footer: { Text("Free at firms.modaps.eosdis.nasa.gov/api/map_key. VIIRS SNPP, trailing 24h, fetched around the view.") }

                Section {
                    SecureField("Anthropic API key", text: $s.anthropicKey).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model", text: $s.aiModel).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("Last readout", value: s.aiSummary.isEmpty ? "—" : s.aiSummary)
                } header: { Text("Power up — AI HUD summary") } footer: { Text("Five-word intelligence readout of the current view, regenerated when the camera settles. Needs HUD on. Key stays on-device; calls go straight to api.anthropic.com.") }

                Section {
                    Toggle("Military contact within 80 km of me", isOn: $s.alertMilitary)
                    Toggle("Earthquake ≥ magnitude", isOn: $s.alertQuakes)
                    if s.alertQuakes {
                        HStack { Text("Threshold"); Slider(value: $s.alertQuakeMag, in: 3...8, step: 0.5); Text(String(format: "%.1f", s.alertQuakeMag)).font(.system(.body, design: .monospaced)) }
                    }
                    Toggle("ISS pass in 10 min", isOn: $s.alertISS)
                    Button("Test notification") { Alerts.shared.requestPermission(); Alerts.shared.fire(id: "test-\(Int(Date().timeIntervalSince1970))", title: "GodsEye", body: "Alerts are working.") }
                } header: { Text("Alerts") } footer: { Text("Checked every poll while the app is open, plus opportunistic background refresh (iOS decides when). Needs location for military/ISS alerts.") }

                Section {
                    LabeledContent("Cameras loaded", value: "\(s.cameras.count) (\(s.cameras.filter(\.isLiveVideo).count) HLS)")
                    LabeledContent("Watched cameras", value: String(s.cctv.watching.count))
                    LabeledContent("Stored frames", value: "\(s.cctv.frameCounts.values.reduce(0, +)) · \(Fmt.bytes(s.cctv.storageBytes))")
                    Picker("Capture interval", selection: Binding(get: { Int(s.cctv.intervalSeconds) }, set: { s.cctv.intervalSeconds = UInt64($0); s.cctv.start() })) {
                        Text("10s").tag(10); Text("20s").tag(20); Text("30s").tag(30); Text("60s").tag(60)
                    }
                    Button("Stop watching all") { s.cctv.watching = [] }.disabled(s.cctv.watching.isEmpty)
                    Button("Delete all recordings", role: .destructive) { s.cctv.clearAll() }
                } header: { Text("CCTV recorder") } footer: {
                    Text("Public feeds keep no history, so GodsEye records its own: every watched camera (and whichever one is open) is snapshotted while the app runs, deduplicated, capped at 400 frames per camera. Playback scrubs those frames; Export stitches them into an MP4. Sources: TfL London, NYC DOT, Caltrans (12 districts, many with live HLS), Austin.")
                }

                Section {
                    Picker("Earthquake window", selection: $s.quakeWindowDays) { Text("24 h").tag(1); Text("7 days").tag(7); Text("30 days (M2.5+)").tag(30) }
                    ForEach(Array(s.quakeClusters.prefix(5).enumerated()), id: \.offset) { _, c in
                        LabeledContent(String(format: "M%.1f %@", c.main.mag, c.main.place), value: "\(c.count) aftershocks")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack { Text("Radar opacity"); Slider(value: $s.radarOpacity, in: 0.2...1) }
                } header: { Text("Seismic & weather") } footer: { Text("Depth rings: red <70 km, orange <300 km, blue deep. Aftershocks = quakes within 100 km / 7 days of a M5+ mainshock. Radar pins to the map when the camera is top-down.") }

                Section {
                    Toggle("Performance mode", isOn: $s.performanceMode)
                        .onChange(of: s.performanceMode) { _, _ in s.startPolling() }
                } header: { Text("Performance") } footer: {
                    Text(s.performanceMode
                         ? "Flat terrain with adaptive density caps · 30s polling · 5s satellite ticks. Recommended on older devices."
                         : "3D terrain with the same adaptive density caps · 20s polling · 4s satellite ticks to reduce spikes while keeping higher visual quality.")
                }

                Section {
                    Toggle("Offline mode", isOn: $s.offlineMode)
                    LabeledContent("Cached feeds", value: "\(FeedCache.fileCount()) files · \(Fmt.bytes(s.cacheBytes))")
                    LabeledContent("Feed errors this session", value: "\(s.feedErrors)")
                    Button("Refresh all feeds now") { Task { await s.refreshAll() } }
                    Button("Clear cache", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Delete all cached feed data?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Clear cache", role: .destructive) { s.clearCache() }
                        }
                } header: { Text("Cache / Offline") } footer: {
                    Text("Offline mode serves the last good payload of every feed (including orbital elements) and stops polling.")
                }

                Section {
                    Button("Reset layers to default") { s.layers = [.flights, .quakes, .satellites, .launches] }
                    Button("Delete all bookmarks", role: .destructive) { s.bookmarks = [] }
                    Button("Clear annotations") { s.clearAnnotations() }
                } header: { Text("Data") }

                Section("Voice commands") {
                    ForEach(["“Take me to LAX and track the nearest aircraft”",
                             "“Track nearest ship” · “Cockpit” · “Stop tracking”",
                             "“Switch to night vision” · “Thermal” · “Normal view”",
                             "“Turn on satellites” · “Hide earthquakes”",
                             "“HUD on” · “Detection off” · “Start director”",
                             "“Mark this as target alpha” · “Clear the map”",
                             "“Nearest camera” · “Reset globe” · “Timeline”",
                             "“Outline Texas” · “How far is LAX from DFW” · “Orbit”",
                             "“Play a radio station near Austin” · “When does the ISS pass”",
                             "“Replay the launch”",
                             "“Turn on radar” · “Space weather” · “Terrain profile”",
                             "“Listen to the police scanner near Chicago”"], id: \.self) { t in
                        Text(t).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                Section("Sources") {
                    ForEach(Layer.allCases) { l in LabeledContent(l.title, value: l.source) }
                    LabeledContent("Basemap / geocoding", value: "Apple Maps")
                    LabeledContent("Speech", value: "On-device (Apple)")
                }

                Section {
                    LabeledContent("App", value: "GodsEye 1.4.0")
                    LabeledContent("Build", value: "MRzefv")
                    LabeledContent("Deep links", value: "godseye://view?…")
                    LabeledContent("Inspired by", value: "gods-eye-view (MIT)")
                    Text("Exploratory visualization of public data. Feeds may be delayed, incomplete, or wrong. Not for flight, maritime, emergency, or other safety-critical use. No live people tracking — parcel owner fields come from public map metadata and may be incomplete.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("About") }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Settings")
            .onAppear { s.cacheBytes = FeedCache.size(); keyDraft = s.aisKey }
        }
    }
}
