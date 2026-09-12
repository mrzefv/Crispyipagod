import SwiftUI
import MapKit

struct GlobeView: View {
    @EnvironmentObject var s: AppState
    @State private var showSearch = false
    @State private var showLayers = false
    @State private var showMissions = false

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
            sensorOverlay
            topBar
            VStack {
                Spacer()
                BottomPanel(showLayers: $showLayers)
            }
            if s.detectionOverlay || s.tacticalHUD { hudOverlay }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showTimeline) {
                    TimelineView()
                        .presentationDetents([.fraction(0.38), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.38)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
        }
        .sheet(item: $s.selected) { e in
            DetailSheet(entity: e)
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $s.camera, interactionModes: .all) {
                if s.trackTrail.count > 1 {
                    MapPolyline(coordinates: s.trackTrail)
                        .stroke(s.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if s.layers.contains(.flights) || s.layers.contains(.military) {
                    ForEach(s.visibleContacts) { c in
                        Annotation(c.displayName, coordinate: c.coord, anchor: .center) {
                            Image(systemName: "airplane")
                                .font(.system(size: c.military ? 13 : 11, weight: .bold))
                                .foregroundStyle(s.trackedEntityId == "ac-\(c.id)" ? .yellow : (c.military ? Color.orange : s.accent))
                                .rotationEffect(.degrees(c.track - 90))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                                .onTapGesture { s.select(Entity.from(c)) }
                        }
                        .annotationTitles(showContactLabels ? .visible : .hidden)
                    }
                }

                ForEach(s.visibleQuakes) { q in
                    Annotation(String(format: "M%.1f", q.mag), coordinate: q.coord, anchor: .center) {
                        ZStack {
                            Circle().fill(q.color.opacity(0.22))
                                .frame(width: quakeSize(q) * 2, height: quakeSize(q) * 2)
                            Circle().stroke(q.color, lineWidth: 1.5)
                                .frame(width: quakeSize(q), height: quakeSize(q))
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(q)) }
                    }
                    .annotationTitles(q.mag >= 5 && s.showLabels ? .visible : .hidden)
                }

                ForEach(s.visibleSatellites) { sat in
                    Annotation(sat.name, coordinate: sat.coord, anchor: .center) {
                        ZStack {
                            Circle().stroke(Color.cyan.opacity(0.5), lineWidth: 1).frame(width: 30, height: 30)
                            Image(systemName: "sparkle")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(s.trackedEntityId == "sat-\(sat.id)" ? .yellow : .cyan)
                        }
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(sat)) }
                    }
                    .annotationTitles(s.showLabels ? .visible : .hidden)
                }

                ForEach(s.visibleLaunches) { l in
                    Annotation(l.name, coordinate: l.coord, anchor: .bottom) {
                        Image(systemName: l.net > Date() ? "flame" : "flame.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.pink)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .onTapGesture { s.select(Entity.from(l)) }
                    }
                    .annotationTitles(.hidden)
                }

                if s.layers.contains(.cameras) {
                    ForEach(s.visibleCameras) { cam in
                        Annotation(cam.name, coordinate: cam.coord, anchor: .bottom) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color.mint.opacity(0.22)).frame(width: 26, height: 20)
                                Image(systemName: "video.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.mint)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Public camera")
                            .accessibilityValue("\(cam.name), \(cam.city)")
                            .contentShape(Rectangle())
                            .onTapGesture { s.select(Entity.from(cam)) }
                        }
                        .annotationTitles(s.showLabels ? .visible : .hidden)
                    }
                }

                if s.location.coordinate != nil {
                    UserAnnotation()
                }
            }
            .mapStyle(s.mapStyle)
            .mapControls {
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in s.cameraChanged(ctx) }
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) { s.tapPoint(c) }
            }
        }
        .ignoresSafeArea()
    }

    private var showContactLabels: Bool { s.showLabels && s.distance < 250_000 }
    private var hudAircraftCount: Int { (s.layers.contains(.flights) || s.layers.contains(.military)) ? s.visibleContacts.count : 0 }
    private var hudSatelliteCount: Int { s.layers.contains(.satellites) ? s.visibleSatellites.count : 0 }
    private var hudCameraCount: Int { s.layers.contains(.cameras) ? s.visibleCameras.count : 0 }

    private func quakeSize(_ q: Quake) -> CGFloat {
        CGFloat(6 + max(0, q.mag - 1) * 3.2)
    }

    private var sensorOverlay: some View {
        Group {
            switch s.sensorStyle {
            case .normal:
                EmptyView()
            case .nvg:
                Color.green.opacity(0.18).blendMode(.screen).ignoresSafeArea().allowsHitTesting(false)
            case .flir:
                LinearGradient(colors: [.orange.opacity(0.22), .red.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
                    .blendMode(.screen).ignoresSafeArea().allowsHitTesting(false)
            case .crt:
                LinearGradient(colors: [.green.opacity(0.12), .clear, .green.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                .opacity(0.38)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            case .noir:
                Color.black.opacity(0.28).blendMode(.multiply).ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }

    private var hudOverlay: some View {
        VStack {
            HStack {
                if s.detectionOverlay {
                    Text("DETECT \(hudAircraftCount) AC · \(hudSatelliteCount) SAT · \(hudCameraCount) CAM")
                        .font(.caption.monospaced().bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().stroke(s.accent.opacity(0.6), lineWidth: 0.8))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Detection overlay counts")
                        .accessibilityValue("\(hudAircraftCount) aircraft, \(hudSatelliteCount) satellites, \(hudCameraCount) cameras")
                }
                Spacer()
                if s.tacticalHUD, let t = s.trackedEntity {
                    Text("TRACK \(t.title.prefix(12)) · \(Fmt.coord(t.lat, t.lon))")
                        .font(.caption.monospaced().bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().stroke(.orange.opacity(0.7), lineWidth: 0.8))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Tracked target")
                        .accessibilityValue("\(t.title), \(Fmt.coord(t.lat, t.lon))")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 46)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassButton(icon: "magnifyingglass", label: "Search") { showSearch = true }
                .sheet(isPresented: $showSearch) {
                    SearchSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: "square.3.layers.3d", label: "Layers", badge: s.layers.count) { showLayers = true }
                .sheet(isPresented: $showLayers) {
                    LayersSheet()
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: "flag.checkered.2.crossed", label: "Missions") { showMissions = true }
                .sheet(isPresented: $showMissions) {
                    MissionsSheet()
                        .presentationDetents([.fraction(0.35)])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: s.isLive ? "clock" : "clock.badge.exclamationmark",
                        label: s.isLive ? "Time" : "Replay",
                        active: !s.isLive) { s.openTimeline(at: nil) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - Glass button

struct GlassButton: View {
    let icon: String
    let label: String
    var badge: Int? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let b = badge {
                    Text("\(b)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
            }
            .foregroundStyle(active ? Color.black : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                if active { Capsule().fill(.tint) }
                else { Capsule().fill(.ultraThinMaterial) }
            }
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bottom panel

struct BottomPanel: View {
    @EnvironmentObject var s: AppState
    @Binding var showLayers: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.centerName)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                    Text(Fmt.coord(s.center.latitude, s.center.longitude) + "  ·  " + altitudeText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(s.isLive ? s.accent : .orange).frame(width: 6, height: 6)
                        Text(s.isLive ? "LIVE" : "REPLAY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(s.isLive ? s.accent : .orange)
                    }
                    Text(countsText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                QuickAction(icon: "location.fill", title: "Locate") { s.locateMe() }
                QuickAction(icon: "globe", title: "Reset") { s.resetGlobe() }
                QuickAction(icon: "backward.fill", title: "Prev") { s.cycleNearby(forward: false) }
                QuickAction(icon: "forward.fill", title: "Next") { s.cycleNearby(forward: true) }
                QuickAction(icon: s.trackedEntityId == nil ? "scope" : "scope.circle.fill", title: "Track") { s.trackSelected() }
                QuickAction(icon: "video.badge.plus", title: "Cam") { s.handoffToNearestCamera() }
                QuickAction(icon: "arrow.clockwise", title: "Refresh") { Task { await s.refreshAll() } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var altitudeText: String {
        let d = s.distance
        if d > 1_000_000 { return String(format: "%.0f Mm", d / 1_000_000) }
        if d > 1_000 { return String(format: "%.0f km", d / 1_000) }
        return "\(Int(d)) m"
    }

    private var countsText: String {
        var parts: [String] = []
        if s.layers.contains(.flights) || s.layers.contains(.military) { parts.append("\(s.visibleContacts.count) AC") }
        if s.layers.contains(.quakes) { parts.append("\(s.visibleQuakes.count) EQ") }
        if s.layers.contains(.satellites) { parts.append("\(s.visibleSatellites.count) SAT") }
        if s.layers.contains(.cameras) { parts.append("\(s.visibleCameras.count) CAM") }
        if s.layers.contains(.launches) { parts.append("\(s.launches.count) LL") }
        if let t = s.lastUpdate { parts.append(Fmt.rel.localizedString(for: t, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

struct SearchSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var places: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    private var contactMatches: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 2 else { return [] }
        return (s.contacts + s.militaryContacts)
            .filter { $0.callsign.uppercased().hasPrefix(q) || $0.id.uppercased().hasPrefix(q) || ($0.registration ?? "").uppercased().hasPrefix(q) }
            .prefix(8).map { $0 }
    }

    private var launchMatches: [Launch] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3 else { return [] }
        return s.launches.filter { $0.name.lowercased().contains(q) || $0.provider.lowercased().contains(q) }.prefix(5).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if !contactMatches.isEmpty {
                    Section("Contacts") {
                        ForEach(contactMatches) { c in
                            Button { pick(Entity.from(c)) } label: {
                                row(icon: "airplane", color: c.military ? .orange : s.accent,
                                    title: c.displayName, sub: [c.type, c.registration, c.altFt.map { "\($0.formatted()) ft" }].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                }
                if !launchMatches.isEmpty {
                    Section("Missions") {
                        ForEach(launchMatches) { l in
                            Button { pick(Entity.from(l)) } label: {
                                row(icon: "flame", color: .pink, title: l.name, sub: l.provider)
                            }
                        }
                    }
                }
                Section(places.isEmpty ? (searching ? "Searching…" : "Places") : "Places") {
                    ForEach(places, id: \.self) { item in
                        Button { pickPlace(item) } label: {
                            row(icon: "mappin.and.ellipse", color: .white,
                                title: item.name ?? "Unnamed",
                                sub: item.placemark.title ?? Fmt.coord(item.placemark.coordinate.latitude, item.placemark.coordinate.longitude))
                        }
                    }
                    if places.isEmpty && !searching && query.count >= 2 {
                        Text("No places yet — try an airport, city, or landmark.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Airport, city, callsign, ICAO…")
            .onChange(of: query) { _, q in schedule(q) }
        }
    }

    private func row(icon: String, color: Color, title: String, sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.primary)
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    private func schedule(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { places = []; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = trimmed
            req.resultTypes = [.pointOfInterest, .address]
            req.region = MKCoordinateRegion(center: s.center, span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
            let resp = try? await MKLocalSearch(request: req).start()
            guard !Task.isCancelled else { return }
            places = Array((resp?.mapItems ?? []).prefix(12))
            searching = false
        }
    }

    private func pick(_ e: Entity) {
        dismiss()
        Task { try? await Task.sleep(nanoseconds: 300_000_000); s.select(e) }
    }

    private func pickPlace(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        let name = item.name ?? "Location"
        let detail = item.placemark.title ?? ""
        dismiss()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            s.select(Entity.place(lat: c.latitude, lon: c.longitude, name: name, detail: detail, distance: item.pointOfInterestCategory == .airport ? 12_000 : 6_000))
        }
    }
}

// MARK: - Layers

struct LayersSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Layer.allCases) { layer in
                        Toggle(isOn: Binding(
                            get: { s.layers.contains(layer) },
                            set: { on in if on { s.layers.insert(layer) } else { s.layers.remove(layer) } }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: layer.icon).frame(width: 22).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(layer.title).font(.system(.body, design: .monospaced).weight(.semibold))
                                    Text("\(count(layer)) · \(layer.source)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("All layers are keyless public feeds. Data may be delayed or incomplete — not for navigation.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func count(_ l: Layer) -> String {
        switch l {
        case .flights: return "\(s.contacts.filter { !$0.military }.count) in range"
        case .military: return "\(s.militaryContacts.count) worldwide"
        case .satellites: return "\(s.satellites.count) tracked"
        case .quakes: return "\(s.quakes.count) events / 24h"
        case .launches: return "\(s.launches.count) missions"
        case .cameras: return "\(s.cameras.count) overlays"
        }
    }
}

struct MissionsSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(MissionPreset.allCases) { mission in
                    Button {
                        s.applyMission(mission)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mission.icon).foregroundStyle(.tint).frame(width: 22)
                            Text(mission.title).font(.system(.body, design: .monospaced).weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("Mission Presets")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
