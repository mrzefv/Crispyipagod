import Foundation
import CoreLocation

enum FeedError: Error { case badResponse, offlineNoCache }

// MARK: - Disk cache (last good payload per feed)

enum FeedCache {
    static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feeds", isDirectory: true)
    }
    static func save(_ name: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
    static func load(_ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }
    static func size() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { acc, url in
            acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    static func fileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
    }
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        URLCache.shared.removeAllCachedResponses()
    }
}

// MARK: - Feeds

final class Feeds {
    static let shared = Feeds()
    var offline = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func fetch(_ urlString: String, cache: String) async throws -> Data {
        if offline {
            if let d = FeedCache.load(cache) { return d }
            throw FeedError.offlineNoCache
        }
        guard let url = URL(string: urlString) else { throw FeedError.badResponse }
        do {
            var req = URLRequest(url: url)
            req.setValue("GodsEye-iOS/1.0 (MRzefv)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FeedError.badResponse
            }
            FeedCache.save(cache, data)
            return data
        } catch {
            if let d = FeedCache.load(cache) { return d }
            throw error
        }
    }

    private func optionalFetch(_ url: String, cache: String) async -> Data? {
        try? await fetch(url, cache: cache)
    }

    func contacts(lat: Double, lon: Double, radiusNm: Int = 250) async throws -> [Contact] {
        let la = (lat * 1000).rounded() / 1000
        let lo = (lon * 1000).rounded() / 1000
        let d = try await fetch("https://api.adsb.lol/v2/lat/\(la)/lon/\(lo)/dist/\(radiusNm)", cache: "contacts.json")
        return try JSONDecoder().decode(AdsbResponse.self, from: d).ac.compactMap(\.value)
    }

    func military() async throws -> [Contact] {
        let d = try await fetch("https://api.adsb.lol/v2/mil", cache: "mil.json")
        return try JSONDecoder().decode(AdsbResponse.self, from: d).ac.compactMap(\.value)
    }

    func quakes() async throws -> [Quake] {
        let d = try await fetch("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson", cache: "quakes.json")
        return try JSONDecoder().decode(USGSFeed.self, from: d).features
            .compactMap(\.value).compactMap(Quake.init)
            .sorted { $0.time > $1.time }
    }

    func iss() async throws -> SatPos {
        let d = try await fetch("https://api.wheretheiss.at/v1/satellites/25544", cache: "iss.json")
        let r = try JSONDecoder().decode(ISSResponse.self, from: d)
        return SatPos(id: "25544", name: r.name, lat: r.latitude, lon: r.longitude,
                      altKm: r.altitude, velocityKmh: r.velocity,
                      time: Date(timeIntervalSince1970: r.timestamp))
    }

    func satellites() async throws -> [SGP4] {
        async let a = optionalFetch("https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=json", cache: "gp-stations.json")
        async let b = optionalFetch("https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=json", cache: "gp-visual.json")
        async let c = optionalFetch("https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=json", cache: "gp-weather.json")
        let payloads = await [a, b, c].compactMap { $0 }
        guard !payloads.isEmpty else { throw FeedError.badResponse }
        var seen = Set<Int>()
        var out: [SGP4] = []
        for p in payloads {
            let els = (try? JSONDecoder().decode([Lossy<GPElement>].self, from: p))?.compactMap(\.value) ?? []
            for e in els where !seen.contains(e.NORAD_CAT_ID) {
                if let s = SGP4(e) { seen.insert(e.NORAD_CAT_ID); out.append(s) }
            }
        }
        return out
    }

    func cameras() async throws -> [Camera] {
        let d = try await fetch("https://api.tfl.gov.uk/Place/Type/JamCam", cache: "jamcams.json")
        return try JSONDecoder().decode([Lossy<TfLPlace>].self, from: d).compactMap(\.value).compactMap(Camera.init)
    }

    func launches() async throws -> [Launch] {
        async let up = optionalFetch("https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=15&format=json", cache: "launches-up.json")
        async let prev = optionalFetch("https://ll.thespacedevs.com/2.2.0/launch/previous/?limit=10&format=json", cache: "launches-prev.json")
        let payloads = await [up, prev].compactMap { $0 }
        guard !payloads.isEmpty else { throw FeedError.badResponse }
        var seen = Set<String>()
        var out: [Launch] = []
        for p in payloads {
            let r = try JSONDecoder().decode(LLResponse.self, from: p)
            for l in r.results.compactMap(\.value).compactMap(Launch.init) where !seen.contains(l.id) {
                seen.insert(l.id)
                out.append(l)
            }
        }
        return out.sorted { $0.net < $1.net }
    }
}

// MARK: - Location

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var authorized = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let ok = m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways
        DispatchQueue.main.async { self.authorized = ok }
        if ok { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        DispatchQueue.main.async { self.coordinate = c }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}


// MARK: - AISStream WebSocket

@MainActor
final class AISClient {
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private(set) var connected = false
    var onShip: ((Ship) -> Void)?
    var onStatus: ((String) -> Void)?
    private var apiKey = ""
    private var box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) = (-90, -180, 90, 180)

    func connect(apiKey: String, center: CLLocationCoordinate2D, spanDeg: Double) {
        disconnect()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { onStatus?("AIS: no key"); return }
        self.apiKey = key
        let s = max(2, min(spanDeg, 40))
        box = (max(-90, center.latitude - s), max(-180, center.longitude - s * 1.4), min(90, center.latitude + s), min(180, center.longitude + s * 1.4))
        guard let url = URL(string: "wss://stream.aisstream.io/v0/stream") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        let sub: [String: Any] = [
            "APIKey": key,
            "BoundingBoxes": [[[box.minLat, box.minLon], [box.maxLat, box.maxLon]]],
            "FilterMessageTypes": ["PositionReport"]
        ]
        if let d = try? JSONSerialization.data(withJSONObject: sub), let str = String(data: d, encoding: .utf8) {
            t.send(.string(str)) { [weak self] err in
                Task { @MainActor in
                    if let err { self?.onStatus?("AIS: \(err.localizedDescription)"); self?.connected = false }
                    else { self?.connected = true; self?.onStatus?("AIS: subscribed") }
                }
            }
        }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let t = self?.task else { return }
                do {
                    let msg = try await t.receive()
                    var data: Data?
                    switch msg {
                    case .data(let d): data = d
                    case .string(let s): data = s.data(using: .utf8)
                    @unknown default: break
                    }
                    if let d = data, let ship = AISClient.parse(d) { self?.onShip?(ship) }
                } catch {
                    self?.connected = false
                    self?.onStatus?("AIS: disconnected")
                    return
                }
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    func needsResubscribe(for center: CLLocationCoordinate2D) -> Bool {
        let margin = 1.0
        return center.latitude < box.minLat + margin || center.latitude > box.maxLat - margin ||
               center.longitude < box.minLon + margin || center.longitude > box.maxLon - margin
    }

    nonisolated static func parse(_ d: Data) -> Ship? {
        guard let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (root["MessageType"] as? String) == "PositionReport",
              let meta = root["MetaData"] as? [String: Any],
              let msg = (root["Message"] as? [String: Any])?["PositionReport"] as? [String: Any] else { return nil }
        let mmsiAny = meta["MMSI"]
        let mmsi: String
        if let i = mmsiAny as? Int { mmsi = String(i) } else if let s = mmsiAny as? String { mmsi = s } else { return nil }
        guard let lat = meta["latitude"] as? Double, let lon = meta["longitude"] as? Double else { return nil }
        return Ship(id: mmsi,
                    name: (meta["ShipName"] as? String) ?? "",
                    lat: lat, lon: lon,
                    sogKt: (msg["Sog"] as? Double) ?? 0,
                    cog: (msg["Cog"] as? Double) ?? 0,
                    heading: Double((msg["TrueHeading"] as? Int) ?? 511),
                    navStatus: (msg["NavigationalStatus"] as? Int) ?? 15,
                    seenAt: Date())
    }
}
