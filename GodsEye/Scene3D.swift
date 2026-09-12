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
    @State private var customRaster: String? = nil   // id of active hand-rolled raster (nil = built-in basemap)

    var body: some View {
        ZStack(alignment: .top) {
            CesiumWebView(bridge: bridge, ionToken: s.ionToken, onMessage: handle)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Basemap.allCases) { b in
                                Button {
                                    if b.needsIon && s.ionToken.isEmpty && CesiumConfig.defaultIonToken.isEmpty { status = "\(b.title) needs a Cesium ion token (Settings → 3D Scene)"; return }
                                    s.basemap = b
                                    customRaster = nil
                                    bridge.eval("GE.setBasemap('\(b.rawValue)')")
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: b.icon)
                                        Text(b.title).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(s.basemap == b ? Color.black : Color.primary)
                                    .background(Capsule().fill(s.basemap == b ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial)))
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(customRasters, id: \.0) { r in
                                Button { selectCustomRaster(r.0, url: r.2, minZ: r.3, maxZ: r.4) } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "square.grid.3x3.fill")
                                        Text(r.1).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(customRaster == r.0 ? Color.black : Color.primary)
                                    .background(Capsule().fill(customRaster == r.0 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.ultraThinMaterial)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Menu {
                        if !allTilesets.isEmpty {
                            Section("Hand-rolled tilesets") {
                                ForEach(allTilesets, id: \.0) { ts in
                                    Toggle(isOn: tilesetBinding(ts.0)) { Label(ts.1, systemImage: "cube") }
                                }
                            }
                        }
                        Button { Task { await reloadCatalog() } } label: { Label("Reload tiles catalog", systemImage: "arrow.triangle.2.circlepath") }
                        Divider()
                        Toggle(isOn: $s.sceneTerrain) { Label("World Terrain (ion)", systemImage: "mountain.2") }
                        Toggle(isOn: $s.sceneBuildings) { Label("OSM Buildings (ion)", systemImage: "building.2") }
                        Toggle(isOn: $s.sceneEntities) { Label("Live contacts", systemImage: "airplane") }
                        Toggle(isOn: $s.sceneLines) { Label("Property lines", systemImage: "rectangle.dashed") }
                        Button { bridge.eval("GE.home()") } label: { Label("Look straight down", systemImage: "arrow.down.to.line") }
                        Button { bridge.eval("GE.tilt()") } label: { Label("Tilt 60°", systemImage: "rotate.3d") }
                    } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
                HStack {
                    Text(status).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
            }
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
        .onChange(of: s.sceneEntities) { _, _ in pushEntities() }
        .onChange(of: s.sceneLines) { _, _ in pushEntities() }
        .onChange(of: s.propertyLines) { _, _ in pushEntities() }
        .onDisappear { pushTimer?.invalidate(); pushTimer = nil }
    }

    // MARK: Bridge

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            status = "\(s.basemap.title) · tap to inspect"
            let assets = s.ionAssets.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            bridge.eval("GE.init({basemap:'\(s.basemap.rawValue)', terrain:\(s.sceneTerrain), buildings:\(s.sceneBuildings), assets:\(assets)})")
            let h = max(s.distance, 300)
            bridge.eval(String(format: "GE.setView(%.6f,%.6f,%.1f,%.2f,%.2f)", s.center.latitude, s.center.longitude, h, s.heading, s.pitch))
            pushEntities()
            pushTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in pushEntities() }
            Task { await reloadCatalog() }
        case "tap":
            guard let lat = msg["lat"] as? Double, let lon = msg["lon"] as? Double else { return }
            let d = (msg["height"] as? Double) ?? 3000
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            Task {
                let r = await s.reverseGeocode(c)
                let e = Entity.place(lat: lat, lon: lon, name: r.title, detail: r.detail, distance: min(max(d * 0.35, 3_000), 600_000), extraMeta: r.extraMeta)
                selected = e
                s.lookupIntel(for: e)
            }
        case "camera":
            if let lat = msg["lat"] as? Double, let lon = msg["lon"] as? Double, let h = msg["height"] as? Double {
                lastCam = (lat, lon, h, (msg["heading"] as? Double) ?? 0, (msg["pitch"] as? Double) ?? 0)
            }
        case "status":
            if let t = msg["text"] as? String { status = t }
        case "entity":
            if let id = msg["id"] as? String { pickEntity(id) }
        default: break
        }
    }

    // MARK: Hand-rolled tiles

    /// (id, title, urlTemplate, minZoom, maxZoom)
    private var customRasters: [(String, String, String, Int, Int)] {
        var out = catalog.rasters.map { ($0.id, $0.name, $0.url, $0.minZoom, $0.maxZoom) }
        let manual = s.customTileURL.trimmingCharacters(in: .whitespaces)
        if manual.contains("{z}") { out.append(("manual-raster", "Custom raster", manual, 0, 22)) }
        return out
    }

    /// (id, title, tileset.json url)
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
        let esc = url.replacingOccurrences(of: "'", with: "")
        bridge.eval("GE.setCustomRaster('\(esc)', \(minZ), \(maxZ))")
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

    private func pickEntity(_ id: String) {
        if let c = s.visibleContacts.first(where: { "ac-\($0.id)" == id }) { selected = Entity.from(c) }
        else if let v = s.visibleShips.first(where: { "sh-\($0.id)" == id }) { selected = Entity.from(v) }
        else if let cam = s.visibleCameras.first(where: { "cam-\($0.id)" == id }) { selected = Entity.from(cam) }
    }

    private func pushEntities() {
        guard ready else { return }
        var items: [[String: Any]] = []
        if s.sceneEntities {
            for c in s.visibleContacts.prefix(400) {
                items.append(["id": "ac-\(c.id)", "kind": "ac", "lat": c.lat, "lon": c.lon, "alt": Double(c.altFt ?? 0) * 0.3048,
                              "label": c.displayName, "heading": c.track, "mil": c.military])
            }
            for v in s.visibleShips.prefix(300) {
                items.append(["id": "sh-\(v.id)", "kind": "sh", "lat": v.lat, "lon": v.lon, "alt": 0, "label": v.displayName, "heading": v.cog, "mil": false])
            }
            for cam in s.visibleCameras.prefix(300) {
                items.append(["id": "cam-\(cam.id)", "kind": "cam", "lat": cam.lat, "lon": cam.lon, "alt": 0, "label": cam.name, "heading": 0, "mil": false])
            }
        }
        var polys: [[String: Any]] = []
        if s.sceneLines {
            for p in s.propertyLines {
                for ring in p.rings {
                    polys.append(["id": p.id, "kind": p.kind == .building ? "fp" : "parcel", "target": p.isTarget,
                                  "coords": ring.flatMap { [$0.longitude, $0.latitude] }])
                }
            }
        }
        var sel: [String: Any] = [:]
        if let e = selected { sel = ["lat": e.lat, "lon": e.lon, "title": e.title] }
        let payload: [String: Any] = ["entities": items, "polys": polys, "selected": sel]
        guard let d = try? JSONSerialization.data(withJSONObject: payload), let js = String(data: d, encoding: .utf8) else { return }
        bridge.eval("GE.setData(\(js))")
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
        return """
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<link href="https://cesium.com/downloads/cesiumjs/releases/\(v)/Build/Cesium/Widgets/widgets.css" rel="stylesheet">
<style>
html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden;-webkit-user-select:none}
#c{position:absolute;inset:0}
.cesium-widget-credits{opacity:.6;font-size:9px}
.cesium-viewer-bottom{padding-bottom:env(safe-area-inset-bottom)}
</style></head><body><div id="c"></div>
<script src="https://cesium.com/downloads/cesiumjs/releases/\(v)/Build/Cesium/Cesium.js"></script>
<script>
const post = (m) => { try { window.webkit.messageHandlers.godseye.postMessage(m); } catch(e){} };
const TOKEN = '\(tok)';
if (TOKEN) Cesium.Ion.defaultAccessToken = TOKEN;
window.GE = (() => {
  let viewer, tileset = null, buildings = null, customAssets = [], current = null, cfg = {};
  const ents = new Map();

  function esri(layer){ return new Cesium.UrlTemplateImageryProvider({ url: 'https://server.arcgisonline.com/ArcGIS/rest/services/'+layer+'/MapServer/tile/{z}/{y}/{x}', maximumLevel: 19, credit: 'Esri, Maxar, Earthstar Geographics' }); }
  function osm(){ return new Cesium.OpenStreetMapImageryProvider({ url: 'https://tile.openstreetmap.org/', credit: '© OpenStreetMap contributors' }); }

  let customTs = new Map();
  function setCustomRaster(url, minZ, maxZ){
    if (!viewer) return;
    const L = viewer.imageryLayers; L.removeAll();
    if (tileset) { viewer.scene.primitives.remove(tileset); tileset = null; }
    viewer.scene.globe.show = true;
    // Esri underneath so the area outside your hand-rolled tiles isn't black.
    L.addImageryProvider(esri('World_Imagery'));
    L.addImageryProvider(new Cesium.UrlTemplateImageryProvider({ url, minimumLevel: minZ||0, maximumLevel: maxZ||22, credit: 'hand-rolled · godseye-tiles', hasAlphaChannel: true }));
    current = 'custom';
    viewer.scene.requestRender();
  }
  async function setCustomTilesets(urls){
    if (!viewer) return;
    const want = new Set(urls||[]);
    for (const [u, t] of customTs) { if (!want.has(u)) { viewer.scene.primitives.remove(t); customTs.delete(u); } }
    for (const u of want) {
      if (customTs.has(u)) continue;
      try {
        const t = await Cesium.Cesium3DTileset.fromUrl(u, { maximumScreenSpaceError: 8, pointCloudShading: { attenuation: true, maximumAttenuation: 6, eyeDomeLighting: true } });
        viewer.scene.primitives.add(t); customTs.set(u, t);
        post({type:'status', text:'Loaded ' + u.split('/').slice(-3, -1).join('/')});
      } catch(e){ post({type:'status', text:'Tileset failed: ' + (e.message||e)}); }
    }
    viewer.scene.requestRender();
  }

  async function setBasemap(name){
    if (!viewer) { cfg.basemap = name; return; }
    current = name;
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
          post({type:'status', text:'Loading Google Photorealistic 3D Tiles…'});
          tileset = await Cesium.Cesium3DTileset.fromIonAssetId(\(CesiumConfig.googleTilesAsset), { showCreditsOnScreen: true });
          viewer.scene.primitives.add(tileset);
          viewer.scene.globe.show = false;
          break;
      }
      post({type:'status', text: name + ' · tap to inspect'});
    } catch(e) { post({type:'status', text:'Basemap failed: ' + (e.message||e)}); L.addImageryProvider(esri('World_Imagery')); }
    viewer.scene.requestRender();
  }

  async function setTerrain(on){
    if (!viewer) return;
    try { viewer.scene.setTerrain(on && TOKEN ? new Cesium.Terrain(Cesium.CesiumTerrainProvider.fromIonAssetId(1)) : new Cesium.Terrain(Promise.resolve(new Cesium.EllipsoidTerrainProvider()))); }
    catch(e){ post({type:'status', text:'Terrain: ' + (e.message||e)}); }
    viewer.scene.requestRender();
  }

  async function setBuildings(on){
    if (!viewer) return;
    if (buildings) { viewer.scene.primitives.remove(buildings); buildings = null; }
    if (on && TOKEN) { try { buildings = await Cesium.createOsmBuildingsAsync(); viewer.scene.primitives.add(buildings); } catch(e){ post({type:'status', text:'OSM Buildings: ' + (e.message||e)}); } }
    viewer.scene.requestRender();
  }

  async function loadAssets(ids){
    for (const p of customAssets) viewer.scene.primitives.remove(p);
    customAssets = [];
    if (!TOKEN) return;
    for (const id of ids||[]) {
      try { const t = await Cesium.Cesium3DTileset.fromIonAssetId(id); viewer.scene.primitives.add(t); customAssets.push(t); }
      catch(e){ post({type:'status', text:'ion asset ' + id + ': ' + (e.message||e)}); }
    }
    viewer.scene.requestRender();
  }

  function init(c){
    cfg = c || {};
    viewer = new Cesium.Viewer('c', {
      baseLayer: false, terrain: undefined, animation:false, timeline:false, geocoder:false, homeButton:false,
      sceneModePicker:false, baseLayerPicker:false, navigationHelpButton:false, infoBox:false, selectionIndicator:false,
      fullscreenButton:false, requestRenderMode:true, maximumRenderTimeChange: Infinity, msaaSamples: 4
    });
    viewer.scene.globe.enableLighting = false;
    viewer.scene.globe.depthTestAgainstTerrain = true;
    viewer.scene.screenSpaceCameraController.enableCollisionDetection = true;
    viewer.scene.postProcessStages.fxaa.enabled = true;
    setBasemap(cfg.basemap || 'esriImagery');
    setTerrain(!!cfg.terrain);
    setBuildings(!!cfg.buildings);
    loadAssets(cfg.assets);

    const h = new Cesium.ScreenSpaceEventHandler(viewer.canvas);
    h.setInputAction((click) => {
      const picked = viewer.scene.pick(click.position);
      if (Cesium.defined(picked) && picked.id && picked.id.id && picked.id.id.startsWith('e:')) { post({type:'entity', id: picked.id.id.slice(2)}); return; }
      let cart = null;
      if (viewer.scene.pickPositionSupported) { const p = viewer.scene.pickPosition(click.position); if (Cesium.defined(p)) cart = p; }
      if (!cart) cart = viewer.camera.pickEllipsoid(click.position, viewer.scene.globe.ellipsoid);
      if (!cart) return;
      const cg = Cesium.Cartographic.fromCartesian(cart);
      const camH = viewer.camera.positionCartographic.height;
      post({type:'tap', lat: Cesium.Math.toDegrees(cg.latitude), lon: Cesium.Math.toDegrees(cg.longitude), height: camH});
    }, Cesium.ScreenSpaceEventType.LEFT_CLICK);

    viewer.camera.moveEnd.addEventListener(() => {
      const c = viewer.camera;
      const cg = c.positionCartographic;
      // Center = where the view axis hits the globe (fallback: camera position).
      let lat = Cesium.Math.toDegrees(cg.latitude), lon = Cesium.Math.toDegrees(cg.longitude);
      const ray = c.getPickRay(new Cesium.Cartesian2(viewer.canvas.clientWidth/2, viewer.canvas.clientHeight/2));
      const hit = ray ? viewer.scene.globe.pick(ray, viewer.scene) : null;
      if (hit) { const hc = Cesium.Cartographic.fromCartesian(hit); lat = Cesium.Math.toDegrees(hc.latitude); lon = Cesium.Math.toDegrees(hc.longitude); }
      post({type:'camera', lat, lon, height: cg.height, heading: Cesium.Math.toDegrees(c.heading), pitch: 90 + Cesium.Math.toDegrees(c.pitch)});
    });
  }

  function setView(lat, lon, height, heading, pitch){
    if (!viewer) return;
    viewer.camera.setView({
      destination: Cesium.Cartesian3.fromDegrees(lon, lat, Math.max(height, 200)),
      orientation: { heading: Cesium.Math.toRadians(heading||0), pitch: Cesium.Math.toRadians(-90 + (pitch||0)), roll: 0 }
    });
    viewer.scene.requestRender();
  }
  function home(){ if (!viewer) return; const c = viewer.camera.positionCartographic; viewer.camera.flyTo({ destination: Cesium.Cartesian3.fromRadians(c.longitude, c.latitude, c.height), orientation:{heading:0, pitch:-Cesium.Math.PI_OVER_TWO, roll:0}, duration:0.8 }); }
  function tilt(){ if (!viewer) return; const c = viewer.camera.positionCartographic; viewer.camera.flyTo({ destination: Cesium.Cartesian3.fromRadians(c.longitude, c.latitude, Math.max(c.height, 400)), orientation:{heading:viewer.camera.heading, pitch:Cesium.Math.toRadians(-30), roll:0}, duration:0.8 }); }

  const colors = { ac: Cesium.Color.fromCssColorString('#4de3ff'), mil: Cesium.Color.ORANGE, sh: Cesium.Color.fromCssColorString('#5aa9ff'), cam: Cesium.Color.fromCssColorString('#c77dff') };
  function setData(d){
    if (!viewer) return;
    const keep = new Set();
    for (const e of (d.entities||[])) {
      const id = 'e:' + e.id; keep.add(id);
      const pos = Cesium.Cartesian3.fromDegrees(e.lon, e.lat, e.alt||0);
      const col = e.mil ? colors.mil : (colors[e.kind] || Cesium.Color.WHITE);
      let ent = viewer.entities.getById(id);
      if (!ent) {
        ent = viewer.entities.add({ id, position: pos,
          point: { pixelSize: e.kind==='ac'?7:6, color: col, outlineColor: Cesium.Color.BLACK, outlineWidth: 1, heightReference: e.kind==='ac'?Cesium.HeightReference.NONE:Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY },
          label: { text: e.label, font: '10px Menlo, monospace', fillColor: col, outlineColor: Cesium.Color.BLACK, outlineWidth: 2, style: Cesium.LabelStyle.FILL_AND_OUTLINE, pixelOffset: new Cesium.Cartesian2(0,-14), scaleByDistance: new Cesium.NearFarScalar(2000,1.0,300000,0.0), disableDepthTestDistance: Number.POSITIVE_INFINITY } });
      } else { ent.position = pos; ent.label.text = e.label; }
    }
    for (const p of (d.polys||[])) {
      const id = 'p:' + p.id + ':' + p.coords.length; keep.add(id);
      if (viewer.entities.getById(id)) continue;
      const arr = Cesium.Cartesian3.fromDegreesArray(p.coords);
      const fp = p.kind === 'fp';
      const col = fp ? Cesium.Color.CYAN : Cesium.Color.YELLOW;
      viewer.entities.add({ id,
        polygon: { hierarchy: new Cesium.PolygonHierarchy(arr), material: col.withAlpha(fp ? 0.10 : (p.target ? 0.18 : 0.04)), classificationType: Cesium.ClassificationType.BOTH },
        polyline: { positions: arr.concat([arr[0]]), width: fp ? 1.5 : (p.target ? 3 : 1), material: col.withAlpha(fp ? 0.9 : (p.target ? 1 : 0.6)), clampToGround: true } });
    }
    if (d.selected && d.selected.lat !== undefined) {
      keep.add('sel');
      const pos = Cesium.Cartesian3.fromDegrees(d.selected.lon, d.selected.lat, 0);
      let ent = viewer.entities.getById('sel');
      if (!ent) viewer.entities.add({ id:'sel', position: pos, point:{ pixelSize: 10, color: Cesium.Color.YELLOW, outlineColor: Cesium.Color.BLACK, outlineWidth: 2, heightReference: Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: Number.POSITIVE_INFINITY }, label:{ text: d.selected.title||'', font:'11px Menlo, monospace', fillColor: Cesium.Color.YELLOW, outlineColor: Cesium.Color.BLACK, outlineWidth: 2, style: Cesium.LabelStyle.FILL_AND_OUTLINE, pixelOffset: new Cesium.Cartesian2(0,-16), disableDepthTestDistance: Number.POSITIVE_INFINITY } });
      else { ent.position = pos; ent.label.text = d.selected.title||''; }
    }
    for (const ent of viewer.entities.values.slice()) { if (!keep.has(ent.id)) viewer.entities.remove(ent); }
    viewer.scene.requestRender();
  }

  return { init, setBasemap, setTerrain, setBuildings, loadAssets, setView, setData, home, tilt, setCustomRaster, setCustomTilesets };
})();
window.addEventListener('load', () => post({type:'ready'}));
window.addEventListener('error', (e) => post({type:'status', text: 'JS: ' + e.message}));
</script></body></html>
"""
    }
}
