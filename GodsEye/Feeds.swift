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
    private let satelliteCatalog: [(id: String, name: String)] = [
        ("25544", "ISS"),
        ("20580", "Hubble"),
        ("43013", "NOAA 20"),
        ("40069", "AISSat-1")
    ]

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
                      time: Date(timeIntervalSince1970: r.timestamp), source: "wheretheiss.at")
    }

    func satellites() async throws -> [SatPos] {
        var out: [SatPos] = []
        for sat in satelliteCatalog {
            let cache = "sat-\(sat.id).json"
            do {
                let d = try await fetch("https://api.wheretheiss.at/v1/satellites/\(sat.id)", cache: cache)
                let r = try JSONDecoder().decode(ISSResponse.self, from: d)
                out.append(SatPos(
                    id: sat.id,
                    name: r.name.isEmpty ? sat.name : r.name,
                    lat: r.latitude,
                    lon: r.longitude,
                    altKm: r.altitude,
                    velocityKmh: r.velocity,
                    time: Date(timeIntervalSince1970: r.timestamp),
                    source: "wheretheiss.at"
                ))
            } catch {
                if sat.id == "25544", let iss = try? await iss() {
                    out.append(iss)
                }
            }
        }
        guard !out.isEmpty else { throw FeedError.badResponse }
        return out
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
