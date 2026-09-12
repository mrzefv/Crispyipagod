import Foundation
import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class AppState: ObservableObject {
    static let home = CLLocationCoordinate2D(latitude: 20, longitude: -20)
    static let globeDistance: Double = 26_000_000

    // Camera
    @Published var camera: MapCameraPosition = .camera(MapCamera(centerCoordinate: AppState.home, distance: AppState.globeDistance, heading: 0, pitch: 0))
    @Published var center: CLLocationCoordinate2D = AppState.home
    @Published var distance: Double = AppState.globeDistance
    @Published var centerName: String = "GLOBAL VIEW"

    // Data
    @Published var layers: Set<Layer> {
        didSet {
            ud.set(layers.map(\.rawValue), forKey: "layers")
            rebuildDisplay()
            if layers.contains(.military) && militaryContacts.isEmpty { Task { await refreshMilitary() } }
        }
    }
    @Published var contacts: [Contact] = [] { didSet { rebuildDisplay() } }
    @Published var militaryContacts: [Contact] = [] { didSet { rebuildDisplay() } }
    @Published var quakes: [Quake] = [] { didSet { rebuildDisplay() } }
    @Published var satellites: [SatPos] = []
    @Published var launches: [Launch] = []
    @Published var cameras: [CameraFeed] = CameraFeed.defaults
    @Published var lastUpdate: Date?
    @Published var feedErrors = 0

    // UI
    @Published var selected: Entity?
    @Published var showTimeline = false
    @Published var tab = 0
    @Published var status = "Initializing…"
    @Published var ready = false

    // Timeline
    let windowStart: Date
    let windowEnd: Date
    @Published var timeCursor: Date? { didSet { if (timeCursor == nil) != (oldValue == nil) || playing == false { rebuildDisplay() } } }  // nil == LIVE
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
    @Published var showTraffic: Bool { didSet { ud.set(showTraffic, forKey: "traffic") } }
    @Published var sensorStyleRaw: String { didSet { ud.set(sensorStyleRaw, forKey: "sensorStyle") } }
    @Published var detectionOverlay: Bool { didSet { ud.set(detectionOverlay, forKey: "detectionOverlay") } }
    @Published var tacticalHUD: Bool { didSet { ud.set(tacticalHUD, forKey: "tacticalHUD") } }
    @Published var cacheBytes: Int64 = FeedCache.size()

    @Published var trackedEntityId: String?
    @Published var trackTrail: [CLLocationCoordinate2D] = []
    @Published var nearbyIndex = 0

    let location = LocationService()
    private let ud = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var lastContactFetchCenter: CLLocationCoordinate2D?
    private var geocoder = CLGeocoder()
    private var geocodeTask: Task<Void, Never>?

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
        showTraffic = ud.object(forKey: "traffic") as? Bool ?? false
        sensorStyleRaw = ud.string(forKey: "sensorStyle") ?? SensorStyle.normal.rawValue
        detectionOverlay = ud.object(forKey: "detectionOverlay") as? Bool ?? false
        tacticalHUD = ud.object(forKey: "tacticalHUD") as? Bool ?? false
        if let d = ud.data(forKey: "bookmarks"), let b = try? JSONDecoder().decode([Bookmark].self, from: d) { bookmarks = b }
        Feeds.shared.offline = offlineMode
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
        switch mapStyleRaw {
        case "hybrid": return .hybrid(elevation: elev, pointsOfInterest: .excludingAll, showsTraffic: showTraffic)
        case "standard": return .standard(elevation: elev, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: showTraffic)
        default: return .imagery(elevation: elev)
        }
    }

    var sensorStyle: SensorStyle {
        SensorStyle(rawValue: sensorStyleRaw) ?? .normal
    }

    var iss: SatPos? {
        satellites.first(where: \.isISS) ?? satellites.first
    }

    var visibleSatellites: [SatPos] {
        layers.contains(.satellites) ? satellites : []
    }

    var visibleCameras: [CameraFeed] {
        guard layers.contains(.cameras) else { return [] }
        if distance > 7_000_000 { return [] }
        let ranked = cameras.map { ($0, $0.coord.distance(to: center)) }.sorted { $0.1 < $1.1 }
        return ranked.prefix(distance > 1_500_000 ? 8 : 20).map(\.0)
    }

    var nearbyContacts: [Contact] {
        visibleContacts.sorted { $0.coord.distance(to: center) < $1.coord.distance(to: center) }
    }

    var trackedEntity: Entity? {
        guard let id = trackedEntityId else { return nil }
        if let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == id }) { return Entity.from(c) }
        if let s = satellites.first(where: { "sat-\($0.id)" == id }) { return Entity.from(s) }
        return selected?.id == id ? selected : nil
    }

    var pollInterval: UInt64 { performanceMode ? 30 : 15 }
    var isLive: Bool { timeCursor == nil }
    var effectiveTime: Date { timeCursor ?? Date() }

    // Display lists are cached and rebuilt only when inputs change (never per render).
    @Published private(set) var visibleContacts: [Contact] = []
    @Published private(set) var visibleQuakes: [Quake] = []

    /// Contact cap by zoom: nothing at globe scale, dense only when close.
    var contactCap: Int {
        let d = distance
        if d > 7_000_000 { return 0 }
        if d > 2_500_000 { return performanceMode ? 60 : 120 }
        if d > 800_000 { return performanceMode ? 150 : 300 }
        return performanceMode ? 250 : 600
    }

    func rebuildDisplay() {
        // contacts
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
        let ranked: [Contact]
        if out.count > cap {
            ranked = Array(out.values.map { ($0, $0.coord.distance(to: cen)) }
                .sorted { $0.1 < $1.1 }
                .prefix(cap)
                .map(\.0))
        } else {
            ranked = out.values.sorted { $0.id < $1.id }
        }
        if ranked != visibleContacts { visibleContacts = ranked }

        // quakes
        var q: [Quake] = []
        if layers.contains(.quakes) {
            q = timeCursor.map { t in quakes.filter { $0.time <= t } } ?? quakes
            if distance > 7_000_000 { q = q.filter { $0.mag >= 2.5 } }
        }
        if q != visibleQuakes { visibleQuakes = q }
    }

    var visibleLaunches: [Launch] { layers.contains(.launches) ? launches : [] }

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

    // MARK: Boot

    func boot() async {
        guard !ready else { return }
        status = "Loading globe assets…"
        try? await Task.sleep(nanoseconds: 500_000_000)
        status = "Fetching seismic feed…"
        await refreshQuakes()
        status = "Acquiring orbital tracks…"
        await refreshSatellites()
        status = "Loading launch manifest…"
        await refreshLaunches()
        status = "Listening for transponders…"
        await refreshContacts(force: true)
        if layers.contains(.military) { await refreshMilitary() }
        rebuildDisplay()
        status = "Online"
        location.request()
        ready = true
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.pollInterval ?? 15) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                tick += 1
                await self.refreshContacts(force: false)
                if self.layers.contains(.satellites) { await self.refreshSatellites() }
                if tick % 4 == 0, self.layers.contains(.military) { await self.refreshMilitary() }
                if tick % 20 == 0 { await self.refreshQuakes() }
                if tick % 120 == 0 { await self.refreshLaunches() }
                self.updateTrackingTrail()
                self.cacheBytes = FeedCache.size()
            }
        }
    }

    // MARK: Refresh

    func refreshContacts(force: Bool) async {
        guard layers.contains(.flights) || layers.contains(.military) else { return }
        let c = center
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

    func refreshSatellites() async {
        do { satellites = try await Feeds.shared.satellites() } catch { feedErrors += 1 }
    }

    func refreshLaunches() async {
        do { launches = try await Feeds.shared.launches() } catch { feedErrors += 1 }
    }

    func refreshAll() async {
        await refreshContacts(force: true)
        await refreshQuakes()
        await refreshSatellites()
        await refreshLaunches()
        if layers.contains(.military) { await refreshMilitary() }
        cacheBytes = FeedCache.size()
    }

    // MARK: Camera

    func cameraChanged(_ ctx: MapCameraUpdateContext) {
        let prevCap = contactCap
        center = ctx.camera.centerCoordinate
        distance = ctx.camera.distance
        if contactCap != prevCap || contactCap > 0 { rebuildDisplay() }
        if let last = lastContactFetchCenter, last.distance(to: center) > 200_000 {
            Task { await refreshContacts(force: true) }
        }
        geocodeTask?.cancel()
        if distance > 3_000_000 {
            centerName = "GLOBAL VIEW"
            return
        }
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

    func fly(to c: CLLocationCoordinate2D, distance d: Double, pitch: Double = 0, heading: Double = 0) {
        withAnimation(.easeInOut(duration: 1.2)) {
            camera = .camera(MapCamera(centerCoordinate: c, distance: d, heading: heading, pitch: pitch))
        }
    }

    func resetGlobe() {
        fly(to: AppState.home, distance: AppState.globeDistance)
    }

    func locateMe() {
        location.request()
        if let c = location.coordinate { fly(to: c, distance: 40_000, pitch: 45) }
    }

    // MARK: Selection

    func select(_ e: Entity, flyTo: Bool = true) {
        if flyTo { fly(to: e.coord, distance: e.viewDistance, pitch: e.kind == .place ? 50 : 35) }
        if let idx = nearbyContacts.firstIndex(where: { "ac-\($0.id)" == e.id }) { nearbyIndex = idx }
        if showTimeline {
            focusedEvent = e
            showTimeline = false
            Task { try? await Task.sleep(nanoseconds: 450_000_000); self.selected = e }
        } else {
            selected = e
        }
        if trackedEntityId == e.id { updateTrackingTrail() }
    }

    func tapPoint(_ c: CLLocationCoordinate2D) {
        let d = distance
        Task {
            let r = await reverseGeocode(c)
            select(Entity.place(lat: c.latitude, lon: c.longitude, name: r.title, detail: r.detail, distance: min(max(d * 0.35, 3_000), 600_000)))
        }
    }

    func toggleTracking(_ e: Entity?) {
        guard let e else {
            trackedEntityId = nil
            trackTrail = []
            return
        }
        if trackedEntityId == e.id {
            trackedEntityId = nil
            trackTrail = []
            return
        }
        trackedEntityId = e.id
        trackTrail = [e.coord]
        fly(to: e.coord, distance: max(8_000, min(e.viewDistance * 1.1, 120_000)), pitch: 55, heading: 0)
    }

    func trackSelected() {
        toggleTracking(selected)
    }

    func updateTrackingTrail() {
        guard let e = trackedEntity else { return }
        if trackTrail.last?.distance(to: e.coord) ?? .greatestFiniteMagnitude > 30 {
            trackTrail.append(e.coord)
            if trackTrail.count > 40 { trackTrail.removeFirst(trackTrail.count - 40) }
        }
        fly(to: e.coord, distance: max(7_000, min(e.viewDistance * 1.05, 100_000)), pitch: 60, heading: 0)
    }

    func cycleNearby(forward: Bool) {
        let list = nearbyContacts
        guard !list.isEmpty else { return }
        if forward {
            nearbyIndex = (nearbyIndex + 1) % list.count
        } else {
            nearbyIndex = (nearbyIndex - 1 + list.count) % list.count
        }
        select(Entity.from(list[nearbyIndex]))
    }

    func nearestCamera(to e: Entity) -> CameraFeed? {
        cameras.min { $0.coord.distance(to: e.coord) < $1.coord.distance(to: e.coord) }
    }

    func handoffToNearestCamera() {
        guard let e = selected ?? trackedEntity, let cam = nearestCamera(to: e) else { return }
        select(Entity.from(cam))
    }

    func applyMission(_ m: MissionPreset) {
        switch m {
        case .liveContacts:
            layers = [.flights, .military, .satellites, .cameras]
            showTraffic = true
            if let c = nearbyContacts.first ?? contacts.first { select(Entity.from(c)) }
        case .space:
            layers = [.satellites, .launches]
            if let sat = iss { select(Entity.from(sat)) }
            else if let l = launches.first { select(Entity.from(l)) }
        case .environmental:
            layers = [.quakes, .cameras]
            showTraffic = false
            if let q = quakes.first { select(Entity.from(q)) }
        }
    }

    func shareURL(for entity: Entity?) -> URL? {
        var comps = URLComponents()
        comps.scheme = "godseye"
        comps.host = "view"
        var items: [URLQueryItem] = [
            .init(name: "lat", value: String(format: "%.6f", center.latitude)),
            .init(name: "lon", value: String(format: "%.6f", center.longitude)),
            .init(name: "dist", value: String(format: "%.0f", distance)),
            .init(name: "layers", value: layers.map(\.rawValue).sorted().joined(separator: ",")),
            .init(name: "sensor", value: sensorStyle.rawValue),
            .init(name: "traffic", value: showTraffic ? "1" : "0")
        ]
        if let entity {
            items.append(.init(name: "sel", value: entity.id))
            items.append(.init(name: "title", value: entity.title))
            items.append(.init(name: "slat", value: String(format: "%.6f", entity.lat)))
            items.append(.init(name: "slon", value: String(format: "%.6f", entity.lon)))
        }
        comps.queryItems = items
        return comps.url
    }

    func handleDeepLink(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme == "godseye",
              comps.host == "view",
              let q = comps.queryItems else { return }
        func qv(_ name: String) -> String? { q.first(where: { $0.name == name })?.value }
        if let csv = qv("layers") {
            let set = Set(csv.split(separator: ",").compactMap { Layer(rawValue: String($0)) })
            if !set.isEmpty { layers = set }
        }
        if let traffic = qv("traffic") { showTraffic = (traffic == "1") }
        if let sensor = qv("sensor"), SensorStyle(rawValue: sensor) != nil { sensorStyleRaw = sensor }
        if let la = qv("lat").flatMap(Double.init),
           let lo = qv("lon").flatMap(Double.init),
           let dist = qv("dist").flatMap(Double.init) {
            fly(to: .init(latitude: la, longitude: lo), distance: max(3_000, min(dist, AppState.globeDistance)))
        }
        if let sel = qv("sel") {
            if sel.hasPrefix("ac-"),
               let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == sel }) {
                selected = Entity.from(c)
                return
            }
            if sel.hasPrefix("sat-"),
               let sat = satellites.first(where: { "sat-\($0.id)" == sel }) {
                selected = Entity.from(sat)
                return
            }
            if sel.hasPrefix("ll-"),
               let l = launches.first(where: { "ll-\($0.id)" == sel }) {
                selected = Entity.from(l)
                return
            }
            if let cam = cameras.first(where: { $0.id == sel }) {
                selected = Entity.from(cam)
                return
            }
        }
        if let title = qv("title"),
           let la = qv("slat").flatMap(Double.init),
           let lo = qv("slon").flatMap(Double.init) {
            selected = Entity.place(lat: la, lon: lo, name: title, detail: "Shared target", distance: 20_000)
        }
    }

    func entity(forBookmark b: Bookmark) -> Entity {
        // Prefer live data if the bookmarked thing is still on the globe.
        if b.kind == .aircraft || b.kind == .military, let c = (contacts + militaryContacts).first(where: { "ac-\($0.id)" == b.id }) { return Entity.from(c) }
        if b.kind == .earthquake, let q = quakes.first(where: { "eq-\($0.id)" == b.id }) { return Entity.from(q) }
        if b.kind == .launch, let l = launches.first(where: { "ll-\($0.id)" == b.id }) { return Entity.from(l) }
        if b.kind == .satellite, let s = satellites.first(where: { "sat-\($0.id)" == b.id }) ?? iss { return Entity.from(s) }
        if b.kind == .camera, let cam = cameras.first(where: { $0.id == b.id }) { return Entity.from(cam) }
        return b.entity
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

    // MARK: Cache

    func clearCache() {
        FeedCache.clear()
        cacheBytes = 0
    }
}
