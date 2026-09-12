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
                    Toggle("Performance mode", isOn: $s.performanceMode)
                        .onChange(of: s.performanceMode) { _, _ in s.startPolling() }
                } header: { Text("Performance") } footer: {
                    Text(s.performanceMode
                         ? "Flat terrain · up to 250 aircraft / 200 ships when zoomed in · 30s polling · 5s orbit ticks. Recommended on iPhone XS-era devices."
                         : "3D terrain · up to 600 aircraft / 400 ships · 15s polling · 3s orbit ticks. Heavier on older devices.")
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
                             "“Replay the launch”"], id: \.self) { t in
                        Text(t).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                Section("Sources") {
                    ForEach(Layer.allCases) { l in LabeledContent(l.title, value: l.source) }
                    LabeledContent("Basemap / geocoding", value: "Apple Maps")
                    LabeledContent("Speech", value: "On-device (Apple)")
                }

                Section {
                    LabeledContent("App", value: "GodsEye 1.2.0")
                    LabeledContent("Build", value: "MRzefv")
                    LabeledContent("Deep links", value: "godseye://view?…")
                    LabeledContent("Inspired by", value: "gods-eye-view (MIT)")
                    Text("Exploratory visualization of public data. Feeds may be delayed, incomplete, or wrong. Not for flight, maritime, emergency, or other safety-critical use. No people tracking — assets, events, and infrastructure only.")
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
