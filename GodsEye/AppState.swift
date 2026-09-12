import Foundation
import SwiftUI
import MapKit
import CoreLocation

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
            if layers.contains(.cctv) && cameras.isEmpty { Task { await refreshCameras() } }
            if layers.contains(.ships) { connectAIS() } else { ais.disconnect() }
        }
    }
    @Published var contacts: [Contact] = [] { didSet { rebuildDisplay(); trackTick(fromPoll: true) } }
    @Published var militaryContacts: [Contact] = [] { didSet { rebuildDisplay() } }
    @Published var quakes: [Quake] = [] { didSet { rebuildDisplay() } }
    @Published var ships: [String: Ship] = [:]
    @Published var satellites: [Satellite] = []
    @Published var cameras: [Camera] = []
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
    @Published var pendingSharedView: URL?

    // Modes
    @Published var sensor: SensorMode { didSet { ud.set(sensor.rawValue, forKey: "sensor") } }
    @Published var hud: Bool { didSet { ud.set(hud, forKey: "hud") } }
    @Published var detection: Bool { didSet { ud.set(detection, forKey: "detection") } }
    @Published var annotations: [Annotation2D] = []

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
    @Published var timeCursor: Date? { didSet { if (timeCursor == nil) != (oldValue == nil) || playing == false { rebuildDisplay() } } }
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
    @Published var cacheBytes: Int64 = FeedCache.size()

    let location = LocationService()
    let voice = VoiceController()
    let ais = AISClient()
    private let ud = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var satTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var lastContactFetchCenter: CLLocationCoordinate2D?
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
        sensor = SensorMode(rawValue: ud.string(forKey: "sensor") ?? "") ?? .normal
        hud = ud.bool(forKey: "hud")
        detection = ud.bool(forKey: "detection")
        if let d = ud.data(forKey: "bookmarks"), let b = try? JSONDecoder().decode([Bookmark].self, from: d) { bookmarks = b }
        Feeds.shared.offline = offlineMode
        voice.onCommand = { [weak self] text in self?.handleVoice(text) }
        ais.onShip = { [weak self] ship in self?.ingest(ship) }
        ais.onStatus = { [weak self] st in self?.aisStatus = st }
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

    var pollInterval: UInt64 { performanceMode ? 30 : 15 }
    var isLive: Bool { timeCursor == nil }
    var effectiveTime: Date { timeCursor ?? Date() }
    var isTracking: Bool { trackedID != nil }

    var contactCap: Int {
        let d = distance
        if d > 7_000_000 { return isTracking ? 40 : 0 }
        if d > 2_500_000 { return performanceMode ? 60 : 120 }
        if d > 800_000 { return performanceMode ? 150 : 300 }
        return performanceMode ? 250 : 600
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
            let shipCap = performanceMode ? 200 : 400
            sh = Array(ships.values.filter { $0.seenAt > cutoff }
                .map { ($0, $0.coord.distance(to: cen)) }
                .sorted { $0.1 < $1.1 }
                .prefix(shipCap)
                .map(\.0))
        }
        if sh != visibleShips { visibleShips = sh }

        var cams: [Camera] = []
        if layers.contains(.cctv), distance < 400_000 {
            let camCap = distance < 15_000 ? 400 : 120
            cams = Array(cameras.filter { $0.available }
                .map { ($0, $0.coord.distance(to: cen)) }
                .filter { $0.1 < 60_000 }
                .sorted { $0.1 < $1.1 }
                .prefix(camCap)
                .map(\.0))
        }
        if cams != visibleCameras { visibleCameras = cams }
    }

    var visibleLaunches: [Launch] { layers.contains(.launches) ? launches : [] }
    var visibleSatellites: [Satellite] {
        guard layers.contains(.satellites) else { return [] }
        if distance > 3_000_000 || !performanceMode { return satellites }
        return satellites.filter { $0.coord.distance(to: center) < 4_000_000 }
    }

    var timelineEvents: [Entity] {
        var e: [Entity] = quakes.filter { $0.mag >= 4.5 }.map { Entity.from($0) }
        e += launches.map { Entity.from($0) }
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
        if let u = pendingDeepLink {
            pendingDeepLink = nil
            pendingSharedView = u
        }
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
                self.cacheBytes = FeedCache.size()
            }
        }
    }

    private func startSatelliteTicker() {
        satTask?.cancel()
        satTask = Task { [weak self] in
            while !Task.isCancelled {
                let secs: UInt64 = (self?.performanceMode ?? true) ? 5 : 3
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
        do { quakes = try await Feeds.shared.quakes() } catch { feedErrors += 1 }
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

    func refreshAll() async {
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
        if contactCap != prevCap || contactCap > 0 || layers.contains(.ships) || layers.contains(.cctv) { rebuildDisplay() }
        if let last = lastContactFetchCenter, last.distance(to: center) > 200_000, !isTracking {
            Task { await refreshContacts(force: true) }
        }
        if layers.contains(.ships), ais.needsResubscribe(for: center) { connectAIS() }
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

    func reverseGeocode(_ c: CLLocationCoordinate2D) async -> (title: String, detail: String) {
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let p = try? await geocoder.reverseGeocodeLocation(loc).first else {
            return (Fmt.coord(c.latitude, c.longitude), "Unresolved position")
        }
        let title = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.country ?? p.ocean ?? p.inlandWater ?? Fmt.coord(c.latitude, c.longitude)
        let detail = [p.name, p.administrativeArea, p.country].compactMap { $0 }.filter { $0 != title }.joined(separator: ", ")
        return (title, detail.isEmpty ? "Location" : detail)
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
        let d = distance
        Task {
            let r = await reverseGeocode(c)
            select(Entity.place(lat: c.latitude, lon: c.longitude, name: r.title, detail: r.detail, distance: min(max(d * 0.35, 3_000), 600_000)))
        }
    }

    func entity(forBookmark b: Bookmark) -> Entity {
        if b.kind == .aircraft || b.kind == .military, let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == b.id }) { return Entity.from(c) }
        if b.kind == .earthquake, let q = quakes.first(where: { "eq-\($0.id)" == b.id }) { return Entity.from(q) }
        if b.kind == .launch, let l = launches.first(where: { "ll-\($0.id)" == b.id }) { return Entity.from(l) }
        if b.kind == .satellite, let s = satellites.first(where: { "sat-\($0.id)" == b.id }) { return Entity.from(s) }
        if b.kind == .ship, let v = ships.values.first(where: { "sh-\($0.id)" == b.id }) { return Entity.from(v) }
        if b.kind == .camera, let cam = cameras.first(where: { "cam-\($0.id)" == b.id }) { return Entity.from(cam) }
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
        selected = nil
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            select(Entity.from(cam))
            show(String(format: "Nearest cam %.0f km away", d / 1000))
        }
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
        startTrackLoop()
        followCamera(animated: true)
        rebuildDisplay()
        show("Tracking \(e.title)")
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
        trackTask?.cancel()
        trackTask = nil
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
        let kind = trackedEntity?.kind ?? .aircraft
        if chase {
            let d: Double = kind == .satellite ? 2_500_000 : (kind == .ship ? 1_500 : 2_800)
            let p: Double = kind == .satellite ? 60 : 74
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
        case .clearAnnotations: clearAnnotations()
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

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "godseye" else { return }
        if ready {
            pendingSharedView = url
        } else {
            pendingDeepLink = url
        }
    }

    func dismissPendingSharedView() {
        pendingSharedView = nil
    }

    func applyPendingSharedView() {
        guard let url = pendingSharedView else { return }
        pendingSharedView = nil
        open(url: url)
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
