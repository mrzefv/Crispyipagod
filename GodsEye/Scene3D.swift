import SwiftUI
import WebKit
import CoreLocation

// MARK: - Config

enum Basemap: String, CaseIterable, Identifiable, Codable {
    case esriImagery, esriHybrid, esriStreets, osm, google3D, bingAerial, bingHybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .esriImagery: return "Esri Imagery"
        case .esriHybrid: return "Esri Hybrid"
        case .esriStreets: return "Esri Streets"
        case .osm: return "OSM"
        case .google3D: return "Google 3D"
        case .bingAerial: return "Bing Aerial"
        case .bingHybrid: return "Bing Hybrid"
        }
    }
    var icon: String {
        switch self {
        case .esriImagery, .bingAerial: return "globe.americas.fill"
        case .esriHybrid, .bingHybrid: return "map.fill"
        case .esriStreets, .osm: return "map"
        case .google3D: return "building.2.crop.circle"
        }
    }
    /// Needs a Cesium ion token (Google Photorealistic 3D Tiles and Bing are served through ion).
    var needsIon: Bool { self == .google3D || self == .bingAerial || self == .bingHybrid }
}

enum CesiumConfig {
    static let cesiumVersion = "1.122"
    /// Fallback ion token so nothing breaks if Settings is empty. Paste yours in Settings → 3D Scene.
    static var defaultIonToken: String { BundledKeys.cesiumIon }
    static let googleTilesAsset = 2275207      // Google Photorealistic 3D Tiles via ion
    static let osmBuildingsAsset = 96188       // Cesium OSM Buildings
    /// Fallback Google Map Tiles API key (Photorealistic 3D without ion). Settings → 3D Scene overrides.
    static var defaultGoogleKey: String { BundledKeys.googleMapTiles }
}

enum SceneTool: String, CaseIterable, Identifiable {
    case none, measure, los, probe, scan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Inspect"
        case .measure: return "Measure"
        case .los: return "Line of sight"
        case .probe: return "Height probe"
        case .scan: return "Scan radius"
        }
    }
    var icon: String {
        switch self {
        case .none: return "hand.tap"
        case .measure: return "ruler"
        case .los: return "eye"
        case .probe: return "arrow.up.and.down"
        case .scan: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Hand-rolled tiles catalog (godseye-tiles)

struct TilesCatalog: Decodable, Equatable {
    struct Raster: Decodable, Equatable, Identifiable { let id: String; let name: String; let url: String; let minZoom: Int; let maxZoom: Int; let bbox: [Double]; let credit: String? }
    struct Tileset: Decodable, Equatable, Identifiable { let id: String; let name: String; let url: String; let bbox: [Double]; let credit: String?; let baseHeight: Double?; let kind: String? }
    var rasters: [Raster] = []
    var tilesets: [Tileset] = []
    var models: String? = nil

    static func load(_ url: String) async -> TilesCatalog? {
        guard let u = URL(string: url), !url.isEmpty else { return nil }
        var req = URLRequest(url: u); req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let res = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(TilesCatalog.self, from: res.0)
    }
}

// MARK: - View

struct Scene3DView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var status = "Loading CesiumJS…"
    @State private var selected: Entity?
    @State private var lastCam: (lat: Double, lon: Double, h: Double, heading: Double, pitch: Double)?
    @State private var bridge = CesiumBridge()
    @State private var pushTimer: Timer?
    @State private var trackTimer: Timer?
    @State private var follow = true
    @State private var catalog = TilesCatalog()
    @State private var customRaster: String? = nil
    @State private var cockpit = false
    @State private var dense = false
    @State private var chromeHidden = false
    @State private var tool: SceneTool = .none
    private let realismPresets: [(String, String, String)] = [("off", "Flat", "sun.min"), ("day", "Day", "sun.max.fill"), ("golden", "Golden", "sunset.fill"), ("night", "Night", "moon.stars.fill"), ("overcast", "Overcast", "cloud.fill")]
    @State private var shadows = false
    @State private var shadowHour: Double = 14
    @State private var lastEntityPayload = ""
    @State private var lastEntityRevision = ""
    @State private var lastTrackPayload = ""

    var body: some View {
        ZStack(alignment: .top) {
            CesiumWebView(bridge: bridge, ionToken: s.ionToken, onMessage: handle)
                .ignoresSafeArea()
            if !chromeHidden { controls }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $selected) { e in
            DetailSheet(entity: e)
                .presentationDetents([.fraction(0.48), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.48)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .onChange(of: s.sceneTerrain) { _, v in bridge.eval("GE.setTerrain(\(v))") }
        .onChange(of: s.sceneBuildings) { _, v in bridge.eval("GE.setBuildings(\(v))") }
        .onChange(of: s.sensor) { _, v in bridge.eval("GE.setSensor('\(v.rawValue)')") }
        .onChange(of: s.hud) { _, v in bridge.eval("GE.setHUD(\(v))") }
        .onChange(of: s.sceneEntities) { _, _ in pushEntities() }
        .onChange(of: s.sceneLines) { _, _ in pushEntities() }
        .onChange(of: s.propertyLines) { _, _ in pushEntities() }
        .onChange(of: s.layers.contains(.space)) { _, on in
            guard ready else { return }
            bridge.eval("GE.setSpaceMode(\(jsBool(on)))")
        }
        .onChange(of: s.layers.contains(.simulation)) { _, _ in
            guard ready else { return }
            pushEntities(force: true)
        }
        .onChange(of: s.simulationTick) { _, _ in
            guard ready, s.layers.contains(.simulation) else { return }
            pushEntities(force: true)
        }
        .onChange(of: s.simulationRevision) { _, _ in
            guard ready else { return }
            pushEntities(force: true)
        }
        .onChange(of: ready) { _, isReady in
            guard isReady else { return }
            bridge.eval("GE.setSpaceMode(\(jsBool(s.layers.contains(.space))))")
        }
        .onChange(of: s.trackedID) { _, _ in
            pushEntities(force: true)
            lastTrackPayload = ""
            pushTrack()
        }
        .onChange(of: selected) { _, _ in pushEntities(force: true) }
        .onDisappear { pushTimer?.invalidate(); pushTimer = nil; trackTimer?.invalidate(); trackTimer = nil }
    }

    // MARK: Controls (native strip; the HUD itself is drawn in the page)

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { close() } label: { glyph("xmark") }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Basemap.allCases) { b in
                            pill(b.title, icon: b.icon, active: s.basemap == b && customRaster == nil, tint: .accentColor) {
                                let hasIon = !s.ionToken.isEmpty || !CesiumConfig.defaultIonToken.isEmpty
                                let hasGoogle = !s.googleMapsKey.isEmpty || !CesiumConfig.defaultGoogleKey.isEmpty
                                if b == .google3D && !hasIon && !hasGoogle { status = "Google 3D needs a Cesium ion token or Google Map Tiles key (Settings → 3D Scene)"; return }
                                if b.needsIon && b != .google3D && !hasIon { status = "\(b.title) needs a Cesium ion token (Settings → 3D Scene)"; return }
                                s.basemap = b; customRaster = nil
                                bridge.eval("GE.setBasemap('\(b.rawValue)')")
                            }
                        }
                        ForEach(customRasters, id: \.0) { r in
                            pill(r.1, icon: "square.grid.3x3.fill", active: customRaster == r.0, tint: .green) { selectCustomRaster(r.0, url: r.2, minZ: r.3, maxZ: r.4) }
                        }
                    }
                }
                Menu {
                    Picker("Sensor", selection: $s.sensor) { ForEach(SensorMode.allCases) { m in Text(m.title).tag(m) } }
                    Toggle(isOn: $s.hud) { Label("HUD chrome", systemImage: "scope") }
                    Toggle(isOn: Binding(get: { dense }, set: { dense = $0; pushEntities() })) { Label("All contacts (dense)", systemImage: "circle.grid.3x3.fill") }
                    Toggle(isOn: $s.sceneEntities) { Label("Live contacts", systemImage: "airplane") }
                    Toggle(isOn: $s.sceneLines) { Label("Property lines", systemImage: "rectangle.dashed") }
                    Toggle(isOn: $s.sceneTerrain) { Label("World Terrain (ion)", systemImage: "mountain.2") }
                    Toggle(isOn: $s.sceneBuildings) { Label("OSM Buildings (ion)", systemImage: "building.2") }
                    if !allTilesets.isEmpty {
                        Section("Hand-rolled tilesets") {
                            ForEach(allTilesets, id: \.0) { ts in Toggle(isOn: tilesetBinding(ts.0)) { Label(ts.1, systemImage: "cube") } }
                        }
                    }
                    Divider()
                    Button { bridge.eval("GE.home()") } label: { Label("Look straight down", systemImage: "arrow.down.to.line") }
                    Button { bridge.eval("GE.tilt()") } label: { Label("Tilt 60°", systemImage: "rotate.3d") }
                    Button { Task { await reloadCatalog() } } label: { Label("Reload tiles catalog", systemImage: "arrow.triangle.2.circlepath") }
                    Button { chromeHidden = true; Task { try? await Task.sleep(nanoseconds: 4_000_000_000); chromeHidden = false } } label: { Label("Hide controls 4s", systemImage: "eye.slash") }
                } label: { glyph("slider.horizontal.3") }
                if s.isTracking {
                    Button {
                        follow.toggle()
                        bridge.eval("GE.setFollow(\(follow))")
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: { glyph(follow ? "scope" : "scope").foregroundStyle(follow ? Color.yellow : Color.primary) }
                    Button {
                        cockpit.toggle()
                        bridge.eval("GE.setCockpit(\(cockpit))")
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: { glyph(cockpit ? "airplane.circle.fill" : "airplane.circle") }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SceneTool.allCases) { tl in
                        pill(tl.title, icon: tl.icon, active: tool == tl, tint: .yellow) {
                            tool = tl
                            bridge.eval("GE.setTool('\(tl.rawValue)')")
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    pill(shadows ? "Shadows \(Int(shadowHour)):00Z" : "Shadows", icon: "sun.max", active: shadows, tint: .orange) {
                        shadows.toggle()
                        bridge.eval("GE.setShadows(\(shadows), \(shadowHour))")
                    }
                    if shadows {
                        Slider(value: Binding(get: { shadowHour }, set: { shadowHour = $0; bridge.eval("GE.setShadows(true, \(shadowHour))") }), in: 0...23, step: 1)
                            .frame(width: 120).tint(.orange)
                    }
                    pill("Clear", icon: "xmark.circle", active: false, tint: .gray) { bridge.eval("GE.clearTools()") }
                }
                .padding(.horizontal, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(realismPresets, id: \.0) { r in
                        pill(r.1, icon: r.2, active: s.sceneRealism == r.0, tint: .orange) {
                            s.sceneRealism = r.0
                            bridge.eval("GE.setRealism('\(r.0)')")
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack {
                Text(status).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
            .background(Circle().fill(.ultraThinMaterial))
    }

    private func jsBool(_ value: Bool) -> String { value ? "true" : "false" }
    private func jsQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func pill(_ title: String, icon: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(active ? Color.black : Color.primary)
            .background(Capsule().fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Bridge

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            status = "\(s.basemap.title) · tap to inspect"
            let assets = s.ionAssets.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let basemap = jsQuoted(s.basemap.rawValue)
            let sensor = jsQuoted(s.sensor.rawValue)
            let accent = jsQuoted(s.accentHex)
            let realism = jsQuoted(s.sceneRealism)
            let gkey = jsQuoted(s.googleMapsKey.isEmpty ? CesiumConfig.defaultGoogleKey : s.googleMapsKey)
            bridge.eval("GE.init({basemap:'\(basemap)', terrain:\(s.sceneTerrain), buildings:\(s.sceneBuildings), assets:\(assets), sensor:'\(sensor)', hud:\(s.hud), accent:'\(accent)', googleKey:'\(gkey)', realism:'\(realism)', space:\(jsBool(s.layers.contains(.space)))})")
            let h = max(s.distance, 300)
            bridge.eval(String(format: "GE.setView(%.6f,%.6f,%.1f,%.2f,%.2f)", s.center.latitude, s.center.longitude, h, s.heading, s.pitch))
            pushEntities(force: true)
            pushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in pushEntities() }
            trackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in pushTrack() }
            bridge.eval("GE.setFollow(\(follow))")
            Task { await reloadCatalog() }
        case "tap":
            guard let lat = msg["lat"] as? Double, let lon = msg["lon"] as? Double else { return }
            let d = (msg["height"] as? Double) ?? 3000
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let surf = msg["surface"] as? Double
            let terr = msg["terrain"] as? Double
            Task {
                let r = await s.reverseGeocode(c)
                var meta = r.extraMeta
                if let surf { meta.append(MetaRow("Surface elevation", String(format: "%.1f m · %.0f ft (3D tiles)", surf, surf * 3.281))) }
                if let surf, let terr, surf - terr > 2 { meta.append(MetaRow("Structure height (est.)", String(format: "%.1f m · %.0f ft", surf - terr, (surf - terr) * 3.281))) }
                if let m = msg["mgrs"] as? String { meta.append(MetaRow("MGRS", m)) }
                let e = Entity.place(lat: lat, lon: lon, name: r.title, detail: r.detail, distance: min(max(d * 0.35, 3_000), 600_000), extraMeta: meta)
                selected = e
                s.lookupIntel(for: e)
            }
        case "tool":
            if let text = msg["text"] as? String { status = text; s.show(text) }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case "camera":
            if let lat = msg["lat"] as? Double, let lon = msg["lon"] as? Double, let h = msg["height"] as? Double {
                lastCam = (lat, lon, h, (msg["heading"] as? Double) ?? 0, (msg["pitch"] as? Double) ?? 0)
            }
        case "status":
            if let t = msg["text"] as? String { status = t }
        case "entity":
            if let id = msg["id"] as? String { pickEntity(id) }
        case "track":
            if let id = msg["id"] as? String { trackEntity(id) }
        case "cockpit":
            cockpit = (msg["on"] as? Bool) ?? false
        case "ctx":
            switch msg["action"] as? String {
            case "prev": s.stepRoster(forward: false); UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "next": s.stepRoster(forward: true); UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "nearest": s.trackNearest(kind: msg["kind"] as? String)
            case "stop": s.stopTracking(); cockpit = false; bridge.eval("GE.setCockpit(false)")
            case "cockpit": cockpit.toggle(); bridge.eval("GE.setCockpit(\(cockpit))")
            case "focus": if let tc = s.trackedCoord { bridge.eval(String(format: "GE.focus(%.6f,%.6f)", tc.latitude, tc.longitude)) }
            default: break
            }
        default: break
        }
    }

    private func pickEntity(_ id: String) {
        if let c = (s.contacts + s.militaryContacts).first(where: { "ac-\($0.id)" == id }) { selected = Entity.from(c) }
        else if let v = s.ships.values.first(where: { "sh-\($0.id)" == id }) { selected = Entity.from(v) }
        else if let cam = s.cameras.first(where: { "cam-\($0.id)" == id }) { selected = Entity.from(cam) }
        else if let q = s.visibleQuakes.first(where: { "eq-\($0.id)" == id }) { selected = Entity.from(q) }
        else if let f = s.visibleFires.first(where: { "fire-\($0.id)" == id }) { selected = Entity.from(f) }
        else if let sat = s.visibleSatellites.first(where: { "sat-\($0.id)" == id }) { selected = Entity.from(sat) }
        else if let tr = s.visibleTrains.first(where: { "train-\($0.id)" == id }) { selected = Entity.from(tr) }
        else if let ap = s.visibleAirports.first(where: { "apt-\($0.id)" == id }) { selected = Entity.from(ap) }
        else if let n = s.infra.first(where: { "infra-\($0.id)" == id }) { selected = Entity.from(n) }
        else if let st = s.storms.first(where: { "storm-\($0.id)" == id }) { selected = Entity.from(st) }
        else if let sim = s.simulationContacts.first(where: { "sim-\($0.id)" == id }) { selected = Entity.from(sim) }
    }

    private func trackEntity(_ id: String) {
        if let c = (s.contacts + s.militaryContacts).first(where: { "ac-\($0.id)" == id }) { s.track(Entity.from(c)) }
        else if let v = s.ships.values.first(where: { "sh-\($0.id)" == id }) { s.track(Entity.from(v)) }
        else if let sim = s.simulationContacts.first(where: { "sim-\($0.id)" == id }) { s.track(Entity.from(sim)) }
    }

    private func pushEntities(force: Bool = false) {
        guard ready else { return }
        let entityRevision = [
            "dense:\(dense)",
            "scene:\(s.sceneEntities)",
            "lines:\(s.sceneLines)",
            "sel:\(selected?.id ?? "-")",
            "track:\(s.trackedID ?? "-")",
            "ac:\(s.visibleContacts.prefix(dense ? 500 : 320).map(\.id).joined(separator: ","))",
            "sh:\(s.visibleShips.prefix(dense ? 320 : 220).map(\.id).joined(separator: ","))",
            "eq:\(s.visibleQuakes.prefix(400).map(\.id).joined(separator: ","))",
            "fire:\(s.visibleFires.prefix(600).map(\.id).joined(separator: ","))",
            "sat:\(s.visibleSatellites.prefix(300).map(\.id).joined(separator: ","))",
            "train:\(s.visibleTrains.prefix(300).map(\.id).joined(separator: ","))",
            "apt:\(s.visibleAirports.prefix(200).map(\.id).joined(separator: ","))",
            "infra:\(s.infra.prefix(300).map(\.id).joined(separator: ","))",
            "storm:\(s.storms.prefix(100).map(\.id).joined(separator: ","))",
            "cam:\(s.visibleCameras.prefix(300).map(\.id).joined(separator: ","))",
            "haz:\(s.visibleHazards.prefix(60).map(\.id).joined(separator: ","))",
            "simp:\(s.layers.contains(.simulation) ? s.simulationOverlays.map(\.id).joined(separator: ",") : "off")",
            "sim:\(s.layers.contains(.simulation) ? "\(s.simulationTick):\(s.simulationRevision)" : "off")",
            "props:\(s.propertyLines.count)",
            "regions:\(s.regions.count)"
        ].joined(separator: "|")
        if !force, entityRevision == lastEntityRevision { return }
        lastEntityRevision = entityRevision
        var items: [[String: Any]] = []
        if s.sceneEntities {
            let baseContacts = s.visibleContacts
            let baseContactIDs = Set(baseContacts.map(\.id))
            let extraMilitary = dense ? Array(s.militaryContacts.filter { !baseContactIDs.contains($0.id) }.prefix(120)) : []
            let acs = baseContacts + extraMilitary
            for c in acs.prefix(dense ? 500 : 320) {
                items.append(["id": "ac-\(c.id)", "kind": "ac", "lat": c.lat, "lon": c.lon, "alt": Double(c.altFt ?? 0) * 0.3048,
                              "label": c.displayName, "heading": c.track, "mil": c.military, "spd": c.groundSpeedKt ?? 0, "model": aircraftModel(c),
                              "sub": [c.type ?? "", c.registration ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")])
            }
            let shs = s.visibleShips
            for v in shs.prefix(dense ? 320 : 220) {
                items.append(["id": "sh-\(v.id)", "kind": "sh", "lat": v.lat, "lon": v.lon, "alt": 0, "label": v.displayName, "heading": v.cog, "mil": false, "spd": v.sogKt, "sub": "MMSI \(v.id)", "model": shipModel(v)])
            }
            for q in s.visibleQuakes.prefix(400) {
                items.append(["id": "eq-\(q.id)", "kind": "eq", "lat": q.lat, "lon": q.lon, "alt": 0, "label": String(format: "M%.1f", q.mag), "heading": 0, "mil": false,
                              "sub": "\(Int(q.depthKm)) km · \(q.place)", "r": pow(10, 0.5 * q.mag) * 120])
            }
            for f in s.visibleFires.prefix(600) {
                items.append(["id": "fire-\(f.id)", "kind": "fire", "lat": f.lat, "lon": f.lon, "alt": 0, "label": "FIRE \(Int(f.frp)) MW", "heading": 0, "mil": false, "sub": f.confidence])
            }
            for sat in s.visibleSatellites.prefix(300) {
                items.append(["id": "sat-\(sat.id)", "kind": "sat", "lat": sat.lat, "lon": sat.lon, "alt": sat.altKm * 1000, "label": sat.name, "heading": 0, "mil": false,
                              "sub": "\(sat.cls.label) · \(Int(sat.altKm)) km", "cls": sat.cls.rawValue, "model": sat.cls == .station ? "iss" : sat.cls == .starlink ? "starlink" : "sat"])
            }
            for tr in s.visibleTrains.prefix(300) {
                items.append(["id": "train-\(tr.id)", "kind": "train", "lat": tr.lat, "lon": tr.lon, "alt": 0, "label": tr.name, "heading": 0, "mil": false, "sub": "\(tr.operatorName) · \(Int(tr.speedKmh)) km/h", "model": "train"])
            }
            for ap in s.visibleAirports.prefix(200) {
                items.append(["id": "apt-\(ap.id)", "kind": "apt", "lat": ap.lat, "lon": ap.lon, "alt": 0, "label": ap.iata.isEmpty ? ap.id : ap.iata, "heading": 0, "mil": false, "sub": ap.name])
            }
            for n in s.infra.prefix(300) {
                items.append(["id": "infra-\(n.id)", "kind": "infra", "lat": n.lat, "lon": n.lon, "alt": 0, "label": n.name, "heading": 0, "mil": false, "sub": n.kind.label, "model": n.kind == .dam ? "dam" : n.kind == .datacenter ? "datacenter" : "substation"])
            }
            for st in s.storms.prefix(100) {
                items.append(["id": "storm-\(st.id)", "kind": "storm", "lat": st.lat, "lon": st.lon, "alt": 0, "label": "STORM", "heading": st.headingDeg, "mil": false, "sub": "\(Int(st.speedKmh)) km/h · \(Int(st.intensity)) dBZ"])
            }
            for cam in s.visibleCameras.prefix(300) {
                items.append(["id": "cam-\(cam.id)", "kind": "cam", "lat": cam.lat, "lon": cam.lon, "alt": 0, "label": cam.name, "heading": cam.heading ?? -1, "mil": false,
                              "img": cam.imageURL, "sub": "\(cam.source)\(cam.isLiveVideo ? " · LIVE" : "")", "watch": s.cctv.watching.contains(cam.id), "model": "camera"])
            }
        }
        if s.layers.contains(.simulation) {
            for sim in s.simulationContacts {
                items.append(["id": "sim-\(sim.id)", "kind": "sim", "lat": sim.lat, "lon": sim.lon, "alt": sim.altM, "label": sim.title, "heading": sim.heading, "mil": false, "sub": sim.subtitle, "icon": sim.kind.icon])
            }
        }
        var polys: [[String: Any]] = []
        if s.sceneLines {
            for p in s.propertyLines {
                for ring in p.rings {
                    polys.append(["id": p.id, "kind": p.kind == .building ? "fp" : "parcel", "target": p.isTarget, "coords": ring.flatMap { [$0.longitude, $0.latitude] }])
                }
            }
            for h in s.visibleHazards.prefix(60) {
                for (i, ring) in h.rings.enumerated() {
                    polys.append(["id": "haz-\(h.id)-\(i)", "kind": "hazard", "target": false, "coords": ring.flatMap { [$0.longitude, $0.latitude] }, "label": h.event])
                }
            }
            for r in s.regions {
                for (i, ring) in r.rings.enumerated() {
                    polys.append(["id": "region-\(r.id)-\(i)", "kind": "region", "target": false, "coords": ring.flatMap { [$0.longitude, $0.latitude] }])
                }
            }
        }
        if s.layers.contains(.simulation) {
            for sim in s.simulationOverlays {
                for (i, ring) in sim.rings.enumerated() {
                    polys.append(["id": "\(sim.id)-\(i)", "kind": "sim", "target": false, "coords": ring.flatMap { [$0.longitude, $0.latitude] }])
                }
            }
        }
        var sel: [String: Any] = [:]
        if let e = selected { sel = ["lat": e.lat, "lon": e.lon, "title": e.title, "kind": e.kind.rawValue] }
        let track = trackPayload()
        let passToken = s.layers.contains(.simulation) ? (s.simulationRevision % 10_000) : Int((s.lastUpdate?.timeIntervalSince1970 ?? 0) / 15) % 10_000
        let payload: [String: Any] = ["entities": items, "polys": polys, "selected": sel, "track": track,
                                      "counts": ["ac": s.contacts.count + s.militaryContacts.count, "sh": s.ships.count, "sat": s.satellites.count, "cam": s.cameras.count],
                                      "orb": s.satellites.count, "pass": passToken]
        guard let d = try? JSONSerialization.data(withJSONObject: payload), let js = String(data: d, encoding: .utf8) else { return }
        if !force, js == lastEntityPayload { return }
        lastEntityPayload = js
        bridge.eval("GE.setData(\(js))")
    }

    // MARK: Model mapping (procedural library from godseye-tiles/models)

    private func aircraftModel(_ c: Contact) -> String {
        let t = (c.type ?? "").uppercased()
        switch c.aircraftClass {
        case .heli: return "heli"
        case .drone: return "drone"
        case .light: return "ga"
        case .heavy: return ["K35R", "KC10", "KC46", "A332", "A310"].contains(t) || c.military ? "tanker" : "heavy"
        case .jet: break
        }
        if ["F16", "F15", "F18", "F35", "F22", "EUFI", "RFAL", "GRIP", "TOR", "A10", "F14", "MIG", "SU27", "SU30", "SU35", "T38", "HAWK", "L39"].contains(where: { t.hasPrefix($0) }) { return "fighter" }
        if ["CRJ", "E17", "E19", "E75", "E45", "E35", "DH8", "AT4", "AT7", "AT72", "SF34", "F70", "F100", "B461", "B462", "B463"].contains(where: { t.hasPrefix($0) }) { return "regional" }
        if ["GLF", "GL", "CL3", "CL6", "C5", "C6", "C7", "E55", "E50", "LJ", "FA", "HDJ", "PC12", "PC24", "PRM", "BE4", "H25", "GA5", "GA6", "GALX", "ASTR", "F2TH", "F900", "FA7X", "FA8X"].contains(where: { t.hasPrefix($0) }) { return "bizjet" }
        return "airliner"
    }

    private func shipModel(_ v: Ship) -> String {
        let n = v.name.uppercased()
        if n.contains("TANKER") || n.contains(" OIL") || n.contains("CHEM") || n.contains("LNG") || n.contains("LPG") { return "tanker_ship" }
        if n.contains("MAERSK") || n.contains("MSC ") || n.contains("EVER ") || n.contains("CMA") || n.contains("COSCO") || n.contains("HAPAG") || n.contains("CONTAINER") || n.contains("EXPRESS") { return "container" }
        if n.contains("CRUISE") || n.contains("CARNIVAL") || n.contains("ROYAL") || n.contains("NORWEGIAN") || n.contains("CELEBRITY") || n.contains("PRINCESS") || n.contains("MSC ") && n.contains("SEA") { return "cruise" }
        if n.contains("TUG") || n.contains("TOW") || n.hasPrefix("ATB") { return "tug" }
        if n.contains("FISH") || n.hasPrefix("F/V") || n.contains("TRAWL") || n.contains("SEINER") { return "fishing" }
        if n.contains("YACHT") || n.hasPrefix("M/Y") || n.hasPrefix("S/Y") || n.hasPrefix("MY ") { return "yacht" }
        return "vessel"
    }

    private func trackPayload() -> [String: Any] {
        guard let te = s.trackedEntity, let tc = s.trackedCoord else { return [:] }
        let c = (s.contacts + s.militaryContacts).first { "ac-\($0.id)" == te.id }
        let v = s.ships.values.first { "sh-\($0.id)" == te.id }
        let sim = s.simulationContacts.first { "sim-\($0.id)" == te.id }
        return ["id": te.id, "lat": tc.latitude, "lon": tc.longitude, "alt": sim?.altM ?? Double(c?.altFt ?? 0) * 0.3048,
                "heading": sim?.heading ?? c?.track ?? v?.cog ?? 0, "spd": sim?.speedKt ?? c?.groundSpeedKt ?? v?.sogKt ?? 0, "label": te.title, "kind": te.kind.rawValue,
                "sub": sim?.subtitle ?? [c?.type ?? "", c?.registration ?? "", c?.military == true ? "MILITARY" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                "ts": Date().timeIntervalSince1970,
                "model": c.map { aircraftModel($0) } ?? v.map { shipModel($0) } ?? "",
                "trail": s.trail.suffix(200).flatMap { [$0.longitude, $0.latitude] }]
    }

    /// 1 Hz: only the tracked target — the page dead-reckons between these at frame rate.
    private func pushTrack() {
        guard ready else { return }
        guard s.isTracking else {
            guard !lastTrackPayload.isEmpty else { return }
            lastTrackPayload = ""
            bridge.eval("GE.setTrack({})")
            return
        }
        let tr = trackPayload()
        guard !tr.isEmpty, let d = try? JSONSerialization.data(withJSONObject: tr), let js = String(data: d, encoding: .utf8) else { return }
        if js == lastTrackPayload { return }
        lastTrackPayload = js
        bridge.eval("GE.setTrack(\(js))")
    }

    // MARK: Hand-rolled tiles

    private var customRasters: [(String, String, String, Int, Int)] {
        var out = catalog.rasters.map { ($0.id, $0.name, $0.url, $0.minZoom, $0.maxZoom) }
        let manual = s.customTileURL.trimmingCharacters(in: .whitespaces)
        if manual.contains("{z}") { out.append(("manual-raster", "Custom raster", manual, 0, 22)) }
        return out
    }

    private var allTilesets: [(String, String, String)] {
        var out = catalog.tilesets.map { ($0.id, $0.name, $0.url) }
        for (i, u) in s.customTilesets.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).enumerated() where u.hasPrefix("http") {
            out.append(("manual-ts-\(i)", "Custom tileset \(i + 1)", u))
        }
        return out
    }

    private func tilesetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { s.enabledTilesets.contains(id) }, set: { on in
            if on { s.enabledTilesets.insert(id) } else { s.enabledTilesets.remove(id) }
            pushCustomTilesets()
        })
    }

    private func selectCustomRaster(_ id: String, url: String, minZ: Int, maxZ: Int) {
        customRaster = id
        bridge.eval("GE.setCustomRaster('\(url.replacingOccurrences(of: "'", with: ""))', \(minZ), \(maxZ))")
        status = "\(id) · tap to inspect"
    }

    private func pushCustomTilesets() {
        let wanted = allTilesets.filter { s.enabledTilesets.contains($0.0) }
        let list: [[String: Any]] = wanted.map { w in
            let meta = catalog.tilesets.first { $0.id == w.0 }
            var d: [String: Any] = ["url": w.2, "kind": meta?.kind ?? "custom"]
            if let b = meta?.baseHeight { d["baseHeight"] = b }
            return d
        }
        guard let d = try? JSONSerialization.data(withJSONObject: list), let js = String(data: d, encoding: .utf8) else { return }
        bridge.eval("GE.setCustomTilesets(\(js))")
        if let m = catalog.models { bridge.eval("GE.setModels('\(m.replacingOccurrences(of: "'", with: ""))')") }
    }

    private func reloadCatalog() async {
        if let c = await TilesCatalog.load(s.tilesCatalogURL) {
            catalog = c
            status = "Catalog: \(c.rasters.count) rasters · \(c.tilesets.count) tilesets"
        } else if !s.tilesCatalogURL.isEmpty {
            status = "Tiles catalog not reachable yet (run the godseye-tiles workflow)"
        }
        pushCustomTilesets()
    }

    private func close() {
        if let c = lastCam {
            s.fly(to: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), distance: max(c.h, 300), pitch: min(max(c.pitch, 0), 80), heading: c.heading, duration: 0.6)
        }
        dismiss()
    }
}

// MARK: - WebKit bridge

final class CesiumBridge {
    weak var webView: WKWebView?
    private var queue: [String] = []
    var isReady = false { didSet { if isReady { flush() } } }
    func eval(_ js: String) {
        guard isReady, let webView else { queue.append(js); return }
        webView.evaluateJavaScript(js) { _, _ in }
    }
    private func flush() { let q = queue; queue = []; q.forEach { eval($0) } }
}

struct CesiumWebView: UIViewRepresentable {
    let bridge: CesiumBridge
    let ionToken: String
    let onMessage: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage, bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: "godseye")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.navigationDelegate = context.coordinator
        bridge.webView = wv
        let token = ionToken.isEmpty ? CesiumConfig.defaultIonToken : ionToken
        wv.loadHTMLString(CesiumHTML.page(token: token), baseURL: URL(string: "https://mrzefv.com/godseye/"))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onMessage: ([String: Any]) -> Void
        let bridge: CesiumBridge
        init(onMessage: @escaping ([String: Any]) -> Void, bridge: CesiumBridge) { self.onMessage = onMessage; self.bridge = bridge }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if (body["type"] as? String) == "ready" { bridge.isReady = true }
            onMessage(body)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onMessage(["type": "status", "text": "Load failed: \(error.localizedDescription)"])
        }
    }
}

// MARK: - Page

enum CesiumHTML {
    static func page(token: String) -> String {
        let v = CesiumConfig.cesiumVersion
        let tok = token.replacingOccurrences(of: "'", with: "")
        let google = CesiumConfig.googleTilesAsset
        return #"""
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<link href="https://cesium.com/downloads/cesiumjs/releases/\#(v)/Build/Cesium/Widgets/widgets.css" rel="stylesheet">
<style>
:root{--acc:#59ff73;--ink:#e8f0ea;--dim:rgba(232,240,234,.55);--mono:Menlo,"SF Mono",ui-monospace,monospace}
html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden;-webkit-user-select:none;font-family:var(--mono);color:var(--ink)}
#c{position:absolute;inset:0}
.cesium-widget-credits{opacity:.5;font-size:8px;bottom:env(safe-area-inset-bottom)}
#hud{position:absolute;inset:0;pointer-events:none}
#hud.off{display:none}
#vig{position:absolute;inset:0;background:radial-gradient(ellipse 62% 44% at 50% 47%, rgba(0,0,0,0) 62%, rgba(0,0,0,.55) 78%, rgba(0,0,0,.92) 100%)}
#ring{position:absolute;left:50%;top:47%;width:min(96vw,74vh);height:min(96vw,74vh);transform:translate(-50%,-50%);border-radius:50%;border:1px solid rgba(255,255,255,.18);box-shadow:0 0 0 1px rgba(0,0,0,.4), inset 0 0 40px rgba(0,0,0,.35)}
#ring:before{content:"";position:absolute;inset:-6px;border-radius:50%;border:1px dashed rgba(255,255,255,.10)}
.br{position:absolute;width:18px;height:18px;border-color:rgba(255,255,255,.45);border-style:solid;border-width:0}
.br.tl{left:10px;top:calc(env(safe-area-inset-top) + 92px);border-left-width:1px;border-top-width:1px}
.br.tr{right:10px;top:calc(env(safe-area-inset-top) + 92px);border-right-width:1px;border-top-width:1px}
.br.bl{left:10px;bottom:calc(env(safe-area-inset-bottom) + 34px);border-left-width:1px;border-bottom-width:1px}
.br.brr{right:10px;bottom:calc(env(safe-area-inset-bottom) + 34px);border-right-width:1px;border-bottom-width:1px}
#scan{position:absolute;inset:0;background:repeating-linear-gradient(0deg, rgba(0,0,0,.14) 0 1px, transparent 1px 3px);mix-blend-mode:multiply;opacity:.7}
#grain{position:absolute;inset:0;opacity:.06;background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='120'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>")}
.blk{position:absolute;font-size:9px;letter-spacing:.06em;line-height:1.5;text-shadow:0 0 4px rgba(0,0,0,.9)}
.blk b{font-weight:700;color:#fff}
.blk .a{color:var(--acc)}
.blk .d{color:var(--dim)}
#tl{left:14px;top:calc(env(safe-area-inset-top) + 100px)}
#tr{right:14px;top:calc(env(safe-area-inset-top) + 100px);text-align:right}
#bl{left:14px;bottom:calc(env(safe-area-inset-bottom) + 44px)}
#brt{right:14px;bottom:calc(env(safe-area-inset-bottom) + 44px);text-align:right}
#title{position:absolute;left:0;right:0;top:calc(env(safe-area-inset-top) + 62px);text-align:center;font-size:11px;letter-spacing:.32em;color:#fff;text-shadow:0 0 6px rgba(0,0,0,.9)}
#title small{display:block;font-size:7px;letter-spacing:.3em;color:var(--dim);margin-top:2px}
#mode{position:absolute;right:14px;top:calc(env(safe-area-inset-top) + 62px);font-size:10px;letter-spacing:.2em;color:#fff}
#stat{position:absolute;left:0;right:0;top:calc(env(safe-area-inset-top) + 86px);text-align:center;font-size:8px;letter-spacing:.12em;color:var(--acc);opacity:.9}
#rec{display:inline-block;width:6px;height:6px;border-radius:50%;background:#ff3b30;box-shadow:0 0 6px #ff3b30;margin-right:5px;animation:bl 1.2s infinite}
@keyframes bl{50%{opacity:.25}}
#cross{position:absolute;left:50%;top:47%;transform:translate(-50%,-50%);width:26px;height:26px;opacity:.75}
#cross:before,#cross:after{content:"";position:absolute;background:rgba(255,255,255,.7)}
#cross:before{left:50%;top:0;width:1px;height:100%}#cross:after{top:50%;left:0;height:1px;width:100%}
#cock{position:absolute;inset:0;display:none}
#cock.on{display:block}
#horizon{position:absolute;left:50%;top:50%;width:60vw;height:1px;background:rgba(255,255,255,.55);transform:translate(-50%,-50%)}
#tape{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 70px);text-align:center;font-size:30px;font-weight:700;color:#fff;letter-spacing:.02em;text-shadow:0 0 10px rgba(0,0,0,.9)}
#tape span{display:inline-block;min-width:26vw}
#tape small{display:block;font-size:8px;letter-spacing:.3em;color:var(--dim);font-weight:400}
#compass{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 40px);text-align:center;font-size:9px;letter-spacing:.4em;color:var(--dim);white-space:nowrap;overflow:hidden}
#cockname{position:absolute;left:14px;top:calc(env(safe-area-inset-top) + 100px);font-size:12px;color:#fff;letter-spacing:.1em}
#cockname small{display:block;font-size:8px;color:var(--dim);letter-spacing:.2em}
#ctxp{position:absolute;right:10px;bottom:calc(env(safe-area-inset-bottom) + 96px);width:46vw;max-height:34vh;overflow:hidden;pointer-events:auto;background:rgba(6,8,10,.78);border:1px solid rgba(255,255,255,.14);border-radius:6px;font-size:8px;letter-spacing:.05em;backdrop-filter:blur(6px)}
#ctxp .hd{padding:6px 8px 4px;border-bottom:1px solid rgba(255,255,255,.1);color:var(--dim);letter-spacing:.2em;display:flex;justify-content:space-between;align-items:center}
#ctxp .hd b{color:#fff}
#ctxp .btns{display:flex;gap:4px;padding:5px 6px;border-bottom:1px solid rgba(255,255,255,.08)}
#ctxp button{flex:1;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.14);color:#fff;font:700 8px var(--mono);letter-spacing:.14em;padding:5px 2px;border-radius:3px}
#ctxp button.a{background:var(--acc);color:#000;border-color:var(--acc)}
#ctxp button.r{border-color:#ff3b30;color:#ff8a80}
#ctxp .ls{overflow-y:auto;max-height:calc(34vh - 62px)}
#ctxp .g{padding:5px 8px 2px;color:#fff;font-weight:700;letter-spacing:.14em;display:flex;justify-content:space-between}
#ctxp .g span{color:var(--dim);font-weight:400}
#ctxp .row{display:flex;justify-content:space-between;padding:3px 8px;color:var(--ink);border-top:1px solid rgba(255,255,255,.04)}
#ctxp .row.t{color:var(--acc)}
#ctxp .row i{font-style:normal;color:var(--dim)}
#ctxp .sub{padding:0 8px 4px;color:var(--dim);font-size:7px}
#ctxp.hid .ls,#ctxp.hid .btns{display:none}
</style></head><body>
<div id="c"></div>
<div id="hud">
  <div id="vig"></div><div id="ring"></div>
  <div class="br tl"></div><div class="br tr"></div><div class="br bl"></div><div class="br brr"></div>
  <div id="scan"></div><div id="grain"></div>
  <div id="title">GOD'S EYE <span style="color:var(--acc)">VIEW</span><small>NO PLACE LEFT BEHIND</small></div>
  <div id="mode">NORMAL</div>
  <div id="stat"></div>
  <div id="cross"></div>
  <div class="blk" id="tl"><b>TOP SECRET // SI-TK // NOFORN</b><br><span class="d">KH11-</span><span id="kh">0000</span> <span class="d">OPS-</span><span id="ops">0000</span><br><span class="a" id="modeL">NORMAL</span><br><span class="d" id="ctx">—</span></div>
  <div class="blk" id="tr"><span id="rec"></span><span class="d">REC</span> <b id="clock">—</b><br><span class="d">ORB:</span> <span id="orb">0</span> <span class="d">PASS:</span> <span id="pass">0</span><br><span class="d">AC</span> <span id="nac">0</span> <span class="d">SH</span> <span id="nsh">0</span> <span class="d">SAT</span> <span id="nsat">0</span> <span class="d">CAM</span> <span id="ncam">0</span></div>
  <div class="blk" id="bl"><span class="d">MGRS:</span> <b id="mgrs">—</b><br><span id="ll">—</span><br><span class="d">SRC</span> <span id="src">ESRI</span> <span class="d">DENS</span> <span id="dens">0</span></div>
  <div class="blk" id="brt"><span class="d">GSD:</span> <b id="gsd">—</b> <span class="d">NIIRS:</span> <b id="niirs">—</b><br><span class="d">ALT:</span> <span id="alt">—</span> <span class="d">HDG:</span> <span id="hdg">—</span> <span class="d">PIT:</span> <span id="pit">—</span><br><span class="d">AZ:</span> <span id="az">—</span></div>
  <div id="ctxp" class="hid">
    <div class="hd"><span>CONTEXT</span><b id="ctxt">—</b><span id="ctxtog" style="pointer-events:auto;color:#fff">▾</span></div>
    <div class="btns"><button id="bprev">◀ PREV</button><button id="bfocus" class="a">FOCUS</button><button id="bnext">NEXT ▶</button></div>
    <div class="btns"><button id="bcock">✈ COCKPIT</button><button id="bnear">NEAREST</button><button id="bstop" class="r">STOP</button></div>
    <div class="ls" id="ctxl"></div>
  </div>
  <div id="cock">
    <div id="horizon"></div>
    <div id="cockname"><span id="cname">—</span><small>FIRST PERSON · MILITARY-GRADE TRACK</small></div>
    <div id="tape"><span><b id="cspd">0</b><small>KTS</small></span><span><b id="chdg">0</b><small>HDG</small></span><span><b id="calt">0</b><small>FT</small></span></div>
    <div id="compass" ></div>
  </div>
</div>
<script src="https://cesium.com/downloads/cesiumjs/releases/\#(v)/Build/Cesium/Cesium.js"></script>
<script>
const post = (m) => { try { window.webkit.messageHandlers.godseye.postMessage(m); } catch(e){} };
const TOKEN = '\#(tok)';
if (TOKEN) Cesium.Ion.defaultAccessToken = TOKEN;
const $ = (id) => document.getElementById(id);

// ---------- MGRS (WGS84) ----------
function toMGRS(lat, lon, prec){
  prec = prec || 5;
  if (lat < -80 || lat > 84) return '—';
  const zone = Math.floor((lon + 180) / 6) + 1;
  const a = 6378137, f = 1/298.257223563, k0 = 0.9996, e2 = f*(2-f), ep2 = e2/(1-e2);
  const lonO = ((zone-1)*6 - 180 + 3) * Math.PI/180, la = lat*Math.PI/180, lo = lon*Math.PI/180;
  const N = a/Math.sqrt(1-e2*Math.sin(la)**2), T = Math.tan(la)**2, C = ep2*Math.cos(la)**2, A = Math.cos(la)*(lo-lonO);
  const M = a*((1-e2/4-3*e2*e2/64-5*e2**3/256)*la-(3*e2/8+3*e2*e2/32+45*e2**3/1024)*Math.sin(2*la)+(15*e2*e2/256+45*e2**3/1024)*Math.sin(4*la)-(35*e2**3/3072)*Math.sin(6*la));
  let x = k0*N*(A+(1-T+C)*A**3/6+(5-18*T+T*T+72*C-58*ep2)*A**5/120)+500000;
  let y = k0*(M+N*Math.tan(la)*(A*A/2+(5-T+9*C+4*C*C)*A**4/24+(61-58*T+T*T+600*C-330*ep2)*A**6/720));
  if (lat < 0) y += 10000000;
  const bands = 'CDEFGHJKLMNPQRSTUVWXX';
  const band = bands.charAt(Math.floor((lat+80)/8));
  const set = ((zone-1)%6)+1;
  const cols = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const colIdx = (Math.floor(x/100000) - 1 + ((set-1)%3)*8) % 24;
  const rowBase = (set % 2 === 0) ? 5 : 0;
  const rows = 'ABCDEFGHJKLMNPQRSTUV';
  const rowIdx = (Math.floor(y/100000) + rowBase) % 20;
  const e = Math.floor(x % 100000), n = Math.floor(y % 100000);
  const p = 10**(5-prec);
  return zone + band + ' ' + cols.charAt(colIdx) + rows.charAt(rowIdx) + ' ' + String(Math.floor(e/p)).padStart(prec,'0') + ' ' + String(Math.floor(n/p)).padStart(prec,'0');
}
function dms(v, pos, neg){ const d = Math.abs(v), D = Math.floor(d), M = Math.floor((d-D)*60), S = ((d-D)*60-M)*60; return `${D}°${String(M).padStart(2,'0')}'${S.toFixed(2)}"${v>=0?pos:neg}`; }

// ---------- sprites (boxed labels) ----------
const spriteCache = new Map();
function sprite(text, sub, color, opts){
  opts = opts || {};
  const key = text+'|'+(sub||'')+'|'+color+'|'+(opts.icon||'')+'|'+(opts.w||'');
  if (spriteCache.has(key)) return spriteCache.get(key);
  const dpr = 2, pad = 6, fs = 11, ss = 8;
  const cv = document.createElement('canvas'); const ctx = cv.getContext('2d');
  ctx.font = `700 ${fs}px Menlo, monospace`;
  const tw = ctx.measureText(text).width; ctx.font = `${ss}px Menlo, monospace`; const sw = sub ? ctx.measureText(sub).width : 0;
  const w = Math.ceil(Math.max(tw, sw) + pad*2 + (opts.icon ? 12 : 0)), h = sub ? 30 : 20;
  cv.width = w*dpr; cv.height = (h+6)*dpr; ctx.scale(dpr,dpr);
  ctx.fillStyle = 'rgba(8,10,12,.82)'; roundRect(ctx, 0, 0, w, h, 4); ctx.fill();
  ctx.strokeStyle = color; ctx.lineWidth = 1; roundRect(ctx, .5, .5, w-1, h-1, 4); ctx.stroke();
  ctx.fillStyle = color; ctx.fillRect(0, 0, 3, h);
  // pointer
  ctx.beginPath(); ctx.moveTo(w/2-4, h); ctx.lineTo(w/2+4, h); ctx.lineTo(w/2, h+5); ctx.closePath(); ctx.fillStyle = color; ctx.fill();
  let x = pad + (opts.icon ? 12 : 0);
  if (opts.icon) { ctx.fillStyle = color; ctx.font = `${fs}px Menlo, monospace`; ctx.fillText(opts.icon, pad-1, 14); }
  ctx.fillStyle = '#fff'; ctx.font = `700 ${fs}px Menlo, monospace`; ctx.fillText(text, x, 14);
  if (sub) { ctx.fillStyle = 'rgba(255,255,255,.65)'; ctx.font = `${ss}px Menlo, monospace`; ctx.fillText(sub, x, 25); }
  spriteCache.set(key, cv); return cv;
}
function roundRect(ctx,x,y,w,h,r){ ctx.beginPath(); ctx.moveTo(x+r,y); ctx.arcTo(x+w,y,x+w,y+h,r); ctx.arcTo(x+w,y+h,x,y+h,r); ctx.arcTo(x,y+h,x,y,r); ctx.arcTo(x,y,x+w,y,r); ctx.closePath(); }
// camera thumbnail card: live still framed with a label
async function camCard(url, label){
  const cv = document.createElement('canvas'); const dpr = 2, w = 96, h = 70; cv.width = w*dpr; cv.height = h*dpr; const ctx = cv.getContext('2d'); ctx.scale(dpr,dpr);
  ctx.fillStyle = 'rgba(8,10,12,.9)'; roundRect(ctx,0,0,w,h-6,4); ctx.fill();
  try {
    const img = await loadImg(url + (url.includes('?') ? '&' : '?') + '_t=' + Math.floor(Date.now()/20000));
    ctx.save(); roundRect(ctx,2,2,w-4,h-22,3); ctx.clip(); ctx.drawImage(img, 2, 2, w-4, h-22); ctx.restore();
  } catch(e) { ctx.fillStyle = 'rgba(199,125,255,.25)'; ctx.fillRect(2,2,w-4,h-22); }
  ctx.strokeStyle = '#c77dff'; ctx.lineWidth = 1; roundRect(ctx,.5,.5,w-1,h-7,4); ctx.stroke();
  ctx.fillStyle = '#fff'; ctx.font = '700 8px Menlo, monospace'; ctx.fillText(label.slice(0,18).toUpperCase(), 5, h-11);
  ctx.beginPath(); ctx.moveTo(w/2-4,h-6); ctx.lineTo(w/2+4,h-6); ctx.lineTo(w/2,h); ctx.closePath(); ctx.fillStyle = '#c77dff'; ctx.fill();
  return cv;
}
function loadImg(src){ return new Promise((res, rej) => { const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => res(i); i.onerror = rej; i.src = src; }); }

// ---------- sensor post-process (GLSL) ----------
const SHADERS = {
  nvg: `uniform sampler2D colorTexture; in vec2 v_textureCoordinates; uniform float t;
    float rnd(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }
    void main(){ vec4 c = texture(colorTexture, v_textureCoordinates); float l = dot(c.rgb, vec3(.3,.59,.11)); l = pow(l*1.6, .8);
      float n = (rnd(v_textureCoordinates*vec2(640.,1136.)+t)-.5)*.10; float sl = sin(v_textureCoordinates.y*1100.)*.03;
      vec2 d = v_textureCoordinates-.5; float vg = smoothstep(.75,.35,length(d));
      out_FragColor = vec4(vec3(.05,.95,.25)*(l+n+sl)*vg + vec3(0,.04,0), 1.); }`,
  flir: `uniform sampler2D colorTexture; in vec2 v_textureCoordinates;
    void main(){ vec4 c = texture(colorTexture, v_textureCoordinates); float l = dot(c.rgb, vec3(.3,.59,.11)); l = 1.-l; l = pow(l, 1.4)*1.15;
      vec3 col = mix(vec3(0.,0.,.05), vec3(1.), l); col = mix(col, vec3(1.,.9,.2), smoothstep(.85,1.,l)*.6);
      out_FragColor = vec4(col, 1.); }`,
  crt: `uniform sampler2D colorTexture; in vec2 v_textureCoordinates; uniform float t;
    void main(){ vec2 uv = v_textureCoordinates; vec2 d = uv-.5; uv = uv + d*dot(d,d)*.12;
      if (uv.x<0.||uv.x>1.||uv.y<0.||uv.y>1.) { out_FragColor = vec4(0,0,0,1); return; }
      float ab = .0025; vec3 c; c.r = texture(colorTexture, uv+vec2(ab,0)).r; c.g = texture(colorTexture, uv).g; c.b = texture(colorTexture, uv-vec2(ab,0)).b;
      float sl = .82 + .18*sin(uv.y*1400. + t*6.); c *= sl; c = c*1.15 + vec3(.02,.06,.03);
      c *= smoothstep(.95,.45,length(d)*1.2);
      out_FragColor = vec4(c, 1.); }`,
  noir: `uniform sampler2D colorTexture; in vec2 v_textureCoordinates; uniform float t;
    float rnd(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }
    void main(){ vec4 c = texture(colorTexture, v_textureCoordinates); float l = dot(c.rgb, vec3(.3,.59,.11)); l = smoothstep(.05,.95,l)*1.1;
      float n = (rnd(v_textureCoordinates*vec2(800.,1400.)+t)-.5)*.08; vec2 d = v_textureCoordinates-.5; float vg = smoothstep(.85,.3,length(d));
      out_FragColor = vec4(vec3(l+n)*vg, 1.); }`,
  snow: `uniform sampler2D colorTexture; in vec2 v_textureCoordinates; uniform float t;
    float rnd(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }
    void main(){ vec2 uv = v_textureCoordinates; float j = (rnd(vec2(floor(uv.y*300.), floor(t*30.)))-.5)*.01;
      vec4 c = texture(colorTexture, uv+vec2(j,0)); float n = rnd(uv*vec2(900.,1600.)+t*3.); float l = dot(c.rgb, vec3(.3,.59,.11));
      vec3 col = mix(vec3(l), c.rgb, .35); col = mix(col, vec3(n), .35);
      out_FragColor = vec4(col, 1.); }`
};

const PLANE_GLB = 'data:model/gltf-binary;base64,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';
const SHIP_GLB = 'data:model/gltf-binary;base64,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';
window.GE = (() => {
  let viewer, tileset = null, buildings = null, customAssets = [], stage = null, cfg = {}, hudOn = true, sensor = 'normal', spaceMode = false;
  let spaceFX = [];
  let buildingReq = { token: 0, on: false, loading: false };
  let customTs = new Map(), lastData = null, cockpit = false, camImgs = new Map(), t0 = Date.now();
  const rasterCredit = { esriImagery:'ESRI', esriHybrid:'ESRI', esriStreets:'ESRI', osm:'OSM', google3D:'GOOGLE 3D', bingAerial:'BING', bingHybrid:'BING', custom:'MRZEFV' };

  function esri(layer){ return new Cesium.UrlTemplateImageryProvider({ url: 'https://server.arcgisonline.com/ArcGIS/rest/services/'+layer+'/MapServer/tile/{z}/{y}/{x}', maximumLevel: 19, credit: 'Esri, Maxar, Earthstar Geographics' }); }
  function osm(){ return new Cesium.OpenStreetMapImageryProvider({ url: 'https://tile.openstreetmap.org/', credit: '© OpenStreetMap contributors' }); }
  function wantsAnimatedShader(){ return !!(SHADERS[sensor] && sensor !== 'flir'); }
  function syncRenderMode(){ if (!viewer) return; viewer.scene.requestRenderMode = !(trk || cockpit || wantsAnimatedShader()); viewer.scene.requestRender(); }

  // ---- basemaps ----
  async function setBasemap(name){
    if (!viewer) { cfg.basemap = name; return; }
    const L = viewer.imageryLayers; L.removeAll();
    if (tileset) { viewer.scene.primitives.remove(tileset); tileset = null; }
    viewer.scene.globe.show = true;
    try {
      switch(name){
        case 'esriImagery': L.addImageryProvider(esri('World_Imagery')); break;
        case 'esriHybrid': L.addImageryProvider(esri('World_Imagery')); L.addImageryProvider(esri('Reference/World_Boundaries_and_Places')); L.addImageryProvider(esri('Reference/World_Transportation')); break;
        case 'esriStreets': L.addImageryProvider(esri('World_Street_Map')); break;
        case 'osm': L.addImageryProvider(osm()); break;
        case 'bingAerial': L.addImageryProvider(await Cesium.IonImageryProvider.fromAssetId(2)); break;
        case 'bingHybrid': L.addImageryProvider(await Cesium.IonImageryProvider.fromAssetId(3)); break;
        case 'google3D':
          L.addImageryProvider(esri('World_Imagery'));
          status('REFRESHING GOOGLE PHOTOREALISTIC 3D TILES');
          if (cfg.googleKey) tileset = await Cesium.createGooglePhotorealistic3DTileset({ key: cfg.googleKey, onlyUsingWithGoogleGeocoder: false, showCreditsOnScreen: true, maximumScreenSpaceError: 6 });
          else tileset = await Cesium.Cesium3DTileset.fromIonAssetId(\#(google), { showCreditsOnScreen: true, maximumScreenSpaceError: 6 });
          viewer.scene.primitives.add(tileset); viewer.scene.globe.show = false; break;
      }
      $('src').textContent = rasterCredit[name] || name.toUpperCase();
      status(name.toUpperCase() + ' · TAP TO INSPECT');
    } catch(e) { status('BASEMAP FAILED: ' + (e.message||e)); L.addImageryProvider(esri('World_Imagery')); }
    viewer.scene.requestRender();
  }
  function setCustomRaster(url, minZ, maxZ){
    if (!viewer) return;
    const L = viewer.imageryLayers; L.removeAll();
    if (tileset) { viewer.scene.primitives.remove(tileset); tileset = null; }
    viewer.scene.globe.show = true;
    L.addImageryProvider(esri('World_Imagery'));
    L.addImageryProvider(new Cesium.UrlTemplateImageryProvider({ url, minimumLevel: minZ||0, maximumLevel: maxZ||22, credit: 'hand-rolled · godseye-tiles', hasAlphaChannel: true }));
    $('src').textContent = 'MRZEFV'; status('HAND-ROLLED RASTER · TAP TO INSPECT'); viewer.scene.requestRender();
  }
  async function setCustomTilesets(list){
    if (!viewer) return;
    const items = (list||[]).map(x => typeof x === 'string' ? { url: x } : x);
    const want = new Map(items.map(x => [x.url, x]));
    for (const [u, t] of customTs) { if (!want.has(u)) { viewer.scene.primitives.remove(t); customTs.delete(u); } }
    for (const [u, meta] of want) {
      if (customTs.has(u)) continue;
      try {
        const t = await Cesium.Cesium3DTileset.fromUrl(u, { maximumScreenSpaceError: meta.kind === 'mesh' ? 4 : 8, pointCloudShading: { attenuation: true, maximumAttenuation: 6, eyeDomeLighting: true } });
        // Hand-rolled mesh is authored in orthometric height; with no real terrain underneath, sit it on the ellipsoid.
        if (meta.baseHeight && !(TOKEN && cfg.terrain)) {
          const c = t.boundingSphere.center; const n = Cesium.Ellipsoid.WGS84.geodeticSurfaceNormal(c, new Cesium.Cartesian3());
          t.modelMatrix = Cesium.Matrix4.fromTranslation(Cesium.Cartesian3.multiplyByScalar(n, -meta.baseHeight, new Cesium.Cartesian3()));
        }
        if (meta.kind === 'mesh' || meta.kind === 'buildings' || meta.kind === 'trees') t.shadows = viewer.shadows ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
        viewer.scene.primitives.add(t); customTs.set(u, t); status('LOADED ' + u.split('/').slice(-3,-1).join('/').toUpperCase());
      } catch(e){ status('TILESET FAILED: ' + (e.message||e)); }
    }
    viewer.scene.requestRender();
  }

  // ---- procedural model library (godseye-tiles/models) ----
  let modelsBase = null;
  function setModels(base){ modelsBase = base && base.endsWith('/') ? base : (base ? base + '/' : null); }
  function modelUri(e){
    if (modelsBase && e.model) return modelsBase + e.model + '.glb';
    if (e.kind === 'ac') return PLANE_GLB;
    if (e.kind === 'sh') return SHIP_GLB;
    return null;
  }
  function modelScale(e){ return e.kind === 'ac' ? 1.0 : e.kind === 'sat' ? 40 : 1.0; }

  function clearSpaceFX(){ for (const id of spaceFX) { const e = viewer && viewer.entities.getById(id); if (e) viewer.entities.remove(e); } spaceFX = []; }
  function seedSpaceFX(){
    if (!viewer) return;
    clearSpaceFX();
    const active = spaceMode;
    if (!active) return;
    const stars = [];
    for (let i = 0; i < 56; i++) {
      const lat = -72 + (i % 29) * (144 / 28);
      const lon = ((i * 137.50776405) % 360) - 180;
      stars.push({ id: `space:star:${i}`, label: `STARFIELD ${i+1}`, icon: '✦', lat, lon, alt: 240000 + (i % 7) * 28000, color: '#c9e8ff', s: i % 9 === 0 ? 0.44 : 0.3 });
    }
    const showcase = [
      { id: 'space:galaxy:1', label: 'SPIRAL GALAXY', icon: '✺', lat: 62.5, lon: -130.3, alt: 420000, color: '#d4b7ff', s: 0.8 },
      { id: 'space:galaxy:2', label: 'DEEP SKY CLUSTER', icon: '✶', lat: -41.7, lon: 18.4, alt: 465000, color: '#9fd7ff', s: 0.74 },
      { id: 'space:ufo:1', label: 'UFO SCOUT', icon: '🛸', lat: 38.2, lon: -114.5, alt: 115000, color: '#9dffb2', s: 0.68 },
      { id: 'space:ufo:2', label: 'UFO SCOUT', icon: '🛸', lat: -11.9, lon: 146.0, alt: 128000, color: '#9dffb2', s: 0.68 },
      { id: 'space:alien:1', label: 'ALIEN SIGNAL', icon: '👽', lat: 6.8, lon: 74.2, alt: 102000, color: '#ffe680', s: 0.65 }
    ];
    for (const it of stars.concat(showcase)) {
      const sp = sprite(it.label, `${Math.round(it.alt/1000)} KM · DEEP SPACE`, it.color, { icon: it.icon });
      viewer.entities.add({ id: it.id, position: Cesium.Cartesian3.fromDegrees(it.lon, it.lat, it.alt), billboard: { image: sp, verticalOrigin: Cesium.VerticalOrigin.BOTTOM, scale: it.s, disableDepthTestDistance: Number.POSITIVE_INFINITY, scaleByDistance: new Cesium.NearFarScalar(2000, 1.0, 1500000, 0.38) } });
      spaceFX.push(it.id);
    }
  }

  // ---- realism presets ----
  let realism = 'off';
  function localHour(h){ const d = new Date(); const lonH = (viewer ? Cesium.Math.toDegrees(viewer.camera.positionCartographic.longitude) : 0) / 15; d.setUTCHours(Math.round(h - lonH + 24) % 24, 0, 0, 0); return Cesium.JulianDate.fromDate(d); }
  function applyBuildingStyle(){
    if (!buildings) return;
    const glass = realism !== 'off';
    buildings.style = glass ? new Cesium.Cesium3DTileStyle({
      color: {
        conditions: [
          ["${height} >= 220", "color('#b4d9ff', 0.82)"],
          ["${height} >= 120", "color('#9ecfff', 0.76)"],
          ["${height} >= 40", "color('#8fc3ff', 0.68)"],
          ["true", "color('#7bb7ff', 0.58)"]
        ]
      }
    }) : undefined;
    buildings.maximumScreenSpaceError = glass ? 3 : 8;
    buildings.imageBasedLightingFactor = glass ? new Cesium.Cartesian2(1.35, 1.05) : new Cesium.Cartesian2(1.0, 1.0);
    buildings.shadows = viewer.shadows ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
  }
  function setRealism(name){
    realism = name || 'off'; if (!viewer) return;
    const sc = viewer.scene, g = sc.globe;
    const on = realism !== 'off';
    sc.highDynamicRange = on; sc.postProcessStages.bloom.enabled = on && realism !== 'overcast';
    sc.postProcessStages.bloom.uniforms.brightness = -0.35; sc.postProcessStages.bloom.uniforms.contrast = 96; sc.postProcessStages.bloom.uniforms.glowOnly = false;
    sc.skyAtmosphere.show = true; sc.skyAtmosphere.hueShift = 0; sc.skyAtmosphere.saturationShift = 0; sc.skyAtmosphere.brightnessShift = 0;
    g.showGroundAtmosphere = on; g.enableLighting = on && realism !== 'overcast'; g.dynamicAtmosphereLighting = on; g.dynamicAtmosphereLightingFromSun = on;
    sc.fog.enabled = on; sc.fog.density = realism === 'overcast' ? 0.0012 : realism === 'night' ? 0.0004 : 0.0006; sc.fog.minimumBrightness = realism === 'night' ? 0.02 : 0.15;
    sc.light = new Cesium.SunLight();
    viewer.shadows = on && realism !== 'overcast' && realism !== 'night';
    viewer.terrainShadows = viewer.shadows ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
    for (const t of customTs.values()) t.shadows = viewer.shadows ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
    if (tileset) tileset.shadows = viewer.shadows ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
    switch (realism) {
      case 'day': viewer.clock.currentTime = localHour(13); sc.light.intensity = 2.4; break;
      case 'golden': viewer.clock.currentTime = localHour(19); sc.light.intensity = 3.2; sc.skyAtmosphere.hueShift = -0.03; sc.skyAtmosphere.saturationShift = 0.25; sc.skyAtmosphere.brightnessShift = -0.1; break;
      case 'night': viewer.clock.currentTime = localHour(1); sc.light.intensity = 0.35; sc.skyAtmosphere.brightnessShift = -0.6; g.nightFadeOutDistance = 1e7; g.nightFadeInDistance = 5e6; break;
      case 'overcast': viewer.clock.currentTime = localHour(11); sc.light.intensity = 1.1; sc.skyAtmosphere.saturationShift = -0.6; sc.skyAtmosphere.brightnessShift = -0.25; break;
      default: sc.light.intensity = 2.0; g.enableLighting = false; sc.fog.enabled = false;
    }
    applyBuildingStyle();
    seedSpaceFX();
    viewer.clock.shouldAnimate = false;
    syncRenderMode();
    status('REALISM ' + realism.toUpperCase());
    sc.requestRender();
  }
  async function setTerrain(on){
    if (!viewer) return;
    try { viewer.scene.setTerrain(on && TOKEN ? new Cesium.Terrain(Cesium.CesiumTerrainProvider.fromIonAssetId(1)) : new Cesium.Terrain(Promise.resolve(new Cesium.EllipsoidTerrainProvider()))); }
    catch(e){ status('TERRAIN: ' + (e.message||e)); }
    viewer.scene.requestRender();
  }
  async function setBuildings(on){
    if (!viewer) return;
    const want = !!on;
    if (!want) {
      buildingReq.token++;
      buildingReq.on = false;
      buildingReq.loading = false;
      if (buildings) { viewer.scene.primitives.remove(buildings); buildings = null; }
      viewer.scene.requestRender();
      return;
    }
    if (buildingReq.on && (buildingReq.loading || buildings)) return;
    const req = ++buildingReq.token;
    buildingReq.on = true;
    buildingReq.loading = true;
    if (buildings) { viewer.scene.primitives.remove(buildings); buildings = null; }
    if (!TOKEN) {
      buildingReq.loading = false;
      viewer.scene.requestRender();
      return;
    }
    try {
      const next = await Cesium.createOsmBuildingsAsync();
      if (req !== buildingReq.token || !buildingReq.on) { if (next && typeof next.destroy === 'function') next.destroy(); return; }
      buildingReq.loading = false;
      buildings = next;
      viewer.scene.primitives.add(buildings);
      applyBuildingStyle();
    } catch(e){
      if (req !== buildingReq.token || !buildingReq.on) return;
      buildingReq.loading = false;
      status('OSM BUILDINGS: ' + (e.message||e));
    }
    viewer.scene.requestRender();
  }
  function setSpaceMode(on){ spaceMode = !!on; if (!viewer) return; seedSpaceFX(); viewer.scene.requestRender(); }
  async function loadAssets(ids){
    for (const p of customAssets) viewer.scene.primitives.remove(p);
    customAssets = [];
    if (!TOKEN) return;
    for (const id of ids||[]) { try { const t = await Cesium.Cesium3DTileset.fromIonAssetId(id); viewer.scene.primitives.add(t); customAssets.push(t); } catch(e){ status('ION ASSET ' + id + ': ' + (e.message||e)); } }
    viewer.scene.requestRender();
  }

  // ---- sensor ----
  function setSensor(name){
    sensor = name || 'normal';
    $('mode').textContent = sensor.toUpperCase(); $('modeL').textContent = sensor.toUpperCase();
    if (!viewer) return;
    if (stage) { viewer.scene.postProcessStages.remove(stage); stage = null; }
    if (SHADERS[sensor]) {
      stage = new Cesium.PostProcessStage({ fragmentShader: SHADERS[sensor], uniforms: { t: () => (Date.now()-t0)/1000 } });
      viewer.scene.postProcessStages.add(stage);
    }
    syncRenderMode();
  }
  function setHUD(on){ hudOn = !!on; $('hud').classList.toggle('off', !hudOn); }
  function status(t){ $('stat').textContent = t; post({type:'status', text: t}); }

  // ---- init ----
  function init(c){
    cfg = c || {};
    if (cfg.accent) document.documentElement.style.setProperty('--acc', cfg.accent);
    viewer = new Cesium.Viewer('c', {
      baseLayer: false, terrain: undefined, animation:false, timeline:false, geocoder:false, homeButton:false,
      sceneModePicker:false, baseLayerPicker:false, navigationHelpButton:false, infoBox:false, selectionIndicator:false,
      fullscreenButton:false, requestRenderMode:true, maximumRenderTimeChange: Infinity, msaaSamples: 4
    });
    viewer.scene.globe.enableLighting = false;
    viewer.scene.globe.depthTestAgainstTerrain = true;
    viewer.scene.screenSpaceCameraController.enableCollisionDetection = true;
    viewer.scene.postProcessStages.fxaa.enabled = true;
    viewer.scene.skyAtmosphere.show = true;
    setBasemap(cfg.basemap || 'esriImagery'); setTerrain(!!cfg.terrain); setBuildings(!!cfg.buildings); loadAssets(cfg.assets);
    setSensor(cfg.sensor || 'normal'); setHUD(cfg.hud !== false); setRealism(cfg.realism || 'off'); setSpaceMode(!!cfg.space);
    bindCtx();
    $('kh').textContent = String(4000 + Math.floor(Math.random()*999)); $('ops').textContent = String(4100 + Math.floor(Math.random()*99));

    const h = new Cesium.ScreenSpaceEventHandler(viewer.canvas);
    h.setInputAction((click) => {
      const picked = viewer.scene.pick(click.position);
      if (Cesium.defined(picked) && picked.id && picked.id.id && String(picked.id.id).startsWith('e:')) { post({type:'entity', id: picked.id.id.slice(2)}); return; }
      let cart = null;
      if (viewer.scene.pickPositionSupported) { const p = viewer.scene.pickPosition(click.position); if (Cesium.defined(p)) cart = p; }
      if (!cart) cart = viewer.camera.pickEllipsoid(click.position, viewer.scene.globe.ellipsoid);
      if (!cart) return;
      const cg = Cesium.Cartographic.fromCartesian(cart);
      const lat = Cesium.Math.toDegrees(cg.latitude), lon = Cesium.Math.toDegrees(cg.longitude);
      if (tool !== 'none') { toolTap(cart, cg, lat, lon); return; }
      const terr = viewer.scene.globe.getHeight(cg);
      post({type:'tap', lat, lon, height: viewer.camera.positionCartographic.height, surface: cg.height, terrain: (terr === undefined ? null : terr), mgrs: toMGRS(lat, lon, 5)});
    }, Cesium.ScreenSpaceEventType.LEFT_CLICK);
    h.setInputAction((e) => {
      const picked = viewer.scene.pick(e.position);
      if (Cesium.defined(picked) && picked.id && picked.id.id && String(picked.id.id).startsWith('e:')) post({type:'track', id: picked.id.id.slice(2)});
    }, Cesium.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);

    viewer.scene.preUpdate.addEventListener(trackFrame);
    viewer.camera.moveStart.addEventListener(() => { userMoving = true; });
    viewer.camera.moveEnd.addEventListener(() => { userMoving = false; });
    viewer.camera.changed.addEventListener(readout);
    viewer.camera.percentageChanged = 0.01;
    viewer.camera.moveEnd.addEventListener(() => {
      const c = viewer.camera, cg = c.positionCartographic, ctr = centerLL();
      post({type:'camera', lat: ctr.lat, lon: ctr.lon, height: cg.height, heading: Cesium.Math.toDegrees(c.heading), pitch: 90 + Cesium.Math.toDegrees(c.pitch)});
    });
    setInterval(() => { $('clock').textContent = new Date().toISOString().replace('T',' ').slice(0,19) + 'Z'; if (cockpit) cockpitTick(); }, 1000);
    readout();
  }

  function centerLL(){
    const c = viewer.camera, cg = c.positionCartographic;
    let lat = Cesium.Math.toDegrees(cg.latitude), lon = Cesium.Math.toDegrees(cg.longitude);
    const ray = c.getPickRay(new Cesium.Cartesian2(viewer.canvas.clientWidth/2, viewer.canvas.clientHeight/2));
    const hit = ray ? viewer.scene.globe.pick(ray, viewer.scene) : null;
    if (hit) { const hc = Cesium.Cartographic.fromCartesian(hit); lat = Cesium.Math.toDegrees(hc.latitude); lon = Cesium.Math.toDegrees(hc.longitude); }
    return { lat, lon };
  }
  function readout(){
    if (!viewer) return;
    const c = viewer.camera, cg = c.positionCartographic, ctr = centerLL();
    const hFt = cg.height*3.281;
    $('mgrs').textContent = toMGRS(ctr.lat, ctr.lon, 4);
    $('ll').textContent = dms(ctr.lat,'N','S') + ' ' + dms(ctr.lon,'E','W');
    const fov = c.frustum.fovy || 1.0; const gsd = 2*cg.height*Math.tan(fov/2)/viewer.canvas.clientHeight;   // m/px at nadir
    const niirs = Math.max(0, Math.min(9, 10.251 - 3.32*Math.log10(Math.max(gsd*39.37, .1))));
    $('gsd').textContent = gsd < 1 ? (gsd*100).toFixed(0)+'CM' : gsd < 1000 ? gsd.toFixed(1)+'M' : (gsd/1000).toFixed(1)+'KM';
    $('niirs').textContent = niirs.toFixed(1);
    $('alt').textContent = hFt > 100000 ? (cg.height/1000).toFixed(0)+'KM' : Math.round(hFt).toLocaleString()+'FT';
    $('hdg').textContent = String(Math.round(Cesium.Math.toDegrees(c.heading))).padStart(3,'0')+'°';
    $('pit').textContent = String(Math.round(90+Cesium.Math.toDegrees(c.pitch))).padStart(2,'0')+'°';
    const sun = subsolar(new Date()); $('az').textContent = String(Math.round(bearing(ctr.lat, ctr.lon, sun.lat, sun.lon))).padStart(3,'0') + '° SUN';
  }
  function subsolar(d){ const J = d/86400000 + 2440587.5 - 2451545.0; const g = (357.529 + .98560028*J) % 360, q = (280.459 + .98564736*J) % 360; const L = q + 1.915*Math.sin(g*Math.PI/180) + .02*Math.sin(2*g*Math.PI/180); const e = 23.439 - .00000036*J; const dec = Math.asin(Math.sin(e*Math.PI/180)*Math.sin(L*Math.PI/180))*180/Math.PI; const gmst = (18.697374558 + 24.06570982441908*J) % 24; const ra = Math.atan2(Math.cos(e*Math.PI/180)*Math.sin(L*Math.PI/180), Math.cos(L*Math.PI/180))*12/Math.PI; let lon = ((ra - gmst)*15 + 540) % 360 - 180; return { lat: dec, lon }; }
  function bearing(la1,lo1,la2,lo2){ const p1=la1*Math.PI/180,p2=la2*Math.PI/180,dl=(lo2-lo1)*Math.PI/180; const y=Math.sin(dl)*Math.cos(p2), x=Math.cos(p1)*Math.sin(p2)-Math.sin(p1)*Math.cos(p2)*Math.cos(dl); return (Math.atan2(y,x)*180/Math.PI+360)%360; }

  function setView(lat, lon, height, heading, pitch){
    if (!viewer) return;
    viewer.camera.setView({ destination: Cesium.Cartesian3.fromDegrees(lon, lat, Math.max(height, 200)), orientation: { heading: Cesium.Math.toRadians(heading||0), pitch: Cesium.Math.toRadians(-90 + (pitch||0)), roll: 0 } });
    viewer.scene.requestRender();
  }
  function home(){ if (!viewer) return; const c = viewer.camera.positionCartographic; viewer.camera.flyTo({ destination: Cesium.Cartesian3.fromRadians(c.longitude, c.latitude, c.height), orientation:{heading:0, pitch:-Cesium.Math.PI_OVER_TWO, roll:0}, duration:0.8 }); }
  function tilt(){ if (!viewer) return; const c = viewer.camera.positionCartographic; viewer.camera.flyTo({ destination: Cesium.Cartesian3.fromRadians(c.longitude, c.latitude, Math.max(c.height, 400)), orientation:{heading:viewer.camera.heading, pitch:Cesium.Math.toRadians(-30), roll:0}, duration:0.8 }); }

  // ---- spatial tools (work on 3D tiles via pickPosition / clampToHeight) ----
  let tool = 'none', toolPts = [];
  const toolEnts = [];
  function setTool(name){ tool = name || 'none'; toolPts = []; $('cross').style.borderColor = ''; status(tool === 'none' ? 'INSPECT · TAP TO IDENTIFY' : tool.toUpperCase() + (tool === 'measure' || tool === 'los' ? ' · TAP TWO POINTS' : ' · TAP A POINT')); }
  function clearTools(){ for (const e of toolEnts) viewer.entities.remove(e); toolEnts.length = 0; toolPts = []; viewer.scene.requestRender(); }
  function addTool(o){ const e = viewer.entities.add(o); toolEnts.push(e); return e; }
  function fmtM(m){ return m < 1000 ? m.toFixed(1) + ' M' : (m/1000).toFixed(2) + ' KM'; }
  function marker(cart, text, color){ addTool({ position: cart, point: { pixelSize: 8, color: Cesium.Color.fromCssColorString(color), outlineColor: Cesium.Color.BLACK, outlineWidth: 2, disableDepthTestDistance: Number.POSITIVE_INFINITY }, billboard: text ? { image: sprite(text, null, color, {}), verticalOrigin: Cesium.VerticalOrigin.BOTTOM, pixelOffset: new Cesium.Cartesian2(0,-8), scale: .5, disableDepthTestDistance: Number.POSITIVE_INFINITY } : undefined }); }
  async function toolTap(cart, cg, lat, lon){
    if (tool === 'probe') {
      const terr = viewer.scene.globe.getHeight(cg) || 0;
      const h = cg.height, sh = Math.max(0, h - terr);
      marker(cart, 'SURF ' + h.toFixed(1) + ' M · STRUCT ' + sh.toFixed(1) + ' M', '#ffe45c');
      // vertical drop line to terrain
      addTool({ polyline: { positions: [cart, Cesium.Cartesian3.fromDegrees(lon, lat, terr)], width: 2, material: Cesium.Color.YELLOW.withAlpha(.8) } });
      post({type:'tool', text: 'PROBE ' + toMGRS(lat, lon, 5) + ' · SURFACE ' + h.toFixed(1) + ' M · STRUCTURE ' + sh.toFixed(1) + ' M (' + (sh*3.281).toFixed(0) + ' FT)'});
      viewer.scene.requestRender(); return;
    }
    if (tool === 'scan') {
      const r = Math.max(150, Math.min(5000, viewer.camera.positionCartographic.height * 0.35));
      addTool({ position: cart, ellipse: { semiMajorAxis: r, semiMinorAxis: r, material: Cesium.Color.YELLOW.withAlpha(.08), outline: true, outlineColor: Cesium.Color.YELLOW, outlineWidth: 2, classificationType: Cesium.ClassificationType.BOTH } });
      const hits = [];
      for (const e of (lastData && lastData.entities) || []) {
        const d = Cesium.Cartesian3.distance(cart, Cesium.Cartesian3.fromDegrees(e.lon, e.lat, e.alt||0));
        if (d <= r) hits.push({ e, d });
      }
      hits.sort((a,b) => a.d - b.d);
      for (const h of hits.slice(0, 12)) addTool({ polyline: { positions: [cart, Cesium.Cartesian3.fromDegrees(h.e.lon, h.e.lat, h.e.alt||0)], width: 1, material: Cesium.Color.YELLOW.withAlpha(.35) } });
      const by = {}; for (const h of hits) by[h.e.kind] = (by[h.e.kind]||0) + 1;
      marker(cart, 'SCAN ' + Math.round(r) + ' M · ' + hits.length + ' CONTACTS', '#ffe45c');
      post({type:'tool', text: 'SCAN ' + Math.round(r) + ' M: ' + hits.length + ' contacts · ' + Object.entries(by).map(([k,v]) => k.toUpperCase() + ' ' + v).join(' · ') + (hits[0] ? ' · nearest ' + hits[0].e.label + ' ' + Math.round(hits[0].d) + ' m' : '')});
      viewer.scene.requestRender(); return;
    }
    toolPts.push({ cart, cg, lat, lon });
    marker(cart, toolPts.length === 1 ? 'A' : 'B', tool === 'los' ? '#4de3ff' : '#ffe45c');
    if (toolPts.length < 2) { viewer.scene.requestRender(); return; }
    const [A, B] = toolPts; toolPts = [];
    const dist = Cesium.Cartesian3.distance(A.cart, B.cart);
    const geo = new Cesium.EllipsoidGeodesic(A.cg, B.cg); const ground = geo.surfaceDistance;
    const brg = bearing(A.lat, A.lon, B.lat, B.lon); const dh = B.cg.height - A.cg.height;
    if (tool === 'measure') {
      addTool({ polyline: { positions: [A.cart, B.cart], width: 3, material: new Cesium.PolylineDashMaterialProperty({ color: Cesium.Color.YELLOW }) } });
      const mid = Cesium.Cartesian3.midpoint(A.cart, B.cart, new Cesium.Cartesian3());
      marker(mid, fmtM(dist) + ' · ' + String(Math.round(brg)).padStart(3,'0') + '° · ΔH ' + dh.toFixed(1) + ' M', '#ffe45c');
      post({type:'tool', text: 'MEASURE ' + fmtM(dist) + ' slant · ' + fmtM(ground) + ' ground · ' + String(Math.round(brg)).padStart(3,'0') + '° · ΔH ' + dh.toFixed(1) + ' m'});
    } else if (tool === 'los') {
      // sample the straight line (eye height +1.7 m at both ends) against the 3D tiles / terrain
      const N = Math.max(24, Math.min(160, Math.round(dist / 5)));
      const samples = [], line = [];
      for (let i = 0; i <= N; i++) {
        const f = i / N; const pt = geo.interpolateUsingFraction(f);
        const hLine = A.cg.height + 1.7 + (B.cg.height + 1.7 - (A.cg.height + 1.7)) * f;
        samples.push(new Cesium.Cartographic(pt.longitude, pt.latitude, 0)); line.push(hLine);
      }
      let clamped;
      try { clamped = await viewer.scene.sampleHeightMostDetailed(samples); } catch(e) { clamped = samples.map(s => { s.height = viewer.scene.globe.getHeight(s) || 0; return s; }); }
      let blocked = 0, firstBlock = -1;
      const segsOK = [], segsBad = [];
      for (let i = 0; i <= N; i++) {
        const surf = (clamped[i] && clamped[i].height !== undefined) ? clamped[i].height : (viewer.scene.globe.getHeight(samples[i]) || 0);
        const p = Cesium.Cartesian3.fromRadians(samples[i].longitude, samples[i].latitude, line[i]);
        const bad = i > 0 && i < N && surf > line[i] + 0.3;
        if (bad) { blocked++; if (firstBlock < 0) firstBlock = i; }
        (bad ? segsBad : segsOK).push(p);
      }
      if (segsOK.length > 1) addTool({ polyline: { positions: segsOK, width: 3, material: Cesium.Color.fromCssColorString('#59ff73').withAlpha(.9) } });
      if (segsBad.length > 1) addTool({ polyline: { positions: segsBad, width: 4, material: Cesium.Color.RED.withAlpha(.9) } });
      const pct = Math.round(100 * blocked / Math.max(1, N - 1));
      const mid = Cesium.Cartesian3.midpoint(A.cart, B.cart, new Cesium.Cartesian3());
      marker(mid, (blocked ? 'LOS BLOCKED ' + pct + '%' : 'LOS CLEAR') + ' · ' + fmtM(dist), blocked ? '#ff3b30' : '#59ff73');
      post({type:'tool', text: (blocked ? 'LINE OF SIGHT BLOCKED (' + pct + '% obstructed, first at ' + Math.round(firstBlock / N * dist) + ' m)' : 'LINE OF SIGHT CLEAR') + ' · ' + fmtM(dist) + ' · ' + String(Math.round(brg)).padStart(3,'0') + '°'});
    }
    viewer.scene.requestRender();
  }
  function setShadows(on, hourZ){
    if (!viewer) return;
    viewer.shadows = !!on; viewer.terrainShadows = on ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
    viewer.scene.globe.enableLighting = !!on;
    if (tileset) tileset.shadows = on ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
    for (const t of customTs.values()) t.shadows = on ? Cesium.ShadowMode.ENABLED : Cesium.ShadowMode.DISABLED;
    if (on) { const d = new Date(); d.setUTCHours(Math.floor(hourZ||12), Math.round(((hourZ||12)%1)*60), 0, 0); viewer.clock.currentTime = Cesium.JulianDate.fromDate(d); viewer.clock.shouldAnimate = false; }
    syncRenderMode();
  }

  // ---- live track: dead-reckon at frame rate, optional camera follow ----
  let trk = null, follow = true, followHPR = null, followRange = null, userMoving = false;
  function setFollow(on){ follow = !!on; followHPR = null; if (!follow && viewer) viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY); status(follow ? 'FOLLOW ON · DRAG TO ORBIT TARGET' : 'FOLLOW OFF'); }
  function setTrack(t){
    if (!viewer) return;
    if (!t || !t.id) { trk = null; if (lastData) lastData.track = {}; viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY); syncRenderMode(); return; }
    if (!trk || trk.id !== t.id) { followHPR = null; }
    trk = Object.assign({}, t, { t0: performance.now(), lat0: t.lat, lon0: t.lon });
    if (lastData) lastData.track = t;
    syncRenderMode();
  }
  function trkPos(){
    if (!trk) return null;
    const dt = Math.min(15, (performance.now() - trk.t0) / 1000);
    const m = (trk.spd || 0) * 0.514444 * dt, hd = (trk.heading || 0) * Math.PI / 180;
    const dlat = (m * Math.cos(hd)) / 110540, dlon = (m * Math.sin(hd)) / (111320 * Math.cos(trk.lat0 * Math.PI / 180));
    return { lat: trk.lat0 + dlat, lon: trk.lon0 + dlon, alt: trk.alt || 0 };
  }
  function trackFrame(){
    if (!trk || !viewer) return;
    const p = trkPos(); const pos = Cesium.Cartesian3.fromDegrees(p.lon, p.lat, p.alt);
    const ids = ['e:' + trk.id, 'trk', 'det'];
    for (const id of ids) { const e = viewer.entities.getById(id); if (e) { e.position = pos; if (id === 'e:' + trk.id) e.orientation = orient(pos, trk.heading); } }
    for (let i = 0; i < 5; i++) { const le = viewer.entities.getById('ld:' + i); if (le && le.polyline) { const ps = le.polyline.positions.getValue ? le.polyline.positions.getValue(Cesium.JulianDate.now()) : le.polyline.positions; if (ps && ps.length === 2) { le.polyline.positions = [pos, ps[1]]; le.position = Cesium.Cartesian3.midpoint(pos, ps[1], new Cesium.Cartesian3()); } } }
    if (cockpit) { cockpitAt(p); return; }
    if (follow) {
      const cam = viewer.camera;
      if (!followHPR) {
        // seed from the current view: keep the user's heading/pitch, range = distance camera→target
        const range = Math.max(400, Cesium.Cartesian3.distance(cam.positionWC, pos));
        followHPR = new Cesium.HeadingPitchRange(cam.heading, Math.min(cam.pitch, Cesium.Math.toRadians(-15)), range);
      } else if (!userMoving) {
        // remember how the user orbited/zoomed relative to the target
        const transform = Cesium.Transforms.eastNorthUpToFixedFrame(pos);
        const inv = Cesium.Matrix4.inverse(transform, new Cesium.Matrix4());
        const local = Cesium.Matrix4.multiplyByPoint(inv, cam.positionWC, new Cesium.Cartesian3());
        const range = Cesium.Cartesian3.magnitude(local);
        if (range > 50) followHPR = new Cesium.HeadingPitchRange(cam.heading, cam.pitch, range);
      }
      cam.lookAt(pos, followHPR);
    }
  }
  function cockpitAt(p){
    const alt = Math.max(p.alt || 0, 60), hd = Cesium.Math.toRadians(trk.heading || 0);
    const back = trk.kind === 'ship' ? 400 : 700, up = trk.kind === 'ship' ? 120 : 220;
    const pos = Cesium.Cartesian3.fromDegrees(p.lon, p.lat, alt);
    const enu = Cesium.Transforms.eastNorthUpToFixedFrame(pos);
    const off = new Cesium.Cartesian3(-Math.sin(hd)*back, -Math.cos(hd)*back, up);
    const dest = Cesium.Matrix4.multiplyByPoint(enu, off, new Cesium.Cartesian3());
    viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY);
    viewer.camera.setView({ destination: dest, orientation: { heading: hd, pitch: Cesium.Math.toRadians(-14), roll: 0 } });
  }

  // ---- cockpit ----
  function setCockpit(on){
    cockpit = !!on && !!(lastData && lastData.track && lastData.track.id);
    $('cock').classList.toggle('on', cockpit);
    $('cross').style.display = cockpit ? 'none' : '';
    viewer.scene.screenSpaceCameraController.enableInputs = !cockpit;
    if (cockpit) cockpitTick(); else { viewer.trackedEntity = undefined; viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY); followHPR = null; }
    syncRenderMode();
    post({type:'cockpit', on: cockpit});
  }
  function cockpitTick(){
    const t = lastData && lastData.track; if (!t || !t.id) { setCockpit(false); return; }
    if (trk) { const p = trkPos(); cockpitAt(p); updateTape(t); return; }
    const alt = Math.max(t.alt || 0, 60), hd = Cesium.Math.toRadians(t.heading || 0);
    const back = t.kind === 'ship' ? 400 : 700, up = t.kind === 'ship' ? 120 : 220;
    const pos = Cesium.Cartesian3.fromDegrees(t.lon, t.lat, alt);
    const enu = Cesium.Transforms.eastNorthUpToFixedFrame(pos);
    const off = new Cesium.Cartesian3(-Math.sin(hd)*back, -Math.cos(hd)*back, up);
    const dest = Cesium.Matrix4.multiplyByPoint(enu, off, new Cesium.Cartesian3());
    viewer.camera.setView({ destination: dest, orientation: { heading: hd, pitch: Cesium.Math.toRadians(-14), roll: 0 } });
    updateTape(t);
  }
  function updateTape(t){
    $('cname').textContent = (t.label||'').toUpperCase(); $('cspd').textContent = Math.round(t.spd||0); $('chdg').textContent = String(Math.round(t.heading||0)).padStart(3,'0'); $('calt').textContent = Math.round((t.alt||0)*3.281).toLocaleString();
    const marks = []; for (let d = -60; d <= 60; d += 15) { const b = ((t.heading||0) + d + 360) % 360; const n = Math.round(b/15)*15 % 360; marks.push(n === 0 ? 'N' : n === 90 ? 'E' : n === 180 ? 'S' : n === 270 ? 'W' : (d === 0 ? '▲' : String(n))); } $('compass').textContent = marks.join('   ');
    viewer.scene.requestRender();
  }

  // ---- context panel ----
  const nwFrame = Cesium.Transforms.localFrameToFixedFrameGenerator('north', 'west');
  function orient(pos, headingDeg){ return Cesium.Transforms.headingPitchRollQuaternion(pos, new Cesium.HeadingPitchRoll(Cesium.Math.toRadians(headingDeg||0), 0, 0), Cesium.Ellipsoid.WGS84, nwFrame); }
  function detBox(){ const k='__det'; if (spriteCache.has(k)) return spriteCache.get(k); const cv=document.createElement('canvas'); const s=64; cv.width=s*2; cv.height=s*2; const c=cv.getContext('2d'); c.scale(2,2); c.strokeStyle='#ffffff'; c.lineWidth=1.5; const L=14; [[0,0,1,1],[s,0,-1,1],[0,s,1,-1],[s,s,-1,-1]].forEach(([x,y,dx,dy])=>{ c.beginPath(); c.moveTo(x,y+dy*L); c.lineTo(x,y); c.lineTo(x+dx*L,y); c.stroke(); }); c.strokeStyle='rgba(255,255,255,.35)'; c.strokeRect(1,1,s-2,s-2); spriteCache.set(k,cv); return cv; }
  let ctxOpen = true, ctxKind = 'flights';
  function bindCtx(){
    $('ctxtog').onclick = () => { ctxOpen = !ctxOpen; $('ctxp').classList.toggle('hid', !ctxOpen); $('ctxtog').textContent = ctxOpen ? '▾' : '▸'; };
    $('bprev').onclick = () => post({type:'ctx', action:'prev'});
    $('bnext').onclick = () => post({type:'ctx', action:'next'});
    $('bfocus').onclick = () => post({type:'ctx', action:'focus'});
    $('bcock').onclick = () => post({type:'ctx', action:'cockpit'});
    $('bnear').onclick = () => post({type:'ctx', action:'nearest', kind: 'aircraft'});
    $('bstop').onclick = () => post({type:'ctx', action:'stop'});
    $('ctxp').classList.toggle('hid', !ctxOpen);
  }
  function focus(lat, lon){ if (!viewer) return; const c = viewer.camera.positionCartographic; viewer.camera.flyTo({ destination: Cesium.Cartesian3.fromDegrees(lon, lat, Math.max(2500, Math.min(c.height, 40000))), orientation: { heading: viewer.camera.heading, pitch: Cesium.Math.toRadians(-55), roll: 0 }, duration: 1.0 }); }
  function renderCtx(d){
    const t = d.track && d.track.id ? d.track : null;
    const origin = t ? Cesium.Cartesian3.fromDegrees(t.lon, t.lat, t.alt||0) : (() => { const c = centerLL(); return Cesium.Cartesian3.fromDegrees(c.lon, c.lat, 0); })();
    const oll = t ? {lat:t.lat, lon:t.lon} : centerLL();
    const groups = { 'FLIGHTS': [], 'MILITARY FLIGHTS': [], 'AIS VESSELS': [] };
    for (const e of (d.entities||[])) {
      if (t && e.id === t.id) continue;
      const g = e.kind === 'ac' ? (e.mil ? 'MILITARY FLIGHTS' : 'FLIGHTS') : e.kind === 'sh' ? 'AIS VESSELS' : null;
      if (!g) continue;
      const dist = Cesium.Cartesian3.distance(origin, Cesium.Cartesian3.fromDegrees(e.lon, e.lat, e.alt||0));
      if (dist > 250000) continue;
      groups[g].push({ e, dist, brg: bearing(oll.lat, oll.lon, e.lat, e.lon) });
    }
    $('ctxt').textContent = t ? (t.label||'').toUpperCase() + ' · 250 KM WINDOW' : 'VIEWPORT · 250 KM';
    let html = '';
    for (const [g, arr] of Object.entries(groups)) {
      arr.sort((a,b) => a.dist - b.dist);
      html += `<div class="g">${g}<span>${arr.length}</span></div>`;
      html += `<div class="sub">${g === 'AIS VESSELS' ? 'aisstream · live' : 'adsb.lol · observed or mapped nearby'}</div>`;
      for (const h of arr.slice(0, 8)) html += `<div class="row" data-id="${h.e.id}"><span>${h.e.label}</span><i>${(h.dist/1000).toFixed(0)} km · ${String(Math.round(h.brg)).padStart(3,'0')}°</i></div>`;
      if (!arr.length) html += '<div class="row"><i>none in window</i></div>';
    }
    $('ctxl').innerHTML = html;
    for (const r of $('ctxl').querySelectorAll('.row[data-id]')) r.onclick = () => post({type:'track', id: r.dataset.id});
    $('bcock').classList.toggle('a', cockpit);
    return groups;
  }

  // ---- data ----
  const colors = { ac:'#4de3ff', mil:'#ffa63d', sh:'#5aa9ff', cam:'#c77dff', eq:'#ff6a3d', fire:'#ff3b30', sat:'#9ad7ff', train:'#ffd166', apt:'#8ecae6', infra:'#2ec4b6', storm:'#c77dff', sim:'#9dffb2' };
  const icons = { ac:'✈', sh:'⛴', cam:'▣', eq:'◎', fire:'▲', sat:'✦', train:'▬', apt:'⊕', infra:'▦', storm:'≋', sim:'🛸' };
  function setData(d){
    if (!viewer) return;
    lastData = d;
    const keep = new Set();
    const camH = viewer.camera.positionCartographic.height;
    const boxed = camH < 60000;
    for (const e of (d.entities||[])) {
      const id = 'e:' + e.id; keep.add(id);
      if (trk && e.id === trk.id && viewer.entities.getById(id)) continue;   // dead-reckoned at frame rate, don't snap back
      const pos = Cesium.Cartesian3.fromDegrees(e.lon, e.lat, e.alt||0);
      const col = e.mil ? colors.mil : (colors[e.kind] || '#fff');
      const cc = Cesium.Color.fromCssColorString(col);
      let ent = viewer.entities.getById(id);
      const isCam = e.kind === 'cam';
      const img = boxed ? (isCam && camH < 8000 ? (camImgs.get(e.id) || sprite(e.label, e.sub, col, { icon: '▣' })) : sprite(e.label, e.sub, col, { icon: e.icon || icons[e.kind] || '▣' })) : null;
      if (isCam && camH < 8000 && !camImgs.has(e.id)) { camImgs.set(e.id, null); camCard(e.img, e.label).then(cv => { camImgs.set(e.id, cv); const en = viewer.entities.getById(id); if (en && en.billboard) { en.billboard.image = cv; viewer.scene.requestRender(); } }); }
      const mUri = modelUri(e);
      const useModel = boxed && !!mUri && (camH < 30000 && (e.kind === 'ac' || e.kind === 'sh') || camH < 8000 && ['train','cam','infra'].includes(e.kind) || e.kind === 'sat' && camH > 200000);
      if (!ent) {
        ent = viewer.entities.add({ id, position: pos, orientation: orient(pos, e.heading),
          model: mUri ? { uri: mUri, minimumPixelSize: e.kind === 'sat' ? 18 : 26, maximumScale: e.kind === 'sat' ? 20000 : 400, scale: modelScale(e), color: modelsBase ? Cesium.Color.WHITE : cc.withAlpha(.95), colorBlendMode: Cesium.ColorBlendMode.MIX, colorBlendAmount: modelsBase ? (e.mil ? .35 : .12) : .55, silhouetteColor: Cesium.Color.WHITE.withAlpha(.3), silhouetteSize: 1, show: useModel, shadows: Cesium.ShadowMode.CAST_ONLY, heightReference: (e.kind === 'sh' || e.kind === 'train' || e.kind === 'cam' || e.kind === 'infra') ? Cesium.HeightReference.CLAMP_TO_GROUND : Cesium.HeightReference.NONE } : undefined,
          point: { pixelSize: e.kind==='ac'?6:5, color: cc, outlineColor: Cesium.Color.BLACK, outlineWidth: 1, heightReference: e.kind==='ac'?Cesium.HeightReference.NONE:Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY, show: !boxed },
          billboard: { image: img || sprite(e.label, e.sub, col), verticalOrigin: Cesium.VerticalOrigin.BOTTOM, pixelOffset: new Cesium.Cartesian2(0, useModel ? -22 : -6), scale: 0.5, heightReference: e.kind==='ac'?Cesium.HeightReference.NONE:Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY, show: boxed, scaleByDistance: new Cesium.NearFarScalar(500,1.0,200000,0.45) } });
      } else { ent.position = pos; ent.orientation = orient(pos, e.heading); if (boxed && img) ent.billboard.image = img; ent.point.show = !boxed; ent.billboard.show = boxed; if (ent.model) { ent.model.show = useModel; } ent.billboard.pixelOffset = new Cesium.Cartesian2(0, useModel ? -22 : -6); }
      if (e.watch && ent.billboard) ent.billboard.color = Cesium.Color.fromCssColorString('#ffb0b0');
      if (e.kind === 'eq' && e.r) { const rid = 'r:' + e.id; keep.add(rid); if (!viewer.entities.getById(rid)) viewer.entities.add({ id: rid, position: Cesium.Cartesian3.fromDegrees(e.lon, e.lat, 0), ellipse: { semiMajorAxis: e.r, semiMinorAxis: e.r, material: cc.withAlpha(.12), outline: true, outlineColor: cc.withAlpha(.7), classificationType: Cesium.ClassificationType.BOTH } }); }
      if (e.kind === 'storm' && e.heading >= 0) { const vid = 'v:' + e.id; keep.add(vid); const end = Cesium.Cartesian3.fromDegrees(e.lon + Math.sin(e.heading*Math.PI/180)*.05, e.lat + Math.cos(e.heading*Math.PI/180)*.05, 0); const ve = viewer.entities.getById(vid); if (!ve) viewer.entities.add({ id: vid, polyline: { positions: [pos, end], width: 2, material: new Cesium.PolylineDashMaterialProperty({ color: cc }), clampToGround: true } }); else ve.polyline.positions = [pos, end]; }
    }
    for (const p of (d.polys||[])) {
      const id = 'p:' + p.id + ':' + p.coords.length; keep.add(id);
      if (viewer.entities.getById(id)) continue;
      const arr = Cesium.Cartesian3.fromDegreesArray(p.coords);
      const col = p.kind === 'fp' ? Cesium.Color.CYAN : p.kind === 'region' ? Cesium.Color.WHITE : p.kind === 'hazard' ? Cesium.Color.fromCssColorString('#ff6a3d') : p.kind === 'sim' ? Cesium.Color.fromCssColorString('#9dffb2') : Cesium.Color.YELLOW;
      viewer.entities.add({ id,
        polygon: p.kind === 'region' ? undefined : { hierarchy: new Cesium.PolygonHierarchy(arr), material: col.withAlpha(p.kind==='fp' ? 0.10 : p.kind==='hazard' ? 0.15 : p.kind==='sim' ? 0.10 : (p.target ? 0.18 : 0.04)), classificationType: Cesium.ClassificationType.BOTH },
        polyline: { positions: arr.concat([arr[0]]), width: p.kind==='fp' ? 1.5 : p.kind==='sim' ? 1.8 : (p.target ? 3 : (p.kind==='region' ? 2 : 1)), material: col.withAlpha(p.kind==='region' ? 0.9 : (p.target ? 1 : 0.6)), clampToGround: true } });
    }
    if (d.selected && d.selected.lat !== undefined) {
      keep.add('sel');
      const pos = Cesium.Cartesian3.fromDegrees(d.selected.lon, d.selected.lat, 0);
      let ent = viewer.entities.getById('sel');
      const sp = sprite(d.selected.title||'TARGET', 'SELECTED · ' + (d.selected.kind||'').toUpperCase(), '#ffe45c', { icon: '◎' });
      if (!ent) viewer.entities.add({ id:'sel', position: pos, billboard:{ image: sp, verticalOrigin: Cesium.VerticalOrigin.BOTTOM, scale: 0.5, heightReference: Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY } });
      else { ent.position = pos; ent.billboard.image = sp; }
    }
    if (d.track && d.track.id) {
      keep.add('trk'); keep.add('trail');
      const t = d.track, pos = Cesium.Cartesian3.fromDegrees(t.lon, t.lat, t.alt||0);
      const sp = sprite((t.label||t.id) + ' · ' + Math.round((t.alt||0)*3.281).toLocaleString() + ' FT · ' + Math.round(t.spd||0) + ' KTS', t.sub || 'TRACKING', '#ffffff', {});
      let ent = viewer.entities.getById('trk');
      if (!ent) viewer.entities.add({ id:'trk', position: pos, billboard:{ image: sp, verticalOrigin: Cesium.VerticalOrigin.BOTTOM, scale: 0.55, disableDepthTestDistance: Number.POSITIVE_INFINITY } });
      else { ent.position = pos; ent.billboard.image = sp; }
      // detection box on the tracked target + leader lines to the nearest contacts
      keep.add('det');
      let det = viewer.entities.getById('det');
      if (!det) viewer.entities.add({ id:'det', position: pos, billboard:{ image: detBox(), scale: .8, disableDepthTestDistance: Number.POSITIVE_INFINITY } }); else det.position = pos;
      const near = (d.entities||[]).filter(e => e.id !== t.id && (e.kind === 'ac' || e.kind === 'sh')).map(e => ({ e, dist: Cesium.Cartesian3.distance(pos, Cesium.Cartesian3.fromDegrees(e.lon, e.lat, e.alt||0)) })).sort((a,b) => a.dist - b.dist).slice(0, 5);
      near.forEach((h, i) => {
        const lid = 'ld:' + i; keep.add(lid);
        const p2 = Cesium.Cartesian3.fromDegrees(h.e.lon, h.e.lat, h.e.alt||0);
        const mid = Cesium.Cartesian3.midpoint(pos, p2, new Cesium.Cartesian3());
        const card = sprite(h.e.label, (h.dist/1000).toFixed(0) + ' KM · BRG ' + String(Math.round(bearing(t.lat, t.lon, h.e.lat, h.e.lon))).padStart(3,'0') + '°', '#4de3ff', {});
        const le = viewer.entities.getById(lid);
        if (!le) viewer.entities.add({ id: lid, position: mid, polyline: { positions: [pos, p2], width: 1.2, material: Cesium.Color.fromCssColorString('#4de3ff').withAlpha(.55) }, billboard: { image: card, scale: .42, verticalOrigin: Cesium.VerticalOrigin.BOTTOM, disableDepthTestDistance: Number.POSITIVE_INFINITY } });
        else { le.position = mid; le.polyline.positions = [pos, p2]; le.billboard.image = card; }
      });
      if (t.trail && t.trail.length >= 4) {
        const tr = viewer.entities.getById('trail'); const ps = Cesium.Cartesian3.fromDegreesArray(t.trail);
        if (!tr) viewer.entities.add({ id:'trail', polyline:{ positions: ps, width: 2, material: new Cesium.PolylineGlowMaterialProperty({ glowPower: .25, color: Cesium.Color.fromCssColorString('#ff3b30') }), clampToGround: t.kind === 'ship' } });
        else tr.polyline.positions = ps;
      }
    } else { if (cockpit) setCockpit(false); if (trk) setTrack(null); }
    if (d.track && d.track.id && (!trk || trk.id !== d.track.id)) setTrack(d.track);
    for (const ent of viewer.entities.values.slice()) { if (!keep.has(ent.id)) viewer.entities.remove(ent); }
    try { renderCtx(d); } catch(e) {}
    const cts = d.counts || {}; $('nac').textContent = cts.ac||0; $('nsh').textContent = cts.sh||0; $('nsat').textContent = cts.sat||0; $('ncam').textContent = cts.cam||0;
    $('orb').textContent = d.orb||0; $('pass').textContent = String(d.pass||0).padStart(4,'0'); $('dens').textContent = (d.entities||[]).length;
    $('ctx').textContent = (d.track && d.track.label) ? ('TRACK ' + d.track.label.toUpperCase()) : (d.selected && d.selected.title ? d.selected.title.toUpperCase() : (sensor.toUpperCase() + ' · GLOBAL SECTOR'));
    viewer.scene.requestRender();
  }

  return { init, setBasemap, setTerrain, setBuildings, loadAssets, setView, setData, home, tilt, setCustomRaster, setCustomTilesets, setSensor, setHUD, setCockpit, setTool, clearTools, setShadows, focus, setTrack, setFollow, setModels, setRealism, setSpaceMode };
})();
window.addEventListener('load', () => post({type:'ready'}));
window.addEventListener('error', (e) => post({type:'status', text: 'JS: ' + e.message}));
</script></body></html>
"""#
    }
}
