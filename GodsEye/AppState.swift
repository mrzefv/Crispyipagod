import Foundation
import SwiftUI
import MapKit
import CoreLocation
import BackgroundTasks
import UserNotifications

struct RegionOutline: Identifiable {
    let id = UUID()
    let name: String
    let rings: [[CLLocationCoordinate2D]]
}

extension Keyframe {
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct Annotation2D: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let lat: Double
    let lon: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

@MainActor
final class AppState: ObservableObject {
    static let home = CLLocationCoordinate2D(latitude: 20, longitude: -20)
    static let globeDistance: Double = 26_000_000

    // Camera
    @Published var camera: MapCameraPosition = .camera(MapCamera(centerCoordinate: AppState.home, distance: AppState.globeDistance, heading: 0, pitch: 0))
    @Published var center: CLLocationCoordinate2D = AppState.home
    @Published var distance: Double = AppState.globeDistance
    @Published var heading: Double = 0
    @Published var pitch: Double = 0
    @Published var centerName: String = "GLOBAL VIEW"

    // Data
    @Published var layers: Set<Layer> {
        didSet {
            ud.set(layers.map(\.rawValue), forKey: "layers")
            rebuildDisplay()
            if layers.contains(.military) && militaryContacts.isEmpty { Task { await refreshMilitary() } }
            if layers.contains(.satellites) && propagators.isEmpty { Task { await refreshSatellites() } }
            if (layers.contains(.cctv) || !cctv.watching.isEmpty) && cameras.isEmpty { Task { await refreshCameras() } }
            if layers.contains(.ships) { connectAIS() } else { ais.disconnect() }
            if layers.contains(.fires) && fires.isEmpty { Task { await refreshFires() } }
            if layers.contains(.radio) && radioStations.isEmpty { Task { await refreshRadio() } }
            if layers.contains(.cables) && cables.isEmpty { Task { await refreshCables() } }
            if layers.contains(.bikeshare) { Task { await refreshBikes() } }
            if layers.contains(.infra) { Task { await refreshInfra() } }
            if layers.contains(.airport) { Task { await refreshAirport() } }
            if layers.contains(.residential) { Task { await refreshResidential() } } else { residential = [] }
            if layers.contains(.radar) || layers.contains(.satir) { Task { if radar.frames.isEmpty { await radar.load() }; rebuildRadar() } } else { radar.composite = nil; radar.satComposite = nil }
            if layers.contains(.wind) { Task { await refreshWind() } }
            if layers.contains(.power) { Task { await refreshPower() } }
            if layers.contains(.rail) { Task { await refreshRail() } }
            if layers.contains(.trains) && trains.isEmpty { Task { await refreshTrains() } }
            if layers.contains(.airports) && airports.isEmpty { Task { await refreshAirports() } }
            if layers.contains(.stations) { Task { await refreshStations() } }
            if layers.contains(.alerts) && hazards.isEmpty { Task { await refreshHazards() } }
            if layers.contains(.space) { Task { await refreshSpace() } }
            if layers.contains(.scanner) && scanners.isEmpty { Task { await refreshScanners() } }
            if layers.contains(.peaks) { Task { await refreshPeaks() } }
            if layers.contains(.simulation) { startSimulation() } else { stopSimulation() }
        }
    }
    @Published var contacts: [Contact] = [] { didSet { rebuildDisplay(); trackTick(fromPoll: true) } }
    @Published var militaryContacts: [Contact] = [] { didSet { rebuildDisplay() } }
    @Published var quakes: [Quake] = [] { didSet { rebuildDisplay() } }
    @Published var ships: [String: Ship] = [:]
    @Published var satellites: [Satellite] = []
    @Published var cameras: [Camera] = []
    @Published var fires: [Fire] = [] { didSet { rebuildDisplay() } }
    @Published var bikes: [BikeStation] = []
    @Published var radioStations: [RadioStation] = []
    @Published var infra: [InfraNode] = []
    @Published var airportFeatures: [AirportFeature] = []
    @Published var residential: [ResidentialBlueprint] = []
    @Published var cables: [Cable] = []
    @Published private(set) var visibleFires: [Fire] = []
    @Published private(set) var visibleBikes: [BikeStation] = []
    @Published private(set) var visibleRadio: [RadioStation] = []
    @Published private(set) var visibleCables: [Cable] = []
    let radar = RadarEngine()
    @Published var viewWidth: Double = 390
    @Published var radarOpacity: Double = 0.75 { didSet { ud.set(radarOpacity, forKey: "radarOpacity") } }
    @Published var winds: [WindVector] = []
    @Published var powerLines: [PowerLine] = []
    @Published var powerNodes: [InfraNode] = []
    @Published var railLines: [RailLine] = []
    @Published var railStations: [RailStation] = []
    @Published var trains: [Train] = []
    @Published var airports: [Airport] = []
    @Published var stations: [WxStation] = []
    @Published var hazards: [HazardAlert] = []
    @Published var scanners: [ScannerFeed] = []
    @Published var peaks: [Peak] = []
    @Published var space = SpaceWeather()
    @Published var auroraPoints: [AuroraPoint] = []
    @Published var night: [CLLocationCoordinate2D] = []
    @Published var storms: [StormCell] = []
    @Published var simulationTick = 0
    @Published var simulationRevision = 0
    @Published var showRadar = false
    @Published var showStation: WxStation?
    @Published var showProfile = false
    @Published var showSpace = false
    @Published var showScanner = false
    @Published var profile: [(dist: Double, elev: Double)] = []
    @Published var profileLoading = false
    @Published var scannerNow: ScannerFeed?
    @Published private(set) var visibleAirports: [Airport] = []
    @Published private(set) var visibleStations: [WxStation] = []
    @Published private(set) var visibleHazards: [HazardAlert] = []
    @Published private(set) var visibleTrains: [Train] = []
    @Published var quakeWindowDays = 1 { didSet { Task { await refreshQuakes() } } }
    private let scannerPlayer = RadioPlayer()
    @Published var iss: SatPos?
    @Published var launches: [Launch] = []
    @Published var lastUpdate: Date?
    @Published var feedErrors = 0
    @Published var aisStatus = "AIS: idle"
    private var propagators: [SGP4] = []

    // Cached display lists
    @Published private(set) var visibleContacts: [Contact] = []
    @Published private(set) var visibleQuakes: [Quake] = []
    @Published private(set) var visibleShips: [Ship] = []
    @Published private(set) var visibleCameras: [Camera] = []

    // UI
    @Published var selected: Entity?
    @Published var showTimeline = false
    @Published var showRoster = false
    @Published var tab = 0
    @Published var status = "Initializing…"
    @Published var ready = false
    @Published var toast: String?

    // Modes
    @Published var sensor: SensorMode { didSet { ud.set(sensor.rawValue, forKey: "sensor") } }
    @Published var hud: Bool { didSet { ud.set(hud, forKey: "hud") } }
    @Published var detection: Bool { didSet { ud.set(detection, forKey: "detection") } }
    @Published var annotations: [Annotation2D] = []
    @Published var regions: [RegionOutline] = []
    @Published var measureMode = false
    @Published var measureA: CLLocationCoordinate2D?
    @Published var measureB: CLLocationCoordinate2D?
    @Published var measureLine: [CLLocationCoordinate2D] = []
    @Published var orbiting = false
    @Published var wakes: Bool { didSet { ud.set(wakes, forKey: "wakes") } }
    @Published var viewsheds: Bool { didSet { ud.set(viewsheds, forKey: "viewsheds") } }
    @Published var aiSummary = ""
    @Published var traceHistory: [CLLocationCoordinate2D] = []
    @Published var weather: Weather?
    @Published var passes: [ISSPass] = []
    @Published var showRadio = false
    @Published var showReplay = false
    @Published var showScenes = false
    @Published var showQR = false
    @Published var replay: LaunchReplay?
    @Published var replayT: Double = 0
    @Published var replayRate: Double = 1
    @Published var replayPlaying = false
    @Published var keyframes: [Keyframe] = []
    @Published var scenePlaying = false
    let radio = RadioPlayer()
    let cctv = CamRecorder()
    @Published var liveCamera: Camera?
    @Published var intel: [String: PlaceIntel] = [:]
    @Published var intelLoading: Set<String> = []
    @Published var propertyLines: [ParcelPolygon] = []   // parcel + footprint polygons for the last looked-up place
    private var orbitTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var sceneTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var weatherTask: Task<Void, Never>?
    private var lastRegionFetch: (center: CLLocationCoordinate2D, at: Date)?

    // Tracking
    @Published var trackedID: String?
    @Published var trackedCoord: CLLocationCoordinate2D?
    @Published var trackedHeading: Double = 0
    @Published var trackedEntity: Entity?
    @Published var trail: [CLLocationCoordinate2D] = []
    @Published var chase = false
    @Published var satTrack: [CLLocationCoordinate2D] = []
    private var trackTask: Task<Void, Never>?
    private var lastTrackedFix: (coord: CLLocationCoordinate2D, at: Date, gsKt: Double, track: Double)?

    // Director
    @Published var directing = false
    private var directorTask: Task<Void, Never>?
    private var programmaticMoveUntil = Date.distantPast

    // Timeline
    let windowStart: Date
    let windowEnd: Date
    @Published var timeCursor: Date? { didSet { if (timeCursor == nil) != (oldValue == nil) || playing == false { rebuildDisplay(); rebuildRadar() } } }
    @Published var playing = false
    @Published var focusedEvent: Entity?

    // Bookmarks
    @Published var bookmarks: [Bookmark] = [] {
        didSet { if let d = try? JSONEncoder().encode(bookmarks) { ud.set(d, forKey: "bookmarks") } }
    }

    // Settings
    @Published var mapStyleRaw: String { didSet { ud.set(mapStyleRaw, forKey: "mapStyle") } }
    @Published var accentRaw: String { didSet { ud.set(accentRaw, forKey: "accent") } }
    @Published var performanceMode: Bool { didSet { ud.set(performanceMode, forKey: "perf"); rebuildDisplay() } }
    @Published var offlineMode: Bool { didSet { ud.set(offlineMode, forKey: "offline"); Feeds.shared.offline = offlineMode } }
    @Published var showLabels: Bool { didSet { ud.set(showLabels, forKey: "labels") } }
    @Published var aisKey: String { didSet { ud.set(aisKey, forKey: "aisKey"); if layers.contains(.ships) { connectAIS() } } }
    @Published var firmsKey: String { didSet { ud.set(firmsKey, forKey: "firmsKey"); if layers.contains(.fires) { Task { await refreshFires() } } } }

    // 3D scene (CesiumJS: Esri / OSM / Google Photorealistic 3D / ion assets)
    @Published var show3D = false
    @Published var ionToken: String { didSet { ud.set(ionToken, forKey: "ionToken") } }
    @Published var ionAssets: String { didSet { ud.set(ionAssets, forKey: "ionAssets") } }
    @Published var googleMapsKey: String { didSet { ud.set(googleMapsKey, forKey: "googleMapsKey") } }
    @Published var keysAutoFilled: [String] = []
    @Published var keysMessage = ""
    @Published var basemap: Basemap { didSet { ud.set(basemap.rawValue, forKey: "basemap") } }
    @Published var sceneTerrain: Bool { didSet { ud.set(sceneTerrain, forKey: "sceneTerrain") } }
    @Published var sceneBuildings: Bool { didSet { ud.set(sceneBuildings, forKey: "sceneBuildings") } }
    @Published var sceneEntities: Bool { didSet { ud.set(sceneEntities, forKey: "sceneEntities") } }
    @Published var sceneLines: Bool { didSet { ud.set(sceneLines, forKey: "sceneLines") } }
    // Hand-rolled tiles (godseye-tiles repo on GitHub Pages)
    @Published var tilesCatalogURL: String { didSet { ud.set(tilesCatalogURL, forKey: "tilesCatalogURL") } }
    @Published var customTileURL: String { didSet { ud.set(customTileURL, forKey: "customTileURL") } }
    @Published var customTilesets: String { didSet { ud.set(customTilesets, forKey: "customTilesets") } }
    @Published var enabledTilesets: Set<String> { didSet { ud.set(Array(enabledTilesets), forKey: "enabledTilesets") } }
    @Published var sceneRealism: String { didSet { ud.set(sceneRealism, forKey: "sceneRealism") } }
    @Published var anthropicKey: String { didSet { ud.set(anthropicKey, forKey: "anthropicKey") } }
    @Published var aiModel: String { didSet { ud.set(aiModel, forKey: "aiModel") } }
    @Published var alertMilitary: Bool { didSet { ud.set(alertMilitary, forKey: "alertMil"); if alertMilitary { Alerts.shared.requestPermission() } } }
    @Published var alertQuakes: Bool { didSet { ud.set(alertQuakes, forKey: "alertEq"); if alertQuakes { Alerts.shared.requestPermission() } } }
    @Published var alertISS: Bool { didSet { ud.set(alertISS, forKey: "alertIss"); if alertISS { Alerts.shared.requestPermission(); computePasses() } } }
    @Published var alertQuakeMag: Double { didSet { ud.set(alertQuakeMag, forKey: "alertEqMag") } }
    @Published var cacheBytes: Int64 = FeedCache.size()

    let location = LocationService()
    let voice = VoiceController()
    let ais = AISClient()
    private let ud = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var satTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var lastContactFetchCenter: CLLocationCoordinate2D?
    private var lastDisplaySample: (center: CLLocationCoordinate2D, distance: Double)?
    private var simulationAnchor: CLLocationCoordinate2D?
    private var lastSimulationAnchorAt = Date.distantPast
    private var geocoder = CLGeocoder()
    private var geocodeTask: Task<Void, Never>?
    private var pendingDeepLink: URL?

    init() {
        let ud = UserDefaults.standard
        let now = Date()
        windowStart = now.addingTimeInterval(-24 * 3600)
        windowEnd = now.addingTimeInterval(72 * 3600)
        let saved = (ud.array(forKey: "layers") as? [String])?.compactMap(Layer.init(rawValue:))
        layers = saved.map(Set.init) ?? [.flights, .quakes, .satellites, .launches]
        mapStyleRaw = ud.string(forKey: "mapStyle") ?? "imagery"
        accentRaw = ud.string(forKey: "accent") ?? "green"
        performanceMode = ud.object(forKey: "perf") as? Bool ?? true
        offlineMode = ud.bool(forKey: "offline")
        showLabels = ud.object(forKey: "labels") as? Bool ?? true
        aisKey = ud.string(forKey: "aisKey") ?? ""
        firmsKey = ud.string(forKey: "firmsKey") ?? ""
        ionToken = ud.string(forKey: "ionToken") ?? ""
        ionAssets = ud.string(forKey: "ionAssets") ?? ""
        googleMapsKey = ud.string(forKey: "googleMapsKey") ?? ""
        basemap = Basemap(rawValue: ud.string(forKey: "basemap") ?? "") ?? ((ud.string(forKey: "ionToken") ?? "").isEmpty && (ud.string(forKey: "googleMapsKey") ?? "").isEmpty && CesiumConfig.defaultIonToken.isEmpty && CesiumConfig.defaultGoogleKey.isEmpty ? .esriImagery : .google3D)
        sceneTerrain = ud.object(forKey: "sceneTerrain") as? Bool ?? true
        sceneBuildings = ud.object(forKey: "sceneBuildings") as? Bool ?? false
        sceneEntities = ud.object(forKey: "sceneEntities") as? Bool ?? true
        sceneLines = ud.object(forKey: "sceneLines") as? Bool ?? true
        tilesCatalogURL = ud.string(forKey: "tilesCatalogURL") ?? "https://mrzefv.github.io/godseye-tiles/catalog.json"
        customTileURL = ud.string(forKey: "customTileURL") ?? ""
        customTilesets = ud.string(forKey: "customTilesets") ?? ""
        enabledTilesets = Set(ud.stringArray(forKey: "enabledTilesets") ?? [])
        sceneRealism = ud.string(forKey: "sceneRealism") ?? "day"
        anthropicKey = ud.string(forKey: "anthropicKey") ?? ""
        aiModel = ud.string(forKey: "aiModel") ?? "claude-sonnet-5"
        alertMilitary = ud.bool(forKey: "alertMil")
        alertQuakes = ud.bool(forKey: "alertEq")
        alertISS = ud.bool(forKey: "alertIss")
        alertQuakeMag = ud.object(forKey: "alertEqMag") as? Double ?? 5.0
        wakes = ud.object(forKey: "wakes") as? Bool ?? true
        radarOpacity = ud.object(forKey: "radarOpacity") as? Double ?? 0.75
        viewsheds = ud.bool(forKey: "viewsheds")
        sensor = SensorMode(rawValue: ud.string(forKey: "sensor") ?? "") ?? .normal
        hud = ud.bool(forKey: "hud")
        detection = ud.bool(forKey: "detection")
        if let d = ud.data(forKey: "bookmarks"), let b = try? JSONDecoder().decode([Bookmark].self, from: d) { bookmarks = b }
        Feeds.shared.offline = offlineMode
        voice.onCommand = { [weak self] text in self?.handleVoice(text) }
        ais.onShip = { [weak self] ship in self?.ingest(ship) }
        ais.onStatus = { [weak self] st in self?.aisStatus = st }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        cctv.cameraLookup = { [weak self] id in self?.cameras.first { $0.id == id } }
        Task { [weak self] in guard let self else { return }; await RemoteKeys.apply(to: self) }
    }

    func neighborCamera(of cam: Camera, forward: Bool) -> Camera? {
        let near = cameras.filter { $0.id != cam.id && $0.available && $0.coord.distance(to: cam.coord) < 25_000 }
            .sorted { $0.coord.distance(to: cam.coord) < $1.coord.distance(to: cam.coord) }
        guard !near.isEmpty else { return nil }
        // Ring order by bearing so prev/next sweep around the current camera
        let ring = near.prefix(12).sorted { Geo.bearing(from: cam.coord, to: $0.coord) < Geo.bearing(from: cam.coord, to: $1.coord) }
        return forward ? ring.first : ring.last
    }

    func openLive(_ cam: Camera) {
        selected = nil
        Task { try? await Task.sleep(nanoseconds: 350_000_000); self.liveCamera = cam }
    }

    // MARK: Place records (public API lookups for tapped / picked places)

    func lookupIntel(for e: Entity, force: Bool = false) {
        guard e.kind == .place else { return }
        if !force, let cached = intel[e.id], Date().timeIntervalSince(cached.fetchedAt) < 1800 {
            if !cached.polygons.isEmpty { propertyLines = cached.polygons }
            return
        }
        guard !intelLoading.contains(e.id) else { return }
        intelLoading.insert(e.id)
        let coord = e.coord
        let id = e.id
        Task {
            let result = await Feeds.shared.placeIntel(at: coord)
            intel[id] = result
            intelLoading.remove(id)
            if !result.polygons.isEmpty { propertyLines = result.polygons }
            if let svc = result.parcelService { show("Property lines · \(svc)") }
            if intel.count > 40 {
                let oldest = intel.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.prefix(intel.count - 40).map(\.key)
                for k in oldest { intel[k] = nil }
            }
        }
    }

    // MARK: Derived

    var accent: Color {
        switch accentRaw {
        case "amber": return Color(red: 1.0, green: 0.68, blue: 0.1)
        case "cyan": return .cyan
        case "white": return .white
        default: return Color(red: 0.35, green: 1.0, blue: 0.45)
        }
    }

    var accentHex: String {
        switch accentRaw {
        case "amber": return "#ffad1a"
        case "cyan": return "#32d4ff"
        case "white": return "#ffffff"
        default: return "#59ff73"
        }
    }

    var mapStyle: MapStyle {
        let elev: MapStyle.Elevation = performanceMode ? .flat : .realistic
        let traffic = layers.contains(.traffic)
        switch mapStyleRaw {
        case "hybrid": return .hybrid(elevation: elev, pointsOfInterest: .excludingAll, showsTraffic: traffic)
        case "standard": return .standard(elevation: elev, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: traffic)
        default:
            if traffic { return .hybrid(elevation: elev, pointsOfInterest: .excludingAll, showsTraffic: true) }
            return .imagery(elevation: elev)
        }
    }

    var pollInterval: UInt64 { performanceMode ? 30 : 20 }
    var isLive: Bool { timeCursor == nil }
    var effectiveTime: Date { timeCursor ?? Date() }
    var isTracking: Bool { trackedID != nil }

    private var densityScale: Double {
        let widthScale = min(1.18, max(0.85, viewWidth / 390))
        let scenePenalty = show3D ? 0.82 : 1.0
        let visualPenalty = performanceMode ? 1.0 : 0.9
        let trackingBoost = isTracking ? 1.08 : 1.0
        return widthScale * scenePenalty * visualPenalty * trackingBoost
    }

    private func scaledCap(base: Int, min minCap: Int) -> Int {
        max(minCap, Int((Double(base) * densityScale).rounded()))
    }

    var contactCap: Int {
        let d = distance
        if d > 7_000_000 { return isTracking ? 40 : 0 }
        if d > 2_500_000 { return scaledCap(base: 80, min: 50) }
        if d > 800_000 { return scaledCap(base: 170, min: 110) }
        return scaledCap(base: 280, min: 180)
    }

    func rebuildDisplay() {
        var out: [String: Contact] = [:]
        let cap = contactCap
        if cap > 0 {
            if layers.contains(.flights) { for c in contacts where !c.military { out[c.id] = c } }
            if layers.contains(.military) {
                for c in contacts where c.military { out[c.id] = c }
                for c in militaryContacts { out[c.id] = c }
            }
        }
        let cen = center
        var ranked: [Contact]
        if out.count > cap {
            ranked = Array(out.values.map { ($0, $0.coord.distance(to: cen)) }
                .sorted { $0.1 < $1.1 }
                .prefix(cap)
                .map(\.0))
        } else {
            ranked = out.values.sorted { $0.id < $1.id }
        }
        if let tid = trackedID, tid.hasPrefix("ac-"), !ranked.contains(where: { "ac-\($0.id)" == tid }),
           let t = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == tid }) { ranked.append(t) }
        if ranked != visibleContacts { visibleContacts = ranked }

        var q: [Quake] = []
        if layers.contains(.quakes) {
            q = timeCursor.map { t in quakes.filter { $0.time <= t } } ?? quakes
            if distance > 7_000_000 { q = q.filter { $0.mag >= 2.5 } }
        }
        if q != visibleQuakes { visibleQuakes = q }

        var sh: [Ship] = []
        if layers.contains(.ships), distance < 5_000_000 {
            let cutoff = Date().addingTimeInterval(-20 * 60)
            let shipCap = scaledCap(base: distance < 800_000 ? 220 : 150, min: 90)
            sh = Array(ships.values.filter { $0.seenAt > cutoff }
                .map { ($0, $0.coord.distance(to: cen)) }
                .sorted { $0.1 < $1.1 }
                .prefix(shipCap)
                .map(\.0))
        }
        if sh != visibleShips { visibleShips = sh }

        var cams: [Camera] = []
        if layers.contains(.cctv), distance < 400_000 {
            let camCap = scaledCap(base: distance < 15_000 ? 280 : 110, min: distance < 15_000 ? 140 : 70)
            cams = Array(cameras.filter { $0.available }
                .map { ($0, $0.coord.distance(to: cen)) }
                .filter { $0.1 < 60_000 }
                .sorted { $0.1 < $1.1 }
                .prefix(camCap)
                .map(\.0))
        }
        if cams != visibleCameras { visibleCameras = cams }

        var fr: [Fire] = []
        if layers.contains(.fires) {
            let cap = distance > 3_000_000 ? scaledCap(base: 260, min: 140) : scaledCap(base: 520, min: 260)
            fr = Array(fires.prefix(cap))
        }
        if fr != visibleFires { visibleFires = fr }

        var bk: [BikeStation] = []
        if layers.contains(.bikeshare), distance < 60_000 {
            bk = Array(bikes.map { ($0, $0.coord.distance(to: cen)) }.sorted { $0.1 < $1.1 }.prefix(scaledCap(base: 220, min: 120)).map(\.0))
        }
        if bk != visibleBikes { visibleBikes = bk }

        var rd: [RadioStation] = []
        if layers.contains(.radio) {
            rd = distance > 6_000_000 ? Array(radioStations.prefix(scaledCap(base: 260, min: 140)))
               : Array(radioStations.map { ($0, $0.coord.distance(to: cen)) }.sorted { $0.1 < $1.1 }.prefix(scaledCap(base: 180, min: 100)).map(\.0))
        }
        if rd != visibleRadio { visibleRadio = rd }

        var cb: [Cable] = []
        if layers.contains(.cables), distance < 9_000_000 {
            let s = min(80.0, max(1.0, distance / 111_000))
            cb = cables.filter { $0.maxLat >= cen.latitude - s && $0.minLat <= cen.latitude + s && $0.maxLon >= cen.longitude - s * 1.5 && $0.minLon <= cen.longitude + s * 1.5 }
            cb = Array(cb.prefix(scaledCap(base: 90, min: 45)))
        }
        if cb != visibleCables { visibleCables = cb }

        var ap: [Airport] = []
        if layers.contains(.airports) {
            ap = distance > 4_000_000 ? airports.filter { $0.type == "large_airport" }
               : Array(airports.map { ($0, $0.coord.distance(to: cen)) }.filter { $0.1 < distance * 2.5 }.sorted { $0.1 < $1.1 }.prefix(scaledCap(base: 180, min: 90)).map(\.0))
        }
        if ap != visibleAirports { visibleAirports = ap }

        var ws: [WxStation] = []
        if layers.contains(.stations), distance < 5_000_000 {
            ws = Array(stations.map { ($0, $0.coord.distance(to: cen)) }.sorted { $0.1 < $1.1 }.prefix(scaledCap(base: 180, min: 90)).map(\.0))
        }
        if ws != visibleStations { visibleStations = ws }

        var hz: [HazardAlert] = []
        if layers.contains(.alerts) {
            hz = distance > 6_000_000 ? hazards.filter { $0.severity == "Extreme" || $0.severity == "Severe" }
               : Array(hazards.map { ($0, $0.coord.distance(to: cen)) }.sorted { $0.1 < $1.1 }.prefix(120).map(\.0))
        }
        if hz != visibleHazards { visibleHazards = hz }

        var tr: [Train] = []
        if layers.contains(.trains) {
            tr = distance > 6_000_000 ? Array(trains.prefix(scaledCap(base: 220, min: 120))) : Array(trains.map { ($0, $0.coord.distance(to: cen)) }.sorted { $0.1 < $1.1 }.prefix(scaledCap(base: 220, min: 120)).map(\.0))
        }
        if tr != visibleTrains { visibleTrains = tr }
        lastDisplaySample = (center, distance)
    }

    func rebuildRadar() {
        guard layers.contains(.radar) || layers.contains(.satir) else { return }
        radar.rebuild(center: center, distance: distance, viewWidth: viewWidth, radar: layers.contains(.radar), sat: layers.contains(.satir))
        if let t = timeCursor, !radar.radarFrames.isEmpty {
            let i = radar.radarFrames.enumerated().min { abs($0.element.time.timeIntervalSince(t)) < abs($1.element.time.timeIntervalSince(t)) }?.offset ?? radar.latestIndex
            if i != radar.index { radar.index = i }
        }
    }

    func refreshWind() async {
        guard layers.contains(.wind) else { return }
        let span = max(0.5, min(12.0, distance / 160_000))
        do { winds = try await Feeds.shared.windGrid(center: center, spanDeg: span) } catch { feedErrors += 1 }
    }
    func refreshPower() async {
        guard layers.contains(.power), distance < 250_000 else { powerLines = []; powerNodes = []; return }
        do { (powerLines, powerNodes) = try await Feeds.shared.powerGrid(center: center, spanDeg: max(0.15, distance / 111_000)) } catch { feedErrors += 1 }
    }
    func refreshRail() async {
        guard layers.contains(.rail), distance < 150_000 else { railLines = []; railStations = []; return }
        do { (railLines, railStations) = try await Feeds.shared.rail(center: center, spanDeg: max(0.1, distance / 111_000)) } catch { feedErrors += 1 }
    }
    func refreshTrains() async {
        guard layers.contains(.trains) else { return }
        trains = await Feeds.shared.trains()
        rebuildDisplay()
        if let tid = trackedID, tid.hasPrefix("train-"), let t = trains.first(where: { "train-\($0.id)" == tid }) {
            trackedCoord = t.coord; trackedHeading = t.heading; trackedEntity = Entity.from(t)
            trail.append(t.coord); if trail.count > 240 { trail.removeFirst(trail.count - 240) }
            followCamera(animated: true)
            LiveActivityManager.shared.update(Entity.from(t), coord: t.coord)
        }
    }
    func refreshAirports() async {
        do { airports = try await Feeds.shared.airports(); rebuildDisplay() } catch { feedErrors += 1 }
    }
    func refreshStations() async {
        guard layers.contains(.stations) else { return }
        let mm = (try? await Feeds.shared.metars(center: center, spanDeg: max(1.0, distance / 111_000))) ?? []
        let bb = (try? await Feeds.shared.buoys()) ?? []
        stations = mm + bb
        rebuildDisplay()
    }
    func refreshHazards() async {
        let nn = (try? await Feeds.shared.nwsAlerts()) ?? []
        let cc = (try? await Feeds.shared.calFire()) ?? []
        hazards = nn + cc
        rebuildDisplay()
        if alertQuakes {   // reuse the alerts permission; extreme hazards near me
            if let me = location.coordinate {
                for h in hazards where (h.severity == "Extreme") && h.coord.distance(to: me) < 150_000 {
                    Alerts.shared.fire(id: "haz-\(h.id)", title: h.event, body: h.headline)
                }
            }
        }
    }
    func refreshSpace() async {
        space = await Feeds.shared.spaceWeather()
        auroraPoints = space.aurora.enumerated().map { AuroraPoint(id: $0.offset, lat: $0.element.lat, lon: $0.element.lon, prob: $0.element.prob) }
        night = Solar.nightPolygon(Date())
    }
    func refreshScanners() async {
        do {
            var list = try await Feeds.shared.scannerFeeds()
            // resolve locations from titles (cached in UserDefaults)
            var geo = (ud.dictionary(forKey: "scannerGeo") as? [String: [Double]]) ?? [:]
            for i in list.indices {
                if let g = geo[list[i].id], g.count == 2 { list[i].lat = g[0]; list[i].lon = g[1]; continue }
                let q = list[i].title.replacingOccurrences(of: "(?i)(police|fire|ems|sheriff|dispatch|county|city|and|&|department|dept|public safety|scanner)", with: " ", options: .regularExpression)
                if let c = await geocode(q.trimmingCharacters(in: .whitespaces)) { list[i].lat = c.latitude; list[i].lon = c.longitude; geo[list[i].id] = [c.latitude, c.longitude] }
                if i > 40 { break }
            }
            ud.set(geo, forKey: "scannerGeo")
            scanners = list.filter { $0.lat != 0 || $0.lon != 0 }
        } catch { feedErrors += 1 }
    }
    func refreshPeaks() async {
        guard layers.contains(.peaks), distance < 300_000 else { peaks = []; return }
        do { peaks = try await Feeds.shared.peaks(center: center, spanDeg: max(0.1, distance / 111_000)) } catch { feedErrors += 1 }
    }

    @discardableResult
    private func updateSimulationAnchor(force: Bool = false, thresholdScale: Double = 0.65) -> Bool {
        guard layers.contains(.simulation) else { return false }
        let threshold = max(distance * thresholdScale, 80_000.0 * min(1.0, thresholdScale / 0.65))
        if force || simulationAnchor == nil || simulationAnchor!.distance(to: center) > threshold {
            simulationAnchor = distance > 1_500_000 ? center : center.moved(meters: min(max(distance * 0.08, 1_800), 10_000), bearing: 38)
            lastSimulationAnchorAt = Date()
            return true
        }
        return false
    }

    private func startSimulation() {
        updateSimulationAnchor(force: simulationAnchor == nil)
        guard simulationTask == nil else { return }
        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.simulationTick &+= 1
                    if Date().timeIntervalSince(self.lastSimulationAnchorAt) > 12 {
                        if self.updateSimulationAnchor() {
                            self.simulationRevision &+= 1
                            self.refreshSelectedSimulation()
                        }
                    }
                }
            }
        }
    }

    private func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        if trackedID?.hasPrefix("sim-") == true || trackedEntity?.kind == .simulation { stopTracking(silent: true) }
        if selected?.kind == .simulation { selected = nil }
        simulationAnchor = nil
        simulationTick = 0
        simulationRevision &+= 1
    }

    private func refreshSelectedSimulation() {
        guard let id = selected?.id, id.hasPrefix("sim-") else { return }
        if let sim = simulationContacts.first(where: { "sim-\($0.id)" == id }) {
            selected = Entity.from(sim)
        }
    }

    func listen(_ f: ScannerFeed) {
        scannerNow = f
        scannerPlayer.play(RadioStation(stationuuid: f.id, name: f.title, url_resolved: f.streamURL, country: f.genre, geo_lat: f.lat, geo_long: f.lon, tags: nil, codec: "mp3", clickcount: f.listeners))
        show("Listening: \(f.title)")
    }
    func stopScanner() { scannerPlayer.stop(); scannerNow = nil }

    func trackStorm(at c: CLLocationCoordinate2D) {
        Task {
            show("Analyzing radar…")
            if let cell = await radar.trackStorm(near: c, center: center, distance: distance, viewWidth: viewWidth) {
                storms.removeAll { $0.id == cell.id }
                storms.append(cell)
                track(Entity.from(cell))
            } else { show("No storm cell near that point") }
        }
    }

    func loadProfile() {
        guard let a = measureA, let b = measureB else { show("Measure two points first"); return }
        profileLoading = true
        showProfile = true
        Task {
            let pts = Geo.greatCircle(a, b, points: 80)
            if let e = try? await Feeds.shared.elevations(pts) {
                let total = a.distance(to: b) / 1000
                profile = e.enumerated().map { (dist: total * Double($0.offset) / Double(max(1, e.count - 1)), elev: $0.element) }
            } else { show("Elevation service unavailable") }
            profileLoading = false
        }
    }

    func elevation(at c: CLLocationCoordinate2D) async -> Double? {
        (try? await Feeds.shared.elevations([c]))?.first
    }

    var visibleLaunches: [Launch] { layers.contains(.launches) ? launches : [] }
    var visibleSatellites: [Satellite] {
        guard layers.contains(.satellites) else { return [] }
        let cap = scaledCap(base: distance > 3_000_000 ? 160 : 240, min: 70)
        let ranked = distance > 3_000_000
            ? Array(satellites.prefix(cap))
            : Array(satellites.map { ($0, $0.coord.distance(to: center)) }.sorted { $0.1 < $1.1 }.prefix(cap).map(\.0))
        if let tid = trackedID, tid.hasPrefix("sat-"), let tracked = satellites.first(where: { "sat-\($0.id)" == tid }), !ranked.contains(where: { $0.id == tracked.id }) {
            return ranked + [tracked]
        }
        return ranked
    }

    private func simulationOrbit(around c: CLLocationCoordinate2D, radius: Double, bearing: Double, step: Double = 12) -> (coord: CLLocationCoordinate2D, heading: Double) {
        let coord = c.moved(meters: radius, bearing: bearing)
        let next = c.moved(meters: radius, bearing: bearing + step)
        return (coord, Geo.bearing(from: coord, to: next))
    }

    private func circleRing(center: CLLocationCoordinate2D, radius: Double, points: Int = 36) -> [CLLocationCoordinate2D] {
        (0...points).map { i in center.moved(meters: radius, bearing: Double(i) * 360 / Double(points)) }
    }

    var simulationContacts: [SimulationContact] {
        guard layers.contains(.simulation), let anchor = simulationAnchor else { return [] }
        let phase = simulationTick
        let orbit = min(max(distance * 0.07, 1_800), 12_000)
        let cropCenter = anchor.moved(meters: orbit * 0.52, bearing: 210)
        let cropBearing = Double(phase) * 32
        let cropUFO = simulationOrbit(around: cropCenter, radius: orbit * 0.34, bearing: cropBearing)
        let dejaBearing = 30 + sin(Double(phase) * 0.55) * 130
        let deja = simulationOrbit(around: anchor, radius: orbit * 0.82, bearing: dejaBearing)
        let beamBase = anchor.moved(meters: orbit * 0.3, bearing: 320 + cos(Double(phase) * 0.45) * 24)
        let beamBearing = 80 + Double(phase) * 22
        let beam = simulationOrbit(around: beamBase, radius: orbit * 0.22, bearing: beamBearing)
        return [
            SimulationContact(id: "crop-run", kind: .ufo, title: "UFO CROP RUN", subtitle: "fictional · tracing circles", summary: "Looping low over the field and redrawing the crop-circle pattern.", lat: cropUFO.coord.latitude, lon: cropUFO.coord.longitude, altM: max(280, orbit * 0.24), heading: cropUFO.heading, phase: phase),
            SimulationContact(id: "deja-vu", kind: .dejaVu, title: "DÉJÀ VU LOOP", subtitle: "fictional · repeating path", summary: "A repeating route that intentionally doubles back to create a déjà vu effect.", lat: deja.coord.latitude, lon: deja.coord.longitude, altM: max(420, orbit * 0.3), heading: deja.heading, phase: phase % 12),
            SimulationContact(id: "abduction", kind: .abduction, title: "ABDUCTION FLYOVER", subtitle: "fictional · beam sweep", summary: "A scripted flyover with a moving beam marker near the surface.", lat: beam.coord.latitude, lon: beam.coord.longitude, altM: max(550, orbit * 0.4), heading: beam.heading, phase: phase % 10),
            SimulationContact(id: "crop-circle", kind: .cropCircle, title: "CROP CIRCLE", subtitle: "fictional · ground imprint", summary: "A static ground marker that the nearby UFO orbit keeps revisiting.", lat: cropCenter.latitude, lon: cropCenter.longitude, altM: 0, heading: 0, phase: phase % 6)
        ]
    }

    var simulationOverlays: [SimulationOverlay] {
        guard layers.contains(.simulation), let anchor = simulationAnchor else { return [] }
        let orbit = min(max(distance * 0.07, 1_800), 12_000)
        let cropCenter = anchor.moved(meters: orbit * 0.52, bearing: 210)
        let beamBase = anchor.moved(meters: orbit * 0.3, bearing: 320 + cos(Double(simulationTick) * 0.45) * 24)
        let corridor = Geo.cone(at: beamBase, heading: 35 + sin(Double(simulationTick) * 0.3) * 18, fov: 26, range: orbit * 0.42)
        return [
            SimulationOverlay(id: "crop-rings", kind: .cropCircle, title: "Crop circles", rings: [
                circleRing(center: cropCenter, radius: orbit * 0.12),
                circleRing(center: cropCenter, radius: orbit * 0.22),
                circleRing(center: cropCenter, radius: orbit * 0.34)
            ], focus: cropCenter),
            SimulationOverlay(id: "beam-corridor", kind: .abduction, title: "Beam corridor", rings: [corridor], focus: beamBase)
        ]
    }

    var timelineEvents: [Entity] {
        var e: [Entity] = quakes.filter { $0.mag >= 4.5 }.map { Entity.from($0) }
        e += launches.map { Entity.from($0) }
        e += hazards.filter { $0.source == "NWS" && $0.starts != nil && ($0.severity == "Extreme" || $0.severity == "Severe") }.prefix(40).map { Entity.from($0) }
        return e.filter { ($0.time ?? .distantPast) >= windowStart && ($0.time ?? .distantFuture) <= windowEnd }
                .sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
    }

    var cursorFraction: Double {
        let t = effectiveTime.timeIntervalSince(windowStart) / windowEnd.timeIntervalSince(windowStart)
        return min(max(t, 0), 1)
    }

    func fraction(of date: Date) -> Double {
        min(max(date.timeIntervalSince(windowStart) / windowEnd.timeIntervalSince(windowStart), 0), 1)
    }

    /// Everything trackable currently on the globe, nearest-first from map center.
    func roster(kind: String? = nil, limit: Int = 60) -> [Entity] {
        var all: [Entity] = []
        if kind == nil || kind == "aircraft" || kind == "military" {
            all += (contacts + militaryContacts).filter { kind != "military" || $0.military }.map { Entity.from($0) }
        }
        if kind == nil || kind == "ship" { all += visibleShips.map { Entity.from($0) } }
        if kind == nil || kind == "satellite" { all += visibleSatellites.map { Entity.from($0) } }
        if kind == nil || kind == "train" { all += visibleTrains.map { Entity.from($0) } }
        let c = center
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
            .map { ($0, $0.coord.distance(to: c)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit).map(\.0)
    }

    // MARK: Boot

    func boot() async {
        guard !ready else { return }
        status = "Loading globe assets…"
        try? await Task.sleep(nanoseconds: 400_000_000)
        status = "Fetching seismic feed…"
        await refreshQuakes()
        status = "Acquiring orbital elements…"
        await refreshISS()
        if layers.contains(.satellites) { await refreshSatellites() }
        status = "Loading launch manifest…"
        await refreshLaunches()
        status = "Listening for transponders…"
        await refreshContacts(force: true)
        if layers.contains(.military) { await refreshMilitary() }
        if layers.contains(.cctv) { await refreshCameras() }
        rebuildDisplay()
        status = "Online"
        location.request()
        ready = true
        startPolling()
        startSatelliteTicker()
        if layers.contains(.ships) { connectAIS() }
        if layers.contains(.radio) { await refreshRadio() }
        if layers.contains(.cables) { await refreshCables() }
        registerBackgroundTasks()
        cctv.start()
        if layers.contains(.airports) { await refreshAirports() }
        if layers.contains(.alerts) { await refreshHazards() }
        if layers.contains(.space) { await refreshSpace() }
        if layers.contains(.radar) || layers.contains(.satir) { await radar.load(); rebuildRadar() }
        if !cctv.watching.isEmpty && cameras.isEmpty { await refreshCameras() }
        if layers.contains(.simulation) { startSimulation() }
        if let u = pendingDeepLink { pendingDeepLink = nil; open(url: u) }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.pollInterval ?? 15) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                tick += 1
                await self.refreshContacts(force: self.isTracking)
                if self.layers.contains(.satellites) || self.iss != nil { await self.refreshISS() }
                if tick % 4 == 0, self.layers.contains(.military) { await self.refreshMilitary() }
                if tick % 20 == 0 { await self.refreshQuakes() }
                if tick % 120 == 0 { await self.refreshLaunches(); await self.refreshSatellites() }
                if tick % 6 == 0 { self.rebuildDisplay() }
                if tick % 8 == 0, self.layers.contains(.bikeshare) { await self.refreshBikes() }
                if tick % 40 == 0, self.layers.contains(.fires) { await self.refreshFires() }
                if tick % 2 == 0, self.layers.contains(.trains) { await self.refreshTrains() }
                if tick % 20 == 0, self.layers.contains(.stations) { await self.refreshStations() }
                if tick % 20 == 0, self.layers.contains(.alerts) { await self.refreshHazards() }
                if tick % 40 == 0, self.layers.contains(.space) { await self.refreshSpace() }
                if tick % 40 == 0, self.layers.contains(.wind) { await self.refreshWind() }
                if tick % 20 == 0, self.layers.contains(.radar) || self.layers.contains(.satir) { await self.radar.load(); self.rebuildRadar() }
                if tick % 4 == 0, self.layers.contains(.space) { self.night = Solar.nightPolygon(Date()) }
                self.checkAlerts()
                self.cacheBytes = FeedCache.size()
            }
        }
    }

    private func startSatelliteTicker() {
        satTask?.cancel()
        satTask = Task { [weak self] in
            while !Task.isCancelled {
                let secs: UInt64 = (self?.performanceMode ?? true) ? 5 : 4
                try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.layers.contains(.satellites) { self.propagate() }
            }
        }
    }

    private func propagate() {
        guard !propagators.isEmpty else { return }
        let now = Date()
        var out: [Satellite] = []
        out.reserveCapacity(propagators.count)
        for p in propagators {
            guard let g = p.geodetic(at: now) else { continue }
            out.append(Satellite(id: String(p.noradID), name: p.name, cls: Satellite.classify(p.name),
                                 lat: g.lat, lon: g.lon, altKm: g.altKm, speedKmh: g.speedKmh, periodMin: p.periodMinutes))
        }
        satellites = out
        if let tid = trackedID, tid.hasPrefix("sat-"), let sat = out.first(where: { "sat-\($0.id)" == tid }) {
            trackedCoord = sat.coord
            trackedEntity = Entity.from(sat)
            trail.append(sat.coord)
            if trail.count > 120 { trail.removeFirst(trail.count - 120) }
            if let p = propagators.first(where: { String($0.noradID) == sat.id }) {
                satTrack = p.groundTrack(from: now, minutes: min(p.periodMinutes, 95), step: 1)
            }
            followCamera(animated: true)
        }
    }

    // MARK: Refresh

    func refreshContacts(force: Bool) async {
        guard layers.contains(.flights) || layers.contains(.military) else { return }
        let followTarget = isTracking && (trackedEntity?.kind == .aircraft || trackedEntity?.kind == .military)
        let c = followTarget ? (trackedCoord ?? center) : center
        if !force, let last = lastContactFetchCenter, let lu = lastUpdate,
           last.distance(to: c) < 150_000, Date().timeIntervalSince(lu) < Double(pollInterval) - 1 { return }
        do {
            let list = try await Feeds.shared.contacts(lat: c.latitude, lon: c.longitude)
            contacts = list
            lastContactFetchCenter = c
            lastUpdate = Date()
        } catch { feedErrors += 1 }
    }

    func refreshMilitary() async {
        do { militaryContacts = try await Feeds.shared.military() } catch { feedErrors += 1 }
    }

    func refreshQuakes() async {
        do { quakes = try await Feeds.shared.quakes(days: quakeWindowDays) } catch { feedErrors += 1 }
    }

    /// Aftershock clustering: quakes within 100 km and 7 days after a M≥5 mainshock.
    var quakeClusters: [(main: Quake, count: Int)] {
        let mains = quakes.filter { $0.mag >= 5 }
        return mains.map { m in (m, quakes.filter { $0.id != m.id && $0.time > m.time && $0.time < m.time.addingTimeInterval(7 * 86400) && $0.coord.distance(to: m.coord) < 100_000 }.count) }
            .filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }
    }

    func refreshISS() async {
        do { iss = try await Feeds.shared.iss() } catch { feedErrors += 1 }
    }

    func refreshLaunches() async {
        do { launches = try await Feeds.shared.launches() } catch { feedErrors += 1 }
    }

    func refreshSatellites() async {
        do {
            propagators = try await Feeds.shared.satellites()
            propagate()
        } catch { feedErrors += 1 }
    }

    func refreshCameras() async {
        do { cameras = try await Feeds.shared.cameras(); rebuildDisplay() } catch { feedErrors += 1 }
    }

    func refreshFires() async {
        guard layers.contains(.fires), !firmsKey.isEmpty else { return }
        let span = max(3.0, min(25.0, distance / 120_000))
        do { fires = try await Feeds.shared.fires(key: firmsKey, center: center, spanDeg: span); checkAlerts() } catch { feedErrors += 1 }
    }

    func refreshBikes() async {
        guard layers.contains(.bikeshare), distance < 200_000 else { return }
        do { bikes = try await Feeds.shared.bikeshare(near: center); rebuildDisplay() } catch { feedErrors += 1 }
    }

    func refreshRadio() async {
        do { radioStations = try await Feeds.shared.radio(); rebuildDisplay() } catch { feedErrors += 1 }
    }

    func refreshInfra() async {
        guard layers.contains(.infra), distance < 400_000 else { return }
        do { infra = try await Feeds.shared.infrastructure(center: center, spanDeg: max(0.3, distance / 111_000)) } catch { feedErrors += 1 }
    }

    func refreshAirport() async {
        guard layers.contains(.airport), distance < 12_000 else { airportFeatures = []; return }
        do { airportFeatures = try await Feeds.shared.airport(center: center) } catch { feedErrors += 1 }
    }

    func refreshResidential() async {
        guard layers.contains(.residential), distance < 6_000 else { residential = []; return }
        do { residential = try await Feeds.shared.residentialBlueprints(center: center, spanDeg: max(0.006, distance / 111_000 * 0.6)) } catch { feedErrors += 1 }
    }

    func refreshCables() async {
        do { cables = try await Feeds.shared.cables(); rebuildDisplay() } catch { feedErrors += 1 }
    }

    func refreshAll() async {
        if layers.contains(.fires) { await refreshFires() }
        if layers.contains(.bikeshare) { await refreshBikes() }
        if layers.contains(.infra) { await refreshInfra() }
        if layers.contains(.residential) { await refreshResidential() }
        if layers.contains(.airport) { await refreshAirport() }
        await refreshContacts(force: true)
        await refreshQuakes()
        await refreshISS()
        await refreshLaunches()
        if layers.contains(.military) { await refreshMilitary() }
        if layers.contains(.satellites) { await refreshSatellites() }
        if layers.contains(.cctv) { await refreshCameras() }
        if layers.contains(.ships) { connectAIS() }
        cacheBytes = FeedCache.size()
        show("Feeds refreshed")
    }

    // MARK: AIS

    func connectAIS() {
        guard layers.contains(.ships) else { return }
        let span = max(2.0, min(20.0, distance / 150_000))
        ais.connect(apiKey: aisKey, center: center, spanDeg: span)
    }

    private func ingest(_ ship: Ship) {
        var v = ship
        if v.name.isEmpty, let old = ships[ship.id] { v.name = old.name }
        ships[ship.id] = v
        if let tid = trackedID, tid == "sh-\(ship.id)" {
            trackedCoord = v.coord
            trackedHeading = v.cog
            trackedEntity = Entity.from(v)
            trail.append(v.coord)
            if trail.count > 200 { trail.removeFirst(trail.count - 200) }
            followCamera(animated: true)
        }
        if ships.count > 3000 {
            let cutoff = Date().addingTimeInterval(-15 * 60)
            ships = ships.filter { $0.value.seenAt > cutoff }
        }
    }

    // MARK: Camera

    func cameraChanged(_ ctx: MapCameraUpdateContext) {
        let prevCap = contactCap
        center = ctx.camera.centerCoordinate
        distance = ctx.camera.distance
        heading = ctx.camera.heading
        pitch = ctx.camera.pitch
        let userMoved = Date() > programmaticMoveUntil
        if userMoved && directing { stopDirector() }
        if userMoved, isTracking, let tc = trackedCoord, center.distance(to: tc) > max(distance * 0.6, 20_000) {
            stopTracking(silent: true)
        }
        if shouldRebuildDisplayOnCameraChange(prevCap: prevCap) { rebuildDisplay() }
        if let last = lastContactFetchCenter, last.distance(to: center) > 200_000, !isTracking {
            Task { await refreshContacts(force: true) }
        }
        if layers.contains(.ships), ais.needsResubscribe(for: center) { connectAIS() }
        if userMoved && orbiting { stopOrbit() }
        if userMoved && scenePlaying { stopScene() }
        if layers.contains(.simulation), updateSimulationAnchor(thresholdScale: 0.18) {
            simulationRevision &+= 1
            refreshSelectedSimulation()
        }
        let moved = lastRegionFetch.map { $0.center.distance(to: center) > max(distance * 0.5, 5_000) || Date().timeIntervalSince($0.at) > 120 } ?? true
        if moved {
            lastRegionFetch = (center, Date())
            Task {
                if layers.contains(.bikeshare) { await refreshBikes() }
                if layers.contains(.infra) { await refreshInfra() }
                if layers.contains(.airport) { await refreshAirport() }
                if layers.contains(.residential) { await refreshResidential() }
                if layers.contains(.fires), fires.isEmpty || distance < 500_000 { await refreshFires() }
                if layers.contains(.wind) { await refreshWind() }
                if layers.contains(.power) { await refreshPower() }
                if layers.contains(.rail) { await refreshRail() }
                if layers.contains(.stations) { await refreshStations() }
                if layers.contains(.peaks) { await refreshPeaks() }
            }
        }
        rebuildRadar()
        scheduleAISummary()
        geocodeTask?.cancel()
        if distance > 3_000_000 { centerName = "GLOBAL VIEW"; return }
        let c = center
        geocodeTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let name = await reverseGeocode(c)
            guard !Task.isCancelled else { return }
            centerName = name.title.uppercased()
        }
    }

    private func shouldRebuildDisplayOnCameraChange(prevCap: Int) -> Bool {
        if contactCap != prevCap { return true }
        let contactLayers = layers.contains(.flights) || layers.contains(.military)
        let contactViewport = contactLayers && contactCap > 0
        let viewportLayers = !layers.intersection(Set<Layer>([.ships, .satellites, .cctv, .fires, .bikeshare, .radio, .cables, .airports, .stations, .alerts, .trains, .peaks, .simulation])).isEmpty
        guard contactViewport || viewportLayers else { return false }
        guard let last = lastDisplaySample else { return true }
        let moveThreshold = max(distance * (contactViewport ? 0.08 : (show3D ? 0.08 : 0.12)), layers.contains(.cctv) ? 2_500 : (contactViewport ? 8_000 : 12_000))
        let zoomThreshold = max(distance * 0.16, 20_000)
        return last.center.distance(to: center) > moveThreshold || abs(last.distance - distance) > zoomThreshold
    }

    func reverseGeocode(_ c: CLLocationCoordinate2D) async -> (title: String, detail: String, extraMeta: [MetaRow]) {
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let p = try? await geocoder.reverseGeocodeLocation(loc).first else {
            return (Fmt.coord(c.latitude, c.longitude), "Unresolved position", [])
        }
        let title = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.country ?? p.ocean ?? p.inlandWater ?? Fmt.coord(c.latitude, c.longitude)
        let detail = [p.name, p.administrativeArea, p.country].compactMap { $0 }.filter { $0 != title }.joined(separator: ", ")

        var meta: [MetaRow] = []
        let address = [p.subThoroughfare, p.thoroughfare, p.subLocality, p.locality, p.administrativeArea, p.postalCode, p.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !address.isEmpty { meta.append(MetaRow("Address", address)) }
        if let area = p.subLocality, !area.isEmpty { meta.append(MetaRow("Neighborhood", area)) }
        if let city = p.locality, !city.isEmpty { meta.append(MetaRow("City", city)) }
        if let region = p.administrativeArea, !region.isEmpty { meta.append(MetaRow("Region", region)) }
        if let country = p.country, !country.isEmpty { meta.append(MetaRow("Country", country)) }
        if let postal = p.postalCode, !postal.isEmpty { meta.append(MetaRow("Postal code", postal)) }
        if let tz = p.timeZone?.identifier, !tz.isEmpty { meta.append(MetaRow("Time zone", tz)) }

        return (title, detail.isEmpty ? "Location" : detail, meta)
    }

    func fly(to c: CLLocationCoordinate2D, distance d: Double, pitch: Double = 0, heading: Double = 0, duration: Double = 1.2) {
        programmaticMoveUntil = Date().addingTimeInterval(duration + 0.6)
        withAnimation(.easeInOut(duration: duration)) {
            camera = .camera(MapCamera(centerCoordinate: c, distance: d, heading: heading, pitch: pitch))
        }
    }

    func resetGlobe() {
        stopTracking(silent: true)
        stopDirector()
        fly(to: AppState.home, distance: AppState.globeDistance)
    }

    func locateMe() {
        location.request()
        if let c = location.coordinate { fly(to: c, distance: 40_000, pitch: 45) }
        else { show("Waiting for location fix…") }
    }

    func run(_ m: Mission) {
        stopTracking(silent: true)
        layers = m.layers
        let c = m.camera
        fly(to: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), distance: c.distance, pitch: c.pitch, duration: 1.8)
        show("Mission: \(m.title)")
    }

    // MARK: Selection

    func select(_ e: Entity, flyTo: Bool = true) {
        if flyTo && !(isTracking && trackedID == e.id) {
            fly(to: e.coord, distance: e.viewDistance, pitch: e.kind == .place || e.kind == .camera ? 55 : 35)
        }
        if showTimeline || showRoster {
            focusedEvent = e
            showTimeline = false
            showRoster = false
            Task { try? await Task.sleep(nanoseconds: 450_000_000); self.selected = e }
        } else {
            selected = e
        }
    }

    func tapPoint(_ c: CLLocationCoordinate2D) {
        if measureMode { measureTap(c); return }
        let d = distance
        Task {
            let r = await reverseGeocode(c)
            select(Entity.place(lat: c.latitude,
                                lon: c.longitude,
                                name: r.title,
                                detail: r.detail,
                                distance: min(max(d * 0.35, 3_000), 600_000),
                                extraMeta: r.extraMeta))
        }
    }

    func entity(forBookmark b: Bookmark) -> Entity {
        if b.kind == .aircraft || b.kind == .military, let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == b.id }) { return Entity.from(c) }
        if b.kind == .earthquake, let q = quakes.first(where: { "eq-\($0.id)" == b.id }) { return Entity.from(q) }
        if b.kind == .launch, let l = launches.first(where: { "ll-\($0.id)" == b.id }) { return Entity.from(l) }
        if b.kind == .satellite, let s = satellites.first(where: { "sat-\($0.id)" == b.id }) { return Entity.from(s) }
        if b.kind == .ship, let v = ships.values.first(where: { "sh-\($0.id)" == b.id }) { return Entity.from(v) }
        if b.kind == .camera, let cam = cameras.first(where: { "cam-\($0.id)" == b.id }) { return Entity.from(cam) }
        if b.kind == .radio, let r = radioStations.first(where: { "radio-\($0.id)" == b.id }) { return Entity.from(r) }
        return b.entity
    }

    func nearestCamera(to c: CLLocationCoordinate2D) -> (Camera, Double)? {
        guard let best = cameras.filter({ $0.available }).min(by: { $0.coord.distance(to: c) < $1.coord.distance(to: c) }) else { return nil }
        return (best, best.coord.distance(to: c))
    }

    func handoffToNearestCamera(from e: Entity) {
        if cameras.isEmpty {
            Task { await refreshCameras(); if !cameras.isEmpty { handoffToNearestCamera(from: e) } else { show("Camera feed unavailable") } }
            return
        }
        guard let (cam, d) = nearestCamera(to: e.coord) else { show("No cameras loaded"); return }
        if !layers.contains(.cctv) { layers.insert(.cctv) }
        show(String(format: "Nearest cam %.0f km away · %@", d / 1000, cam.source))
        openLive(cam)
    }

    // MARK: Tracking / chase

    func track(_ e: Entity) {
        guard e.kind.trackable else { return }
        stopDirector()
        trackedID = e.id
        trackedEntity = e
        trackedCoord = e.coord
        trackedHeading = e.heading
        trail = [e.coord]
        satTrack = []
        lastTrackedFix = nil
        if e.kind == .aircraft || e.kind == .military,
           let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == e.id }) {
            lastTrackedFix = (c.coord, c.seenAt, c.groundSpeedKt ?? 0, c.track)
        }
        if e.kind == .satellite, let p = propagators.first(where: { "sat-\($0.noradID)" == e.id }) {
            satTrack = p.groundTrack(from: Date(), minutes: min(p.periodMinutes, 95), step: 1)
        }
        selected = nil
        traceHistory = []
        weather = nil
        startTrackLoop()
        followCamera(animated: true)
        rebuildDisplay()
        LiveActivityManager.shared.start(e)
        startWeather()
        if e.kind == .aircraft || e.kind == .military { Task { await loadTrace(for: e) } }
        if e.kind == .storm, let cell = storms.first(where: { "storm-\($0.id)" == e.id }) { trail = cell.history }
        show("Tracking \(e.title)")
    }

    func loadTrace(for e: Entity) async {
        let hex = e.id.replacingOccurrences(of: "ac-", with: "")
        guard let pts = try? await Feeds.shared.trace(hex: hex), pts.count > 2 else { return }
        guard trackedID == e.id else { return }
        let step = max(1, pts.count / 600)
        traceHistory = pts.enumerated().filter { $0.offset % step == 0 }.map { $0.element.coord }
        show("Trace: \(pts.count) fixes · \(Fmt.rel.localizedString(for: pts.first!.time, relativeTo: Date()))")
    }

    private func startWeather() {
        weatherTask?.cancel()
        weatherTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let c = self.trackedCoord else { return }
                if let w = try? await Feeds.shared.weather(at: c) { self.weather = w }
                try? await Task.sleep(nanoseconds: 90_000_000_000)
            }
        }
    }

    func toggleChase() {
        guard isTracking else { return }
        chase.toggle()
        followCamera(animated: true)
        show(chase ? "Cockpit view" : "Track view")
    }

    func stopTracking(silent: Bool = false) {
        guard trackedID != nil else { return }
        trackedID = nil
        trackedEntity = nil
        trackedCoord = nil
        trail = []
        satTrack = []
        chase = false
        traceHistory = []
        weather = nil
        trackTask?.cancel()
        trackTask = nil
        weatherTask?.cancel()
        weatherTask = nil
        LiveActivityManager.shared.end()
        stopOrbit()
        if !silent { show("Tracking released") }
        rebuildDisplay()
    }

    private func startTrackLoop() {
        trackTask?.cancel()
        trackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.isTracking else { return }
                self.trackTick(fromPoll: false)
            }
        }
    }

    /// Dead-reckon the tracked aircraft between polls; snap on new fixes.
    private func trackTick(fromPoll: Bool) {
        guard let tid = trackedID, tid.hasPrefix("ac-") else { return }
        if fromPoll {
            guard let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == tid }) else { return }
            lastTrackedFix = (c.coord, c.seenAt, c.groundSpeedKt ?? 0, c.track)
            trackedEntity = Entity.from(c)
            trackedHeading = c.track
            trail.append(c.coord)
            if trail.count > 240 { trail.removeFirst(trail.count - 240) }
            trackedCoord = c.coord
            followCamera(animated: true)
            if let te = trackedEntity { LiveActivityManager.shared.update(te, coord: c.coord) }
            return
        }
        guard let fix = lastTrackedFix, fix.gsKt > 0 else { return }
        let dt = Date().timeIntervalSince(fix.at)
        guard dt < 90 else { return }
        let meters = fix.gsKt * 0.514444 * dt
        trackedCoord = fix.coord.moved(meters: meters, bearing: fix.track)
        followCamera(animated: true, duration: 1.0)
    }

    private func followCamera(animated: Bool, duration: Double = 1.2) {
        guard let c = trackedCoord else { return }
        if orbiting { return }
        let kind = trackedEntity?.kind ?? .aircraft
        if chase {
            let d: Double = kind == .satellite ? 2_500_000 : (kind == .ship ? 1_500 : kind == .train ? 900 : kind == .storm ? 250_000 : 2_800)
            let p: Double = kind == .satellite ? 60 : kind == .storm ? 30 : 74
            fly(to: c, distance: d, pitch: p, heading: trackedHeading, duration: duration)
        } else {
            let d = max(min(distance, kind == .satellite ? 6_000_000 : 400_000), kind == .satellite ? 800_000 : 3_000)
            fly(to: c, distance: d, pitch: min(pitch, 60), heading: heading, duration: duration)
        }
    }

    func trackNearest(kind: String?) {
        guard let e = roster(kind: kind, limit: 1).first else { show("Nothing to track here"); return }
        track(e)
    }

    func stepRoster(forward: Bool, kind: String? = nil) {
        let list = roster(kind: kind, limit: 60)
        guard !list.isEmpty else { show("No contacts"); return }
        guard let tid = trackedID, let i = list.firstIndex(where: { $0.id == tid }) else { track(list[0]); return }
        let n = forward ? (i + 1) % list.count : (i - 1 + list.count) % list.count
        track(list[n])
    }

    // MARK: Director

    func toggleDirector() { directing ? stopDirector() : startDirector() }

    func startDirector() {
        stopTracking(silent: true)
        directing = true
        show("Scene director: on")
        directorTask?.cancel()
        directorTask = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                guard let self, self.directing else { return }
                let shots = self.directorShots()
                guard !shots.isEmpty else { self.stopDirector(); return }
                let s = shots[i % shots.count]
                i += 1
                let h = Double((i * 47) % 360)
                self.fly(to: s.coord, distance: s.distance, pitch: s.pitch, heading: h, duration: 2.4)
                self.programmaticMoveUntil = Date().addingTimeInterval(7.5)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, self.directing else { return }
                self.fly(to: s.coord, distance: s.distance * 0.7, pitch: min(s.pitch + 10, 70), heading: h + 35, duration: 4.0)
                self.programmaticMoveUntil = Date().addingTimeInterval(5.0)
                try? await Task.sleep(nanoseconds: 4_200_000_000)
            }
        }
    }

    private func directorShots() -> [(coord: CLLocationCoordinate2D, distance: Double, pitch: Double)] {
        var s: [(coord: CLLocationCoordinate2D, distance: Double, pitch: Double)] = []
        if let iss = iss { s.append((iss.coord, 2_500_000, 45)) }
        for q in quakes.filter({ $0.mag >= 4.5 }).prefix(3) { s.append((q.coord, 300_000, 55)) }
        if let l = launches.first(where: { $0.net > Date() }) { s.append((l.coord, 12_000, 60)) }
        for c in visibleContacts.prefix(2) { s.append((c.coord, 25_000, 65)) }
        for v in visibleShips.prefix(1) { s.append((v.coord, 8_000, 60)) }
        if s.isEmpty { s.append((center, max(distance, 500_000), 45)) }
        return s
    }

    func stopDirector() {
        guard directing || directorTask != nil else { return }
        directing = false
        directorTask?.cancel()
        directorTask = nil
    }

    // MARK: Orbit mode

    func toggleOrbit() { orbiting ? stopOrbit() : startOrbit() }

    func startOrbit() {
        orbiting = true
        stopDirector()
        show("Orbit: on")
        orbitTask?.cancel()
        orbitTask = Task { [weak self] in
            var h = self?.heading ?? 0
            while !Task.isCancelled {
                guard let self, self.orbiting else { return }
                h = (h + 4).truncatingRemainder(dividingBy: 360)
                let c = self.trackedCoord ?? self.selected?.coord ?? self.center
                let d = max(self.distance, 800)
                self.programmaticMoveUntil = Date().addingTimeInterval(1.2)
                withAnimation(.linear(duration: 0.5)) {
                    self.camera = .camera(MapCamera(centerCoordinate: c, distance: d, heading: h, pitch: max(self.pitch, 55)))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopOrbit() {
        guard orbiting else { return }
        orbiting = false
        orbitTask?.cancel()
        orbitTask = nil
    }

    // MARK: Measure

    func toggleMeasure() {
        measureMode.toggle()
        if measureMode { measureA = nil; measureB = nil; measureLine = []; show("Measure: tap two points") }
    }

    func measureTap(_ c: CLLocationCoordinate2D) {
        if measureA == nil || measureB != nil { measureA = c; measureB = nil; measureLine = []; return }
        measureB = c
        finishMeasure()
    }

    private func finishMeasure() {
        guard let a = measureA, let b = measureB else { return }
        measureLine = Geo.greatCircle(a, b)
        let km = a.distance(to: b) / 1000
        show(String(format: "%.1f km · %.0f nm · brg %03.0f°", km, km / 1.852, Geo.bearing(from: a, to: b)))
    }

    func measure(from p1: String, to p2: String) {
        Task {
            async let a = geocode(p1)
            async let b = geocode(p2)
            guard let ca = await a, let cb = await b else { show("Couldn't resolve one of those places"); return }
            measureMode = false
            measureA = ca; measureB = cb
            finishMeasure()
            let mid = Geo.greatCircle(ca, cb, points: 2)[1]
            fly(to: mid, distance: max(ca.distance(to: cb) * 2.2, 50_000), pitch: 20, duration: 1.8)
        }
    }

    func geocode(_ q: String) async -> CLLocationCoordinate2D? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90))
        return try? await MKLocalSearch(request: req).start().mapItems.first?.placemark.coordinate
    }

    func clearMeasure() { measureA = nil; measureB = nil; measureLine = []; measureMode = false }

    // MARK: Region outlines

    func outline(_ name: String) {
        Task {
            do {
                let rings = try await Feeds.shared.boundary(named: name)
                regions.append(RegionOutline(name: name.uppercased(), rings: rings))
                let all = rings.flatMap { $0 }
                guard !all.isEmpty else { show("No boundary for \(name)"); return }
                let lat = (all.map(\.latitude).min()! + all.map(\.latitude).max()!) / 2
                let lon = (all.map(\.longitude).min()! + all.map(\.longitude).max()!) / 2
                let span = max(all.map(\.latitude).max()! - all.map(\.latitude).min()!, (all.map(\.longitude).max()! - all.map(\.longitude).min()!) * 0.6)
                fly(to: CLLocationCoordinate2D(latitude: lat, longitude: lon), distance: max(span * 111_000 * 2.2, 40_000), pitch: 0, duration: 1.8)
                show("Outlined \(name)")
            } catch { show("No boundary for \(name)") }
        }
    }

    // MARK: Launch replay

    func startReplay(_ l: Launch) {
        replay = LaunchReplay(l)
        replayT = 0
        replayRate = 1
        selected = nil
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            showReplay = true
            fly(to: l.coord, distance: 40_000, pitch: 65, heading: replay?.azimuth ?? 90, duration: 1.6)
        }
    }

    func replayToggle() { replayPlaying ? replayPause() : replayPlay() }

    func replayPlay() {
        guard let r = replay else { return }
        replayPlaying = true
        if replayT >= LaunchReplay.duration { replayT = 0 }
        replayTask?.cancel()
        replayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.replayPlaying else { return }
                self.replayT = min(LaunchReplay.duration, self.replayT + 0.25 * 10 * self.replayRate)
                let st = r.state(at: self.replayT)
                self.programmaticMoveUntil = Date().addingTimeInterval(1)
                withAnimation(.linear(duration: 0.25)) {
                    self.camera = .camera(MapCamera(centerCoordinate: st.coord, distance: 40_000 + st.altKm * 12_000, heading: r.azimuth - 40, pitch: 62))
                }
                if self.replayT >= LaunchReplay.duration { self.replayPlaying = false; return }
            }
        }
    }

    func replayPause() { replayPlaying = false; replayTask?.cancel(); replayTask = nil }

    func endReplay() { replayPause(); replay = nil; showReplay = false }

    // MARK: Radio tuner

    func tune(_ st: RadioStation) {
        radio.play(st)
        fly(to: st.coord, distance: 60_000, pitch: 45, duration: 1.6)
        show("♪ \(st.name)")
    }

    func tuneNear(_ place: String) {
        Task {
            if radioStations.isEmpty { await refreshRadio() }
            let c: CLLocationCoordinate2D
            if place == "here" || place.isEmpty { c = center } else if let g = await geocode(place) { c = g } else { show("Couldn't find \(place)"); return }
            guard let st = radioStations.min(by: { $0.coord.distance(to: c) < $1.coord.distance(to: c) }) else { return }
            if !layers.contains(.radio) { layers.insert(.radio) }
            tune(st)
        }
    }

    // MARK: Scenes (keyframe recorder)

    func addKeyframe() {
        keyframes.append(Keyframe(lat: center.latitude, lon: center.longitude, distance: distance, heading: heading, pitch: pitch))
        show("Keyframe \(keyframes.count) captured")
    }

    func playScene() {
        guard !keyframes.isEmpty else { show("No keyframes"); return }
        scenePlaying = true
        stopTracking(silent: true)
        stopDirector()
        sceneTask?.cancel()
        sceneTask = Task { [weak self] in
            guard let self else { return }
            for k in self.keyframes {
                guard !Task.isCancelled, self.scenePlaying else { return }
                self.fly(to: k.coord, distance: k.distance, pitch: k.pitch, heading: k.heading, duration: k.travel)
                self.programmaticMoveUntil = Date().addingTimeInterval(k.travel + k.hold + 0.5)
                try? await Task.sleep(nanoseconds: UInt64((k.travel + k.hold) * 1_000_000_000))
            }
            self.scenePlaying = false
        }
    }

    func stopScene() { scenePlaying = false; sceneTask?.cancel(); sceneTask = nil }

    func exportScene(named name: String) -> URL? {
        SceneIO.save(SceneFile(name: name, keyframes: keyframes, sensor: sensor.rawValue, layers: layers.map(\.rawValue)))
    }

    func importScene(_ url: URL) {
        guard let sc = SceneIO.load(url) else { show("Couldn't read scene"); return }
        keyframes = sc.keyframes
        if let m = SensorMode(rawValue: sc.sensor) { sensor = m }
        layers = Set(sc.layers.compactMap(Layer.init(rawValue:)))
        show("Loaded \(sc.name): \(sc.keyframes.count) keyframes")
    }

    // MARK: AI HUD summary

    func scheduleAISummary() {
        guard hud, !anthropicKey.isEmpty else { return }
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            let ctx = """
            View center: \(self.centerName) (\(Fmt.coord(self.center.latitude, self.center.longitude))), camera distance \(Int(self.distance / 1000)) km, pitch \(Int(self.pitch)).
            Layers: \(self.layers.map(\.rawValue).joined(separator: ",")). Aircraft in view: \(self.visibleContacts.count), military: \(self.visibleContacts.filter(\.military).count), ships: \(self.visibleShips.count), quakes: \(self.visibleQuakes.count), fires: \(self.visibleFires.count), sats: \(self.visibleSatellites.count).
            Tracking: \(self.trackedEntity.map { "\($0.kind.label) \($0.title) — \($0.summary)" } ?? "none"). Sensor: \(self.sensor.title). Time UTC \(Fmt.utc(Date())).
            """
            if let t = try? await Feeds.shared.aiSummary(key: self.anthropicKey, model: self.aiModel, context: ctx) {
                guard !Task.isCancelled else { return }
                self.aiSummary = t
            }
        }
    }

    // MARK: ISS passes + alerts

    func computePasses() {
        guard let me = location.coordinate,
              let iss = propagators.first(where: { $0.noradID == 25544 }) else { return }
        passes = PassPredictor.passes(iss, observer: me)
        if alertISS, let next = passes.first {
            Alerts.shared.schedule(id: "iss-\(Int(next.start.timeIntervalSince1970))",
                                   title: "ISS pass in 10 min",
                                   body: String(format: "Max elevation ~%.0f° at %@", next.maxElevationDeg, Fmt.time(next.peak)),
                                   at: next.start.addingTimeInterval(-600))
        }
    }

    func checkAlerts() {
        if alertQuakes {
            for q in quakes where q.mag >= alertQuakeMag && Date().timeIntervalSince(q.time) < 3600 {
                Alerts.shared.fire(id: "eq-\(q.id)", title: String(format: "M%.1f earthquake", q.mag), body: q.place)
            }
        }
        if alertMilitary, let me = location.coordinate {
            for c in (contacts + militaryContacts) where c.military && c.coord.distance(to: me) < 80_000 {
                Alerts.shared.fire(id: "mil-\(c.id)-\(Calendar.current.component(.hour, from: Date()))",
                                   title: "Military contact nearby",
                                   body: "\(c.displayName) \(c.type ?? "") · \(Int(c.coord.distance(to: me) / 1000)) km · \(c.altFt.map { "\($0) ft" } ?? "")")
            }
        }
        if alertISS, passes.isEmpty || (passes.first.map { $0.end < Date() } ?? false) { computePasses() }
    }

    // MARK: Background refresh

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "party.mrvek.godseye.refresh", using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                self?.scheduleBackgroundRefresh()
                await self?.refreshQuakes()
                await self?.refreshContacts(force: true)
                self?.checkAlerts()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { task.setTaskCompleted(success: false) }
        }
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        guard alertMilitary || alertQuakes || alertISS else { return }
        let req = BGAppRefreshTaskRequest(identifier: "party.mrvek.godseye.refresh")
        req.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: Annotations (voice whiteboard)

    func annotate(_ label: String, at c: CLLocationCoordinate2D? = nil) {
        let p = c ?? center
        annotations.append(Annotation2D(label: label, lat: p.latitude, lon: p.longitude))
        show("Marked: \(label)")
    }

    func clearAnnotations() { annotations = []; show("Map cleared") }

    // MARK: Voice

    func handleVoice(_ text: String) {
        let cmd = VoiceCommand.parse(text)
        switch cmd {
        case .goTo(let place):
            Task {
                let req = MKLocalSearch.Request()
                req.naturalLanguageQuery = place
                req.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 80))
                if let item = try? await MKLocalSearch(request: req).start().mapItems.first {
                    let isAirport = item.pointOfInterestCategory == .airport
                    fly(to: item.placemark.coordinate, distance: isAirport ? 15_000 : 8_000, pitch: 50, duration: 1.8)
                    show("→ \(item.name ?? place)")
                    if text.lowercased().contains("track") || text.lowercased().contains("nearest") {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await refreshContacts(force: true)
                        trackNearest(kind: "aircraft")
                    }
                } else { show("Couldn't find \(place)") }
            }
        case .trackNearest(let kind): trackNearest(kind: kind)
        case .trackCallsign(let cs):
            if let c = (contacts + militaryContacts).first(where: { $0.callsign.uppercased().hasPrefix(cs) || $0.id.uppercased() == cs }) { track(Entity.from(c)) }
            else { show("No contact \(cs)") }
        case .cockpit(let on):
            if on, !isTracking { trackNearest(kind: "aircraft") }
            if chase != on { toggleChase() }
        case .stopTracking: stopTracking()
        case .sensor(let m): sensor = m; show("Sensor: \(m.title)")
        case .layer(let l, let on):
            if on { layers.insert(l) } else { layers.remove(l) }
            show("\(l.title): \(on ? "on" : "off")")
        case .resetGlobe: resetGlobe()
        case .hud(let on): hud = on
        case .detection(let on): detection = on
        case .director(let on): if on { startDirector() } else { stopDirector() }
        case .mission(let m): run(m)
        case .timeline: openTimeline(at: nil)
        case .nearestCamera:
            let e = trackedEntity ?? selected ?? Entity.place(lat: center.latitude, lon: center.longitude, name: "Center", detail: "", distance: distance)
            handoffToNearestCamera(from: e)
        case .annotate(let label): annotate(label)
        case .clearAnnotations: clearAnnotations(); regions = []; clearMeasure()
        case .outline(let name): outline(name)
        case .measure(let a, let b): measure(from: a, to: b)
        case .orbit(let on): if on { startOrbit() } else { stopOrbit() }
        case .radioNear(let place): tuneNear(place)
        case .issPass:
            computePasses()
            if let p = passes.first { show(String(format: "ISS: %@ · max %.0f°", Fmt.rel.localizedString(for: p.start, relativeTo: Date()), p.maxElevationDeg)) }
            else { show(location.coordinate == nil ? "Need your location for passes" : "No ISS pass in 24h") }
        case .radarToggle(let on): if on { layers.insert(.radar) } else { layers.remove(.radar) }
        case .listenScanner(let place):
            Task { if scanners.isEmpty { await refreshScanners() }
                let c = place.isEmpty ? center : (await geocode(place) ?? center)
                if let f = scanners.min(by: { $0.coord.distance(to: c) < $1.coord.distance(to: c) }) { listen(f); fly(to: f.coord, distance: 30_000, pitch: 40) } else { show("No scanner feeds resolved") } }
        case .spaceWeather:
            Task { await refreshSpace(); show("Kp \(String(format: "%.1f", space.kp)) · \(space.stormLevel) · X-ray \(space.xrayClass)") ; showSpace = true }
        case .terrainProfile: loadProfile()
        case .replayLaunch:
            if let l = launches.filter({ $0.net < Date() }).last ?? launches.first { startReplay(l) } else { show("No launch loaded") }
        case .unknown: show("Didn't catch that: “\(text)”")
        }
    }

    // MARK: Deep links   godseye://view?lat=&lon=&d=&h=&p=&layers=a,b&sensor=nvg&target=ac-xxxx

    var deepLink: String {
        var parts = [
            "lat=\(String(format: "%.5f", center.latitude))",
            "lon=\(String(format: "%.5f", center.longitude))",
            "d=\(Int(distance))", "h=\(Int(heading))", "p=\(Int(pitch))",
            "layers=\(layers.map(\.rawValue).sorted().joined(separator: ","))",
            "sensor=\(sensor.rawValue)"
        ]
        if let t = trackedID { parts.append("target=\(t)") }
        else if let s = selected {
            parts.append("target=\(s.id)")
            parts.append("tlat=\(String(format: "%.5f", s.lat))")
            parts.append("tlon=\(String(format: "%.5f", s.lon))")
            parts.append("title=\(s.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        return "godseye://view?" + parts.joined(separator: "&")
    }

    func open(url: URL) {
        guard ready else { pendingDeepLink = url; return }
        guard url.scheme == "godseye", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        if let ls = q["layers"] { layers = Set(ls.split(separator: ",").compactMap { Layer(rawValue: String($0)) }) }
        if let sr = q["sensor"], let m = SensorMode(rawValue: sr) { sensor = m }
        if let la = Double(q["lat"] ?? ""), let lo = Double(q["lon"] ?? "") {
            fly(to: CLLocationCoordinate2D(latitude: la, longitude: lo),
                distance: Double(q["d"] ?? "") ?? 500_000,
                pitch: Double(q["p"] ?? "") ?? 0,
                heading: Double(q["h"] ?? "") ?? 0, duration: 1.8)
        }
        if let target = q["target"] {
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                await refreshContacts(force: true)
                if let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == target }) { track(Entity.from(c)); return }
                if let s = satellites.first(where: { "sat-\($0.id)" == target }) { track(Entity.from(s)); return }
                if let qk = quakes.first(where: { "eq-\($0.id)" == target }) { select(Entity.from(qk)); return }
                if let l = launches.first(where: { "ll-\($0.id)" == target }) { select(Entity.from(l)); return }
                if let la = Double(q["tlat"] ?? ""), let lo = Double(q["tlon"] ?? "") {
                    select(Entity.place(lat: la, lon: lo, name: q["title"] ?? "Shared target", detail: "From shared link", distance: 20_000))
                } else { show("Target not on globe right now") }
            }
        }
        show("Opened shared view")
    }

    // MARK: Bookmarks

    func isBookmarked(_ e: Entity) -> Bool { bookmarks.contains { $0.id == e.id } }

    func toggleBookmark(_ e: Entity) {
        if let i = bookmarks.firstIndex(where: { $0.id == e.id }) { bookmarks.remove(at: i) }
        else { bookmarks.insert(Bookmark(e), at: 0) }
    }

    func removeBookmarks(at offsets: IndexSet) { bookmarks.remove(atOffsets: offsets) }

    // MARK: Timeline

    func openTimeline(at date: Date?) {
        if let d = date { timeCursor = min(max(d, windowStart), windowEnd) }
        if selected != nil {
            selected = nil
            Task { try? await Task.sleep(nanoseconds: 450_000_000); self.showTimeline = true }
        } else {
            showTimeline = true
        }
    }

    func setCursor(fraction f: Double) {
        pause()
        let t = windowStart.addingTimeInterval(f * windowEnd.timeIntervalSince(windowStart))
        timeCursor = abs(t.timeIntervalSinceNow) < 90 ? nil : t
    }

    func goLive() {
        pause()
        timeCursor = nil
        focusedEvent = nil
    }

    func togglePlay() { playing ? pause() : play() }

    func play() {
        playing = true
        if timeCursor == nil || timeCursor! >= windowEnd { timeCursor = windowStart }
        playTask?.cancel()
        playTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                let next = (self.timeCursor ?? self.windowStart).addingTimeInterval(20 * 60)
                if next >= self.windowEnd { self.timeCursor = nil; self.playing = false; self.rebuildDisplay(); return }
                self.timeCursor = next
                tick += 1
                if tick % 3 == 0 { self.rebuildDisplay() }
            }
        }
    }

    func pause() {
        playing = false
        playTask?.cancel()
        playTask = nil
        rebuildDisplay()
    }

    func jump(forward: Bool) {
        pause()
        let events = timelineEvents
        let t = effectiveTime
        let target: Entity? = forward
            ? events.first { ($0.time ?? .distantPast) > t.addingTimeInterval(1) }
            : events.last { ($0.time ?? .distantFuture) < t.addingTimeInterval(-1) }
        guard let e = target, let et = e.time else { return }
        timeCursor = et
        focusedEvent = e
        fly(to: e.coord, distance: max(e.viewDistance, 800_000), pitch: 30)
    }

    func nearestEvent() -> Entity? {
        let t = effectiveTime
        return timelineEvents.min { abs(($0.time ?? t).timeIntervalSince(t)) < abs(($1.time ?? t).timeIntervalSince(t)) }
    }

    // MARK: Misc

    func clearCache() {
        FeedCache.clear()
        cacheBytes = 0
        show("Cache cleared")
    }

    private var toastTask: Task<Void, Never>?
    func show(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

extension CLLocationCoordinate2D {
    /// Move along a bearing (degrees) by meters on a sphere.
    func moved(meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let d = meters / R
        let b = bearing * .pi / 180
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
