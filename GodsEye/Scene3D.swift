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
    static let defaultIonToken = ""
    static let googleTilesAsset = 2275207      // Google Photorealistic 3D Tiles via ion
    static let osmBuildingsAsset = 96188       // Cesium OSM Buildings
    /// Fallback Google Map Tiles API key (Photorealistic 3D without ion). Settings → 3D Scene overrides.
    static let defaultGoogleKey = ""
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
    struct Tileset: Decodable, Equatable, Identifiable { let id: String; let name: String; let url: String; let bbox: [Double]; let credit: String? }
    var rasters: [Raster] = []
    var tilesets: [Tileset] = []

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
    @State private var catalog = TilesCatalog()
    @State private var customRaster: String? = nil
    @State private var cockpit = false
    @State private var dense = false
    @State private var chromeHidden = false
    @State private var tool: SceneTool = .none
    @State private var shadows = false
    @State private var shadowHour: Double = 14

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
        .onChange(of: s.trackedID) { _, _ in pushEntities() }
        .onChange(of: selected) { _, _ in pushEntities() }
        .onDisappear { pushTimer?.invalidate(); pushTimer = nil }
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
            let gkey = (s.googleMapsKey.isEmpty ? CesiumConfig.defaultGoogleKey : s.googleMapsKey).replacingOccurrences(of: "'", with: "")
            bridge.eval("GE.init({basemap:'\(s.basemap.rawValue)', terrain:\(s.sceneTerrain), buildings:\(s.sceneBuildings), assets:\(assets), sensor:'\(s.sensor.rawValue)', hud:\(s.hud), accent:'\(s.accentHex)', googleKey:'\(gkey)'})")
            let h = max(s.distance, 300)
            bridge.eval(String(format: "GE.setView(%.6f,%.6f,%.1f,%.2f,%.2f)", s.center.latitude, s.center.longitude, h, s.heading, s.pitch))
            pushEntities()
            pushTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in pushEntities() }
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
    }

    private func trackEntity(_ id: String) {
        if let c = (s.contacts + s.militaryContacts).first(where: { "ac-\($0.id)" == id }) { s.track(Entity.from(c)) }
        else if let v = s.ships.values.first(where: { "sh-\($0.id)" == id }) { s.track(Entity.from(v)) }
    }

    private func pushEntities() {
        guard ready else { return }
        var items: [[String: Any]] = []
        if s.sceneEntities {
            let acs = dense ? (s.contacts + s.militaryContacts) : s.visibleContacts
            for c in acs.prefix(dense ? 6000 : 500) {
                items.append(["id": "ac-\(c.id)", "kind": "ac", "lat": c.lat, "lon": c.lon, "alt": Double(c.altFt ?? 0) * 0.3048,
                              "label": c.displayName, "heading": c.track, "mil": c.military, "spd": c.groundSpeedKt ?? 0,
                              "sub": [c.type ?? "", c.registration ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")])
            }
            let shs = dense ? Array(s.ships.values) : s.visibleShips
            for v in shs.prefix(dense ? 3000 : 400) {
                items.append(["id": "sh-\(v.id)", "kind": "sh", "lat": v.lat, "lon": v.lon, "alt": 0, "label": v.displayName, "heading": v.cog, "mil": false, "spd": v.sogKt, "sub": "MMSI \(v.id)"])
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
                              "sub": "\(sat.cls.label) · \(Int(sat.altKm)) km", "cls": sat.cls.rawValue])
            }
            for tr in s.visibleTrains.prefix(300) {
                items.append(["id": "train-\(tr.id)", "kind": "train", "lat": tr.lat, "lon": tr.lon, "alt": 0, "label": tr.name, "heading": 0, "mil": false, "sub": "\(tr.operatorName) · \(Int(tr.speedKmh)) km/h"])
            }
            for ap in s.visibleAirports.prefix(200) {
                items.append(["id": "apt-\(ap.id)", "kind": "apt", "lat": ap.lat, "lon": ap.lon, "alt": 0, "label": ap.iata.isEmpty ? ap.id : ap.iata, "heading": 0, "mil": false, "sub": ap.name])
            }
            for n in s.infra.prefix(300) {
                items.append(["id": "infra-\(n.id)", "kind": "infra", "lat": n.lat, "lon": n.lon, "alt": 0, "label": n.name, "heading": 0, "mil": false, "sub": n.kind.label])
            }
            for st in s.storms.prefix(100) {
                items.append(["id": "storm-\(st.id)", "kind": "storm", "lat": st.lat, "lon": st.lon, "alt": 0, "label": "STORM", "heading": st.headingDeg, "mil": false, "sub": "\(Int(st.speedKmh)) km/h · \(Int(st.intensity)) dBZ"])
            }
            for cam in s.visibleCameras.prefix(300) {
                items.append(["id": "cam-\(cam.id)", "kind": "cam", "lat": cam.lat, "lon": cam.lon, "alt": 0, "label": cam.name, "heading": cam.heading ?? -1, "mil": false,
                              "img": cam.imageURL, "sub": "\(cam.source)\(cam.isLiveVideo ? " · LIVE" : "")", "watch": s.cctv.watching.contains(cam.id)])
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
        var sel: [String: Any] = [:]
        if let e = selected { sel = ["lat": e.lat, "lon": e.lon, "title": e.title, "kind": e.kind.rawValue] }
        var track: [String: Any] = [:]
        if let te = s.trackedEntity, let tc = s.trackedCoord {
            let c = (s.contacts + s.militaryContacts).first { "ac-\($0.id)" == te.id }
            track = ["id": te.id, "lat": tc.latitude, "lon": tc.longitude, "alt": Double(c?.altFt ?? 0) * 0.3048,
                     "heading": c?.track ?? 0, "spd": c?.groundSpeedKt ?? 0, "label": te.title, "kind": te.kind.rawValue,
                     "trail": s.trail.suffix(200).flatMap { [$0.longitude, $0.latitude] }]
        }
        let payload: [String: Any] = ["entities": items, "polys": polys, "selected": sel, "track": track,
                                      "counts": ["ac": s.contacts.count + s.militaryContacts.count, "sh": s.ships.count, "sat": s.satellites.count, "cam": s.cameras.count],
                                      "orb": s.satellites.count, "pass": Int(Date().timeIntervalSince1970 / 90) % 10000]
        guard let d = try? JSONSerialization.data(withJSONObject: payload), let js = String(data: d, encoding: .utf8) else { return }
        bridge.eval("GE.setData(\(js))")
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
        let urls = allTilesets.filter { s.enabledTilesets.contains($0.0) }.map { $0.2 }
        guard let d = try? JSONSerialization.data(withJSONObject: urls), let js = String(data: d, encoding: .utf8) else { return }
        bridge.eval("GE.setCustomTilesets(\(js))")
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

window.GE = (() => {
  let viewer, tileset = null, buildings = null, customAssets = [], stage = null, cfg = {}, hudOn = true, sensor = 'normal';
  let customTs = new Map(), lastData = null, cockpit = false, camImgs = new Map(), t0 = Date.now();
  const rasterCredit = { esriImagery:'ESRI', esriHybrid:'ESRI', esriStreets:'ESRI', osm:'OSM', google3D:'GOOGLE 3D', bingAerial:'BING', bingHybrid:'BING', custom:'MRZEFV' };

  function esri(layer){ return new Cesium.UrlTemplateImageryProvider({ url: 'https://server.arcgisonline.com/ArcGIS/rest/services/'+layer+'/MapServer/tile/{z}/{y}/{x}', maximumLevel: 19, credit: 'Esri, Maxar, Earthstar Geographics' }); }
  function osm(){ return new Cesium.OpenStreetMapImageryProvider({ url: 'https://tile.openstreetmap.org/', credit: '© OpenStreetMap contributors' }); }

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
  async function setCustomTilesets(urls){
    if (!viewer) return;
    const want = new Set(urls||[]);
    for (const [u, t] of customTs) { if (!want.has(u)) { viewer.scene.primitives.remove(t); customTs.delete(u); } }
    for (const u of want) {
      if (customTs.has(u)) continue;
      try { const t = await Cesium.Cesium3DTileset.fromUrl(u, { maximumScreenSpaceError: 8, pointCloudShading: { attenuation: true, maximumAttenuation: 6, eyeDomeLighting: true } });
        viewer.scene.primitives.add(t); customTs.set(u, t); status('LOADED ' + u.split('/').slice(-3,-1).join('/').toUpperCase()); }
      catch(e){ status('TILESET FAILED: ' + (e.message||e)); }
    }
    viewer.scene.requestRender();
  }
  async function setTerrain(on){
    if (!viewer) return;
    try { viewer.scene.setTerrain(on && TOKEN ? new Cesium.Terrain(Cesium.CesiumTerrainProvider.fromIonAssetId(1)) : new Cesium.Terrain(Promise.resolve(new Cesium.EllipsoidTerrainProvider()))); }
    catch(e){ status('TERRAIN: ' + (e.message||e)); }
    viewer.scene.requestRender();
  }
  async function setBuildings(on){
    if (!viewer) return;
    if (buildings) { viewer.scene.primitives.remove(buildings); buildings = null; }
    if (on && TOKEN) { try { buildings = await Cesium.createOsmBuildingsAsync(); viewer.scene.primitives.add(buildings); } catch(e){ status('OSM BUILDINGS: ' + (e.message||e)); } }
    viewer.scene.requestRender();
  }
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
    viewer.scene.requestRenderMode = !SHADERS[sensor] || sensor === 'flir';   // animated shaders need continuous render
    viewer.scene.requestRender();
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
    setSensor(cfg.sensor || 'normal'); setHUD(cfg.hud !== false);
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
    viewer.scene.requestRenderMode = !on && !(SHADERS[sensor] && sensor !== 'flir');
    viewer.scene.requestRender();
  }

  // ---- cockpit ----
  function setCockpit(on){
    cockpit = !!on && !!(lastData && lastData.track && lastData.track.id);
    $('cock').classList.toggle('on', cockpit);
    $('cross').style.display = cockpit ? 'none' : '';
    viewer.scene.screenSpaceCameraController.enableInputs = !cockpit;
    if (cockpit) cockpitTick(); else { viewer.trackedEntity = undefined; }
    post({type:'cockpit', on: cockpit});
  }
  function cockpitTick(){
    const t = lastData && lastData.track; if (!t || !t.id) { setCockpit(false); return; }
    const alt = Math.max(t.alt || 0, 60), hd = Cesium.Math.toRadians(t.heading || 0);
    const back = t.kind === 'ship' ? 400 : 700, up = t.kind === 'ship' ? 120 : 220;
    const pos = Cesium.Cartesian3.fromDegrees(t.lon, t.lat, alt);
    const enu = Cesium.Transforms.eastNorthUpToFixedFrame(pos);
    const off = new Cesium.Cartesian3(-Math.sin(hd)*back, -Math.cos(hd)*back, up);
    const dest = Cesium.Matrix4.multiplyByPoint(enu, off, new Cesium.Cartesian3());
    viewer.camera.setView({ destination: dest, orientation: { heading: hd, pitch: Cesium.Math.toRadians(-14), roll: 0 } });
    $('cname').textContent = (t.label||'').toUpperCase(); $('cspd').textContent = Math.round(t.spd||0); $('chdg').textContent = String(Math.round(t.heading||0)).padStart(3,'0'); $('calt').textContent = Math.round((t.alt||0)*3.281).toLocaleString();
    const marks = []; for (let d = -60; d <= 60; d += 15) { const b = ((t.heading||0) + d + 360) % 360; const n = Math.round(b/15)*15 % 360; marks.push(n === 0 ? 'N' : n === 90 ? 'E' : n === 180 ? 'S' : n === 270 ? 'W' : (d === 0 ? '▲' : String(n))); } $('compass').textContent = marks.join('   ');
    viewer.scene.requestRender();
  }

  // ---- data ----
  const colors = { ac:'#4de3ff', mil:'#ffa63d', sh:'#5aa9ff', cam:'#c77dff', eq:'#ff6a3d', fire:'#ff3b30', sat:'#9ad7ff', train:'#ffd166', apt:'#8ecae6', infra:'#2ec4b6', storm:'#c77dff' };
  const icons = { ac:'✈', sh:'⛴', cam:'▣', eq:'◎', fire:'▲', sat:'✦', train:'▬', apt:'⊕', infra:'▦', storm:'≋' };
  function setData(d){
    if (!viewer) return;
    lastData = d;
    const keep = new Set();
    const camH = viewer.camera.positionCartographic.height;
    const boxed = camH < 60000;
    for (const e of (d.entities||[])) {
      const id = 'e:' + e.id; keep.add(id);
      const pos = Cesium.Cartesian3.fromDegrees(e.lon, e.lat, e.alt||0);
      const col = e.mil ? colors.mil : (colors[e.kind] || '#fff');
      const cc = Cesium.Color.fromCssColorString(col);
      let ent = viewer.entities.getById(id);
      const isCam = e.kind === 'cam';
      const img = boxed ? (isCam && camH < 8000 ? (camImgs.get(e.id) || sprite(e.label, e.sub, col, { icon: '▣' })) : sprite(e.label, e.sub, col, { icon: icons[e.kind] || '▣' })) : null;
      if (isCam && camH < 8000 && !camImgs.has(e.id)) { camImgs.set(e.id, null); camCard(e.img, e.label).then(cv => { camImgs.set(e.id, cv); const en = viewer.entities.getById(id); if (en && en.billboard) { en.billboard.image = cv; viewer.scene.requestRender(); } }); }
      if (!ent) {
        ent = viewer.entities.add({ id, position: pos,
          point: { pixelSize: e.kind==='ac'?6:5, color: cc, outlineColor: Cesium.Color.BLACK, outlineWidth: 1, heightReference: e.kind==='ac'?Cesium.HeightReference.NONE:Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY, show: !boxed },
          billboard: { image: img || sprite(e.label, e.sub, col), verticalOrigin: Cesium.VerticalOrigin.BOTTOM, pixelOffset: new Cesium.Cartesian2(0,-6), scale: 0.5, heightReference: e.kind==='ac'?Cesium.HeightReference.NONE:Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY, show: boxed, scaleByDistance: new Cesium.NearFarScalar(500,1.0,200000,0.45) } });
      } else { ent.position = pos; if (boxed && img) ent.billboard.image = img; ent.point.show = !boxed; ent.billboard.show = boxed; }
      if (e.watch && ent.billboard) ent.billboard.color = Cesium.Color.fromCssColorString('#ffb0b0');
      if (e.kind === 'eq' && e.r) { const rid = 'r:' + e.id; keep.add(rid); if (!viewer.entities.getById(rid)) viewer.entities.add({ id: rid, position: Cesium.Cartesian3.fromDegrees(e.lon, e.lat, 0), ellipse: { semiMajorAxis: e.r, semiMinorAxis: e.r, material: cc.withAlpha(.12), outline: true, outlineColor: cc.withAlpha(.7), classificationType: Cesium.ClassificationType.BOTH } }); }
      if (e.kind === 'storm' && e.heading >= 0) { const vid = 'v:' + e.id; keep.add(vid); const end = Cesium.Cartesian3.fromDegrees(e.lon + Math.sin(e.heading*Math.PI/180)*.05, e.lat + Math.cos(e.heading*Math.PI/180)*.05, 0); const ve = viewer.entities.getById(vid); if (!ve) viewer.entities.add({ id: vid, polyline: { positions: [pos, end], width: 2, material: new Cesium.PolylineDashMaterialProperty({ color: cc }), clampToGround: true } }); else ve.polyline.positions = [pos, end]; }
    }
    for (const p of (d.polys||[])) {
      const id = 'p:' + p.id + ':' + p.coords.length; keep.add(id);
      if (viewer.entities.getById(id)) continue;
      const arr = Cesium.Cartesian3.fromDegreesArray(p.coords);
      const col = p.kind === 'fp' ? Cesium.Color.CYAN : p.kind === 'region' ? Cesium.Color.WHITE : p.kind === 'hazard' ? Cesium.Color.fromCssColorString('#ff6a3d') : Cesium.Color.YELLOW;
      viewer.entities.add({ id,
        polygon: p.kind === 'region' ? undefined : { hierarchy: new Cesium.PolygonHierarchy(arr), material: col.withAlpha(p.kind==='fp' ? 0.10 : p.kind==='hazard' ? 0.15 : (p.target ? 0.18 : 0.04)), classificationType: Cesium.ClassificationType.BOTH },
        polyline: { positions: arr.concat([arr[0]]), width: p.kind==='fp' ? 1.5 : (p.target ? 3 : (p.kind==='region' ? 2 : 1)), material: col.withAlpha(p.kind==='region' ? 0.9 : (p.target ? 1 : 0.6)), clampToGround: true } });
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
      const sp = sprite(t.label||t.id, 'TRACKING · ' + Math.round(t.spd||0) + ' KTS · ' + Math.round((t.alt||0)*3.281).toLocaleString() + ' FT', '#ff3b30', { icon: '◉' });
      let ent = viewer.entities.getById('trk');
      if (!ent) viewer.entities.add({ id:'trk', position: pos, billboard:{ image: sp, verticalOrigin: Cesium.VerticalOrigin.BOTTOM, scale: 0.55, disableDepthTestDistance: Number.POSITIVE_INFINITY } });
      else { ent.position = pos; ent.billboard.image = sp; }
      if (t.trail && t.trail.length >= 4) {
        const tr = viewer.entities.getById('trail'); const ps = Cesium.Cartesian3.fromDegreesArray(t.trail);
        if (!tr) viewer.entities.add({ id:'trail', polyline:{ positions: ps, width: 2, material: new Cesium.PolylineGlowMaterialProperty({ glowPower: .25, color: Cesium.Color.fromCssColorString('#ff3b30') }), clampToGround: t.kind === 'ship' } });
        else tr.polyline.positions = ps;
      }
    } else if (cockpit) setCockpit(false);
    for (const ent of viewer.entities.values.slice()) { if (!keep.has(ent.id)) viewer.entities.remove(ent); }
    const cts = d.counts || {}; $('nac').textContent = cts.ac||0; $('nsh').textContent = cts.sh||0; $('nsat').textContent = cts.sat||0; $('ncam').textContent = cts.cam||0;
    $('orb').textContent = d.orb||0; $('pass').textContent = String(d.pass||0).padStart(4,'0'); $('dens').textContent = (d.entities||[]).length;
    $('ctx').textContent = (d.track && d.track.label) ? ('TRACK ' + d.track.label.toUpperCase()) : (d.selected && d.selected.title ? d.selected.title.toUpperCase() : (sensor.toUpperCase() + ' · GLOBAL SECTOR'));
    viewer.scene.requestRender();
  }

  return { init, setBasemap, setTerrain, setBuildings, loadAssets, setView, setData, home, tilt, setCustomRaster, setCustomTilesets, setSensor, setHUD, setCockpit, setTool, clearTools, setShadows };
})();
window.addEventListener('load', () => post({type:'ready'}));
window.addEventListener('error', (e) => post({type:'status', text: 'JS: ' + e.message}));
</script></body></html>
"""#
    }
}
