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
                        Text("Tap any contact, event, or location on the globe and hit Save.")
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
            .toolbar {
                if !s.bookmarks.isEmpty { EditButton() }
            }
        }
    }

    private func open(_ b: Bookmark) {
        let e = s.entity(forBookmark: b)
        s.tab = 0
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            s.select(e)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var s: AppState
    @State private var confirmClear = false

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
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Map style")
                } footer: {
                    Text("Imagery uses Apple's satellite tiles with 3D terrain where available.")
                }

                Section {
                    Toggle("Performance mode", isOn: $s.performanceMode)
                        .onChange(of: s.performanceMode) { _, _ in s.startPolling() }
                } header: {
                    Text("Performance")
                } footer: {
                    Text(s.performanceMode
                         ? "Flat terrain · up to 250 contacts when zoomed in · 30s polling. Recommended on iPhone XS-era devices."
                         : "3D terrain · up to 600 contacts when zoomed in · 15s polling. Heavier on older devices.")
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
                } header: {
                    Text("Cache / Offline")
                } footer: {
                    Text("Offline mode serves the last good payload of every feed and stops network polling. Turn it off to resume live data.")
                }

                Section {
                    LabeledContent("Default layers", value: s.layers.map(\.title).sorted().joined(separator: ", "))
                    Button("Reset layers to default") { s.layers = [.flights, .quakes, .satellites, .launches] }
                    Button("Delete all bookmarks", role: .destructive) { s.bookmarks = [] }
                } header: {
                    Text("Data")
                }

                Section("Sources") {
                    ForEach(Layer.allCases) { l in
                        LabeledContent(l.title, value: l.source)
                    }
                    LabeledContent("Basemap", value: "Apple Maps")
                    LabeledContent("Geocoding", value: "Apple Maps")
                }

                Section {
                    LabeledContent("App", value: "GodsEye 1.0.1")
                    LabeledContent("Build", value: "MRzefv")
                    LabeledContent("Inspired by", value: "gods-eye-view (MIT)")
                    Text("Exploratory visualization of public data. Feeds may be delayed, incomplete, or wrong. Not for flight, maritime, emergency, or other safety-critical use. No people tracking — assets, events, and infrastructure only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Settings")
            .onAppear { s.cacheBytes = FeedCache.size() }
        }
    }
}
