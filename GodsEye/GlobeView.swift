import SwiftUI
import MapKit

struct GlobeView: View {
    @EnvironmentObject var s: AppState
    @State private var showSearch = false
    @State private var showLayers = false
    @State private var showModes = false

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
                .modifier(SensorFilter(mode: s.sensor))
            SensorOverlay(mode: s.sensor)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            if s.hud { HUDView().allowsHitTesting(false) }

            VStack(spacing: 8) {
                topBar
                if s.isTracking { TrackingBar() }
                Spacer()
                if let t = s.toast { ToastView(text: t).transition(.move(edge: .bottom).combined(with: .opacity)) }
                BottomPanel(showLayers: $showLayers, showModes: $showModes)
            }
            .animation(.easeInOut(duration: 0.25), value: s.toast)

            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showTimeline) {
                    TimelineView()
                        .presentationDetents([.fraction(0.38), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.38)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showRoster) {
                    RosterSheet()
                        .presentationDetents([.fraction(0.42), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $showModes) {
                    ModesSheet()
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
        }
        .sheet(item: $s.selected) { e in
            DetailSheet(entity: e)
                .presentationDetents([.fraction(0.48), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.48)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .onOpenURL { url in s.open(url: url) }
    }

    // MARK: Map

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $s.camera, interactionModes: .all) {
                // Trails
                if s.trail.count > 1 {
                    MapPolyline(coordinates: s.trail)
                        .stroke(s.trackedEntity?.kind.color ?? s.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                if s.satTrack.count > 1 {
                    MapPolyline(coordinates: s.satTrack)
                        .stroke(Color.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                }

                // Aircraft
                if s.layers.contains(.flights) || s.layers.contains(.military) {
                    ForEach(s.visibleContacts) { c in
                        Annotation(c.displayName, coordinate: c.coord, anchor: .center) {
                            MarkerGlyph(system: c.glyph,
                                        color: c.military ? .orange : s.accent,
                                        size: c.aircraftClass == .heavy ? 15 : 11,
                                        rotation: c.glyph == "airplane" ? c.track - 90 : (c.glyph == "paperplane.fill" ? c.track - 45 : c.track),
                                        id: c.id.uppercased(),
                                        tracked: s.trackedID == "ac-\(c.id)",
                                        detection: s.detection)
                                .onTapGesture { s.select(Entity.from(c)) }
                        }
                        .annotationTitles(showContactLabels ? .visible : .hidden)
                    }
                }

                // Tracked target (dead-reckoned position)
                if let tc = s.trackedCoord, let te = s.trackedEntity, te.kind == .aircraft || te.kind == .military {
                    Annotation("", coordinate: tc, anchor: .center) {
                        Image(systemName: "scope")
                            .font(.system(size: 30, weight: .thin))
                            .foregroundStyle(te.kind.color)
                    }
                    .annotationTitles(.hidden)
                }

                // Ships
                ForEach(s.visibleShips) { v in
                    Annotation(v.displayName, coordinate: v.coord, anchor: .center) {
                        MarkerGlyph(system: "arrowtriangle.up.fill", color: .blue, size: 11,
                                    rotation: v.cog, id: v.id, tracked: s.trackedID == "sh-\(v.id)", detection: s.detection)
                            .onTapGesture { s.select(Entity.from(v)) }
                    }
                    .annotationTitles(s.showLabels && s.distance < 120_000 ? .visible : .hidden)
                }

                // Satellites
                ForEach(s.visibleSatellites) { sat in
                    Annotation(sat.name, coordinate: sat.coord, anchor: .center) {
                        ZStack {
                            if sat.cls == .station {
                                Circle().stroke(Color.cyan.opacity(0.5), lineWidth: 1).frame(width: 30, height: 30)
                            }
                            Image(systemName: sat.cls == .station ? "sparkle" : "circle.fill")
                                .font(.system(size: sat.cls == .station ? 14 : 5, weight: .bold))
                                .foregroundStyle(sat.cls.color)
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                        .overlay { if s.detection { DetectionBox(id: sat.id, color: sat.cls.color) } }
                        .onTapGesture { s.select(Entity.from(sat)) }
                    }
                    .annotationTitles(s.showLabels && (sat.cls == .station || s.distance < 4_000_000) ? .visible : .hidden)
                }

                // Earthquakes
                ForEach(s.visibleQuakes) { q in
                    Annotation(String(format: "M%.1f", q.mag), coordinate: q.coord, anchor: .center) {
                        ZStack {
                            Circle().fill(q.color.opacity(0.22)).frame(width: quakeSize(q) * 2, height: quakeSize(q) * 2)
                            Circle().stroke(q.color, lineWidth: 1.5).frame(width: quakeSize(q), height: quakeSize(q))
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(q)) }
                    }
                    .annotationTitles(q.mag >= 5 && s.showLabels ? .visible : .hidden)
                }

                // Launch pads
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

                // CCTV
                ForEach(s.visibleCameras) { cam in
                    Annotation(cam.name, coordinate: cam.coord, anchor: .center) {
                        ZStack {
                            Circle().fill(Color.purple.opacity(0.25)).frame(width: 22, height: 22)
                            Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
                        }
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(cam)) }
                    }
                    .annotationTitles(.hidden)
                }

                // Voice / manual annotations
                ForEach(s.annotations) { a in
                    Annotation(a.label, coordinate: a.coord, anchor: .bottom) {
                        VStack(spacing: 2) {
                            Text(a.label)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(s.accent))
                                .foregroundStyle(.black)
                            Image(systemName: "mappin").foregroundStyle(s.accent)
                        }
                    }
                    .annotationTitles(.hidden)
                }

                if s.location.coordinate != nil { UserAnnotation() }
            }
            .mapStyle(s.mapStyle)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { ctx in s.cameraChanged(ctx) }
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) { s.tapPoint(c) }
            }
        }
        .ignoresSafeArea()
    }

    private var showContactLabels: Bool { s.showLabels && s.distance < 250_000 }

    private func quakeSize(_ q: Quake) -> CGFloat { CGFloat(6 + max(0, q.mag - 1) * 3.2) }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            GlassButton(icon: "magnifyingglass", label: "Search") { showSearch = true }
                .sheet(isPresented: $showSearch) {
                    SearchSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: "square.3.layers.3d", label: "Layers", badge: s.layers.count) { showLayers = true }
                .sheet(isPresented: $showLayers) {
                    LayersSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: s.isLive ? "clock" : "clock.badge.exclamationmark",
                        label: s.isLive ? "Time" : "Replay",
                        active: !s.isLive) { s.openTimeline(at: nil) }
            VoiceButton(voice: s.voice)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - Marker glyph (+ detection box)

struct MarkerGlyph: View {
    let system: String
    let color: Color
    let size: CGFloat
    let rotation: Double
    let id: String
    let tracked: Bool
    let detection: Bool

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotation))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .overlay {
                if tracked { Circle().stroke(color, lineWidth: 1.5).frame(width: 26, height: 26) }
                if detection { DetectionBox(id: id, color: color) }
            }
    }
}

struct DetectionBox: View {
    let id: String
    let color: Color
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(color.opacity(0.9), lineWidth: 1).frame(width: 24, height: 24)
            Text(id)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 2)
                .background(color)
                .offset(y: -10)
        }
        .frame(width: 24, height: 24)
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
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let b = badge {
                    Text("\(b)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
            }
            .foregroundStyle(active ? Color.black : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                if active { Capsule().fill(.tint) } else { Capsule().fill(.ultraThinMaterial) }
            }
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct VoiceButton: View {
    @ObservedObject var voice: VoiceController

    var body: some View {
        Button { voice.toggle() } label: {
            Image(systemName: voice.listening ? "waveform" : "mic.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(voice.listening ? Color.black : Color.primary)
                .frame(width: 42, height: 36)
                .background { if voice.listening { Capsule().fill(.tint) } else { Capsule().fill(.ultraThinMaterial) } }
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
                .symbolEffect(.variableColor.iterative, isActive: voice.listening)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tracking bar

struct TrackingBar: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        if let e = s.trackedEntity {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(e.kind.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TRACKING · \(e.title)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
                    Text(e.summary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { s.stepRoster(forward: false) } label: { Image(systemName: "chevron.left") }
                Button { s.toggleChase() } label: {
                    Image(systemName: s.chase ? "airplane.departure" : "video")
                        .foregroundStyle(s.chase ? Color.black : Color.primary)
                        .padding(6)
                        .background(Circle().fill(s.chase ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1))))
                }
                Button { s.stepRoster(forward: true) } label: { Image(systemName: "chevron.right") }
                Button { s.stopTracking() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
            .font(.system(size: 14, weight: .semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(e.kind.color.opacity(0.5), lineWidth: 1))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
            .padding(.bottom, 4)
    }
}

// MARK: - Bottom panel

struct BottomPanel: View {
    @EnvironmentObject var s: AppState
    @Binding var showLayers: Bool
    @Binding var showModes: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.centerName)
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                    Text(Fmt.coord(s.center.latitude, s.center.longitude) + "  ·  " + altitudeText)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(s.isLive ? s.accent : .orange).frame(width: 6, height: 6)
                        Text(s.isLive ? "LIVE" : "REPLAY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(s.isLive ? s.accent : .orange)
                        if s.sensor != .normal {
                            Text(s.sensor.title.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12)))
                        }
                    }
                    Text(countsText).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                QuickAction(icon: "location.fill", title: "Locate") { s.locateMe() }
                QuickAction(icon: "globe", title: "Reset") { s.resetGlobe() }
                QuickAction(icon: "list.bullet.rectangle", title: "Contacts") { s.showRoster = true }
                QuickAction(icon: "camera.aperture", title: "Modes", active: s.sensor != .normal || s.hud || s.detection) { showModes = true }
                QuickAction(icon: s.directing ? "stop.fill" : "film", title: "Director", active: s.directing) { s.toggleDirector() }
                QuickAction(icon: "square.3.layers.3d", title: "Layers") { showLayers = true }
            }
        }
        .padding(10)
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
        if s.layers.contains(.ships) { parts.append("\(s.visibleShips.count) SH") }
        if s.layers.contains(.satellites) { parts.append("\(s.visibleSatellites.count) SAT") }
        if s.layers.contains(.quakes) { parts.append("\(s.visibleQuakes.count) EQ") }
        if s.layers.contains(.cctv) { parts.append("\(s.visibleCameras.count) CAM") }
        if let t = s.lastUpdate { parts.append(Fmt.rel.localizedString(for: t, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Color.black : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.06))))
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

    private var satMatches: [Satellite] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 2 else { return [] }
        return s.satellites.filter { $0.name.uppercased().contains(q) || $0.id == q }.prefix(6).map { $0 }
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
                                row(icon: c.glyph, color: c.military ? .orange : s.accent,
                                    title: c.displayName, sub: [c.type, c.registration, c.altFt.map { "\($0.formatted()) ft" }].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                }
                if !satMatches.isEmpty {
                    Section("Satellites") {
                        ForEach(satMatches) { sat in
                            Button { pick(Entity.from(sat)) } label: {
                                row(icon: "sparkle", color: sat.cls.color, title: sat.name, sub: "\(sat.cls.label) · \(Int(sat.altKm)) km")
                            }
                        }
                    }
                }
                if !launchMatches.isEmpty {
                    Section("Missions") {
                        ForEach(launchMatches) { l in
                            Button { pick(Entity.from(l)) } label: { row(icon: "flame", color: .pink, title: l.name, sub: l.provider) }
                        }
                    }
                }
                Section(searching ? "Searching…" : "Places") {
                    ForEach(places, id: \.self) { item in
                        Button { pickPlace(item) } label: {
                            row(icon: "mappin.and.ellipse", color: .white,
                                title: item.name ?? "Unnamed",
                                sub: item.placemark.title ?? Fmt.coord(item.placemark.coordinate.latitude, item.placemark.coordinate.longitude))
                        }
                    }
                    if places.isEmpty && !searching && query.count >= 2 {
                        Text("No places yet — try an airport, city, or landmark.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Airport, city, callsign, ICAO, satellite…")
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

// MARK: - Layers + missions

struct LayersSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Missions") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Mission.allCases) { m in
                                Button { s.run(m) } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: m.icon).font(.title3)
                                        Text(m.title).font(.system(size: 10, weight: .semibold, design: .monospaced)).lineLimit(1)
                                    }
                                    .frame(width: 96, height: 64)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
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
                } header: {
                    Text("Layers")
                } footer: {
                    Text("Everything is keyless except AIS ships (free AISStream key in Settings). Data may be delayed or incomplete — not for navigation.")
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
        case .ships: return s.aisKey.isEmpty ? "needs key" : "\(s.ships.count) · \(s.aisStatus)"
        case .satellites: return "\(s.satellites.count) propagated"
        case .quakes: return "\(s.quakes.count) events / 24h"
        case .launches: return "\(s.launches.count) missions"
        case .cctv: return "\(s.cameras.count) cameras"
        case .traffic: return "live flow on basemap"
        }
    }
}

// MARK: - Modes (sensor / HUD / detection)

struct ModesSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Sensor") {
                    ForEach(SensorMode.allCases) { m in
                        Button { s.sensor = m } label: {
                            HStack {
                                Text(m.key).font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
                                Text(m.title).font(.system(.body, design: .monospaced))
                                Spacer()
                                if s.sensor == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section("Overlays") {
                    Toggle(isOn: $s.hud) { Label("Military HUD", systemImage: "scope") }
                    Toggle(isOn: $s.detection) { Label("Detection overlay", systemImage: "viewfinder") }
                }
                Section {
                    Button("Clear annotations") { s.clearAnnotations() }.disabled(s.annotations.isEmpty)
                    Button("Mark map center") { s.annotate("MARK \(s.annotations.count + 1)") }
                } header: { Text("Whiteboard") } footer: {
                    Text("Voice: “mark this as target alpha”, “clear the map”.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Modes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Roster

struct RosterSheet: View {
    @EnvironmentObject var s: AppState
    @State private var kind: String? = nil
    @State private var list: [Entity] = []

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("CONTACTS NEAR CENTER").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Text("\(list.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            }
            Picker("Kind", selection: $kind) {
                Text("All").tag(String?.none)
                Text("Aircraft").tag(String?.some("aircraft"))
                Text("Military").tag(String?.some("military"))
                Text("Ships").tag(String?.some("ship"))
                Text("Sats").tag(String?.some("satellite"))
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in reload() }
            HStack(spacing: 10) {
                Button { s.stepRoster(forward: false, kind: kind) } label: { Label("Prev", systemImage: "backward.fill") }
                Button { s.stepRoster(forward: true, kind: kind) } label: { Label("Next", systemImage: "forward.fill") }
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .buttonStyle(.bordered)
            List(list) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.kind.icon).foregroundStyle(e.kind.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                        Text(e.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(String(format: "%.0f km", e.coord.distance(to: s.center) / 1000))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Button { s.track(e) } label: {
                        Image(systemName: s.trackedID == e.id ? "scope" : "plus.viewfinder")
                            .foregroundStyle(s.trackedID == e.id ? Color.black : Color.primary)
                            .padding(6)
                            .background(Circle().fill(s.trackedID == e.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1))))
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture { s.select(e) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(14)
        .onAppear { reload() }
    }

    private func reload() { list = s.roster(kind: kind, limit: 60) }
}
