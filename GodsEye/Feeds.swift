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

    func quakes(days: Int = 1) async throws -> [Quake] {
        let feed = days >= 30 ? "2.5_month" : days >= 7 ? "all_week" : "all_day"
        let d = try await fetch("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/\(feed).geojson", cache: "quakes-\(feed).json")
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

    // MARK: Public cameras — TfL (London), NYC DOT, Caltrans (12 districts), Austin

    func cameras() async throws -> [Camera] {
        async let tfl = camerasTfL()
        async let nyc = camerasNYC()
        async let ca = camerasCaltrans()
        async let atx = camerasAustin()
        let all = await (tfl + nyc + ca + atx)
        guard !all.isEmpty else { throw FeedError.badResponse }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private func camerasTfL() async -> [Camera] {
        guard let d = try? await fetch("https://api.tfl.gov.uk/Place/Type/JamCam", cache: "cams-tfl.json"),
              let list = try? JSONDecoder().decode([Lossy<TfLPlace>].self, from: d) else { return [] }
        return list.compactMap(\.value).compactMap(Camera.init)
    }

    private func camerasNYC() async -> [Camera] {
        guard let d = try? await fetch("https://webcams.nyctmc.org/api/cameras", cache: "cams-nyc.json"),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            guard let id = c["id"] as? String, let name = c["name"] as? String,
                  let la = (c["latitude"] as? Double) ?? Double(c["latitude"] as? String ?? ""),
                  let lo = (c["longitude"] as? Double) ?? Double(c["longitude"] as? String ?? "") else { return nil }
            let online = ((c["isOnline"] as? String) ?? "\(c["isOnline"] as? Bool ?? true)").lowercased() == "true"
            let img = (c["imageUrl"] as? String) ?? "https://webcams.nyctmc.org/api/cameras/\(id)/image"
            return Camera(id: "nyc-\(id)", name: name, source: "NYC DOT", lat: la, lon: lo, imageURL: img,
                          available: online, region: (c["area"] as? String) ?? "New York")
        }
    }

    private func camerasCaltrans() async -> [Camera] {
        await withTaskGroup(of: [Camera].self) { group in
            for dist in 1...12 {
                group.addTask { [self] in
                    guard let d = try? await self.fetch("https://cwwp2.dot.ca.gov/data/d\(dist)/cctv/cctvStatusD\(String(format: "%02d", dist)).json", cache: "cams-ca-\(dist).json"),
                          let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let data = root["data"] as? [[String: Any]] else { return [] }
                    return data.compactMap { row in
                        guard let c = row["cctv"] as? [String: Any],
                              let loc = c["location"] as? [String: Any],
                              let la = Double(loc["latitude"] as? String ?? ""), let lo = Double(loc["longitude"] as? String ?? ""),
                              let img = c["imageData"] as? [String: Any] else { return nil }
                        let still = (img["static"] as? [String: Any])?["currentImageURL"] as? String ?? ""
                        let stream = img["streamingVideoURL"] as? String
                        guard !still.isEmpty || !(stream ?? "").isEmpty else { return nil }
                        let name = [loc["route"] as? String, loc["locationName"] as? String].compactMap { $0 }.joined(separator: " · ")
                        let idx = (c["index"] as? String) ?? UUID().uuidString
                        return Camera(id: "ca-\(dist)-\(idx)", name: name.isEmpty ? "Caltrans D\(dist)" : name, source: "Caltrans",
                                      lat: la, lon: lo, imageURL: still, videoURL: nil,
                                      streamURL: (stream ?? "").isEmpty ? nil : stream,
                                      available: ((c["inService"] as? String) ?? "true").lowercased() == "true",
                                      heading: Camera.headingFrom(loc["direction"] as? String),
                                      region: (loc["nearbyPlace"] as? String) ?? "California")
                    }
                }
            }
            var out: [Camera] = []
            for await part in group { out += part }
            return out
        }
    }

    private func camerasAustin() async -> [Camera] {
        guard let d = try? await fetch("https://data.austintexas.gov/resource/b4k4-adkb.json?$limit=2000", cache: "cams-atx.json"),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            guard let id = c["camera_id"] as? String else { return nil }
            var la: Double? = Double(c["location_latitude"] as? String ?? ""), lo: Double? = Double(c["location_longitude"] as? String ?? "")
            if la == nil, let loc = c["location"] as? [String: Any], let coords = loc["coordinates"] as? [Double], coords.count >= 2 { lo = coords[0]; la = coords[1] }
            guard let lat = la, let lon = lo else { return nil }
            let img = (c["screenshot_address"] as? String) ?? "https://cctv.austinmobility.io/image/\(id).jpg"
            let status = ((c["camera_status"] as? String) ?? "TURNED_ON").uppercased()
            return Camera(id: "atx-\(id)", name: (c["location_name"] as? String) ?? "Austin cam \(id)", source: "Austin", lat: lat, lon: lon,
                          imageURL: img, available: status.contains("ON") || status.contains("ACTIVE"), region: "Austin")
        }
    }

    // MARK: Flight trace history (globe.adsb.lol trace files, adsbexchange format)

    func trace(hex: String) async throws -> [(coord: CLLocationCoordinate2D, altFt: Int?, time: Date)] {
        let h = hex.lowercased()
        let suffix = String(h.suffix(2))
        let d = try await fetch("https://globe.adsb.lol/data/traces/\(suffix)/trace_full_\(h).json", cache: "trace-\(h).json")
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ts = root["timestamp"] as? Double,
              let rows = root["trace"] as? [[Any]] else { throw FeedError.badResponse }
        var out: [(CLLocationCoordinate2D, Int?, Date)] = []
        for r in rows where r.count >= 3 {
            guard let dt = r[0] as? Double, let la = r[1] as? Double, let lo = r[2] as? Double else { continue }
            let alt = r.count > 3 ? (r[3] as? Int) : nil
            out.append((CLLocationCoordinate2D(latitude: la, longitude: lo), alt, Date(timeIntervalSince1970: ts + dt)))
        }
        return out.map { (coord: $0.0, altFt: $0.1, time: $0.2) }
    }

    // MARK: NASA FIRMS (CSV, key)

    func fires(key: String, center: CLLocationCoordinate2D, spanDeg: Double) async throws -> [Fire] {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw FeedError.badResponse }
        let s = max(3.0, min(spanDeg, 25))
        let w = max(-180, center.longitude - s * 1.3), e = min(180, center.longitude + s * 1.3)
        let so = max(-90, center.latitude - s), n = min(90, center.latitude + s)
        let url = String(format: "https://firms.modaps.eosdis.nasa.gov/api/area/csv/%@/VIIRS_SNPP_NRT/%.2f,%.2f,%.2f,%.2f/1", k, w, so, e, n)
        let d = try await fetch(url, cache: "fires.csv")
        guard let text = String(data: d, encoding: .utf8) else { throw FeedError.badResponse }
        var lines = text.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return [] }
        let header = lines.removeFirst().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        func idx(_ n: String) -> Int? { header.firstIndex(of: n) }
        guard let iLat = idx("latitude"), let iLon = idx("longitude") else { throw FeedError.badResponse }
        let iFrp = idx("frp"), iBr = idx("bright_ti4") ?? idx("brightness"), iConf = idx("confidence"), iDate = idx("acq_date"), iTime = idx("acq_time"), iSat = idx("satellite")
        let df = DateFormatter(); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd HHmm"
        var out: [Fire] = []
        for (n, line) in lines.enumerated() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count > max(iLat, iLon), let la = Double(c[iLat]), let lo = Double(c[iLon]) else { continue }
            let frp = iFrp.flatMap { $0 < c.count ? Double(c[$0]) : nil } ?? 0
            let br = iBr.flatMap { $0 < c.count ? Double(c[$0]) : nil } ?? 0
            let conf = iConf.flatMap { $0 < c.count ? c[$0] : nil } ?? "n"
            var t = Date()
            if let id = iDate, let it = iTime, id < c.count, it < c.count {
                let hhmm = c[it].count < 4 ? String(repeating: "0", count: 4 - c[it].count) + c[it] : c[it]
                t = df.date(from: "\(c[id]) \(hhmm)") ?? t
            }
            let sat = iSat.flatMap { $0 < c.count ? c[$0] : nil } ?? "VIIRS"
            out.append(Fire(id: "\(n)-\(Int(la * 1000))-\(Int(lo * 1000))", lat: la, lon: lo, frp: frp, brightness: br,
                            confidence: conf == "h" ? "high" : conf == "l" ? "low" : conf == "n" ? "nominal" : conf, time: t, satellite: sat))
        }
        return out.sorted { $0.frp > $1.frp }
    }

    // MARK: GBFS bikeshare

    static let gbfsSystems: [GBFSSystem] = [
        GBFSSystem(name: "Citi Bike NYC", lat: 40.73, lon: -73.99, base: "https://gbfs.citibikenyc.com/gbfs/en"),
        GBFSSystem(name: "Divvy Chicago", lat: 41.88, lon: -87.63, base: "https://gbfs.divvybikes.com/gbfs/en"),
        GBFSSystem(name: "Bay Wheels SF", lat: 37.78, lon: -122.42, base: "https://gbfs.baywheels.com/gbfs/en"),
        GBFSSystem(name: "Capital Bikeshare DC", lat: 38.90, lon: -77.03, base: "https://gbfs.capitalbikeshare.com/gbfs/en"),
        GBFSSystem(name: "Bluebikes Boston", lat: 42.36, lon: -71.06, base: "https://gbfs.bluebikes.com/gbfs/en"),
        GBFSSystem(name: "Bike Share Toronto", lat: 43.65, lon: -79.38, base: "https://tor.publicbikesystem.net/ube/gbfs/v1/en"),
        GBFSSystem(name: "BIXI Montréal", lat: 45.51, lon: -73.57, base: "https://gbfs.velobixi.com/gbfs/en"),
        GBFSSystem(name: "Vélib' Paris", lat: 48.86, lon: 2.35, base: "https://velib-metropole-opendata.smovengo.cloud/opendata/Velib_Metropole/gbfs/en"),
        GBFSSystem(name: "Santander Cycles London", lat: 51.51, lon: -0.12, base: "https://gbfs.londoncycles.tfl.gov.uk/gbfs/en"),
        GBFSSystem(name: "Nice Ride Minneapolis", lat: 44.98, lon: -93.27, base: "https://gbfs.niceridemn.com/gbfs/en"),
        GBFSSystem(name: "Metro Bike LA", lat: 34.05, lon: -118.24, base: "https://gbfs.bcycle.com/bcycle_lametro"),
        GBFSSystem(name: "CoGo Columbus", lat: 39.96, lon: -83.00, base: "https://gbfs.cogobikeshare.com/gbfs/en"),
        GBFSSystem(name: "Biki Honolulu", lat: 21.31, lon: -157.86, base: "https://gbfs.bcycle.com/bcycle_honolulu"),
        GBFSSystem(name: "Lyft Denver", lat: 39.74, lon: -104.99, base: "https://gbfs.lyft.com/gbfs/2.3/den/en"),
        GBFSSystem(name: "Lyft Portland (Biketown)", lat: 45.52, lon: -122.68, base: "https://gbfs.biketownpdx.com/gbfs/en"),
        GBFSSystem(name: "Lyft Austin (MetroBike)", lat: 30.27, lon: -97.74, base: "https://gbfs.bcycle.com/bcycle_austin"),
    ]

    func bikeshare(near c: CLLocationCoordinate2D) async throws -> [BikeStation] {
        guard let sys = Feeds.gbfsSystems.min(by: { $0.lat.distanceDeg(to: c, lon: $0.lon) < $1.lat.distanceDeg(to: c, lon: $1.lon) }),
              abs(sys.lat - c.latitude) < 1.5, abs(sys.lon - c.longitude) < 1.5 else { return [] }
        let key = sys.name.replacingOccurrences(of: " ", with: "_")
        async let infoD = fetch("\(sys.base)/station_information.json", cache: "gbfs-info-\(key).json")
        async let statD = optionalFetch("\(sys.base)/station_status.json", cache: "gbfs-status-\(key).json")
        let info = try JSONDecoder().decode(GBFSInfo.self, from: try await infoD).data.stations.compactMap(\.value)
        var status: [String: GBFSStatus.St] = [:]
        if let sd = await statD, let st = try? JSONDecoder().decode(GBFSStatus.self, from: sd) {
            for x in st.data.stations.compactMap(\.value) { status[x.station_id] = x }
        }
        return info.map {
            BikeStation(id: $0.station_id, name: $0.name, lat: $0.lat, lon: $0.lon,
                        bikes: status[$0.station_id]?.num_bikes_available ?? -1,
                        docks: status[$0.station_id]?.num_docks_available ?? -1, system: sys.name)
        }
    }

    // MARK: Radio Browser

    func radio() async throws -> [RadioStation] {
        let d = try await fetch("https://de1.api.radio-browser.info/json/stations/search?has_geo_info=true&hidebroken=true&order=clickcount&reverse=true&limit=750", cache: "radio.json")
        return try JSONDecoder().decode([Lossy<RadioStation>].self, from: d).compactMap(\.value)
            .filter { $0.geo_lat != nil && $0.geo_long != nil && !$0.url_resolved.isEmpty }
    }

    // MARK: Overpass (infra + airport)

    private func overpass(_ query: String, cache: String) async throws -> OverpassResponse {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { throw FeedError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("GodsEye-iOS/1.1 (MRzefv)", forHTTPHeaderField: "User-Agent")
        req.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)).data(using: .utf8)
        req.timeoutInterval = 25
        if offline, let d = FeedCache.load(cache) { return try JSONDecoder().decode(OverpassResponse.self, from: d) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw FeedError.badResponse }
        FeedCache.save(cache, data)
        return try JSONDecoder().decode(OverpassResponse.self, from: data)
    }

    func infrastructure(center c: CLLocationCoordinate2D, spanDeg: Double) async throws -> [InfraNode] {
        let s = max(0.3, min(spanDeg, 2.5))
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", c.latitude - s, c.longitude - s * 1.3, c.latitude + s, c.longitude + s * 1.3)
        let q = """
        [out:json][timeout:20];(
          nwr["telecom"="data_center"](\(bbox));
          nwr["waterway"="dam"](\(bbox));
          nwr["power"="plant"](\(bbox));
          nwr["power"="substation"]["voltage"](\(bbox));
        );out center tags 400;
        """
        let r = try await overpass(q, cache: "infra.json")
        return r.elements.compactMap(\.value).compactMap { e in
            guard let la = e.lat ?? e.center?.lat, let lo = e.lon ?? e.center?.lon, let t = e.tags else { return nil }
            let kind: InfraNode.Kind
            if t["telecom"] == "data_center" { kind = .datacenter }
            else if t["waterway"] == "dam" { kind = .dam }
            else if t["power"] == "plant" { kind = .power }
            else if t["power"] == "substation" { kind = .substation }
            else { return nil }
            return InfraNode(id: "\(e.type)-\(e.id)", kind: kind, name: t["name"] ?? t["operator"] ?? kind.label.capitalized, lat: la, lon: lo, tags: t)
        }
    }

    func airport(center c: CLLocationCoordinate2D) async throws -> [AirportFeature] {
        let s = 0.03
        let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", c.latitude - s, c.longitude - s * 1.4, c.latitude + s, c.longitude + s * 1.4)
        let q = """
        [out:json][timeout:20];(
          way["aeroway"~"^(runway|taxiway|apron|terminal)$"](\(bbox));
        );out geom 600;
        """
        let r = try await overpass(q, cache: "airport.json")
        return r.elements.compactMap(\.value).compactMap { e in
            guard let g = e.geometry, g.count > 1, let a = e.tags?["aeroway"] else { return nil }
            let kind: AirportFeature.Kind
            switch a { case "runway": kind = .runway; case "taxiway": kind = .taxiway; case "apron": kind = .apron; default: kind = .terminal }
            return AirportFeature(id: "\(e.type)-\(e.id)", kind: kind, name: e.tags?["ref"] ?? e.tags?["name"] ?? a,
                                  points: g.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
    }

    // MARK: Submarine cables

    func cables() async throws -> [Cable] {
        let d = try await fetch("https://www.submarinecablemap.com/api/v3/cable/cable-geo.json", cache: "cables.json")
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let feats = root["features"] as? [[String: Any]] else { throw FeedError.badResponse }
        var out: [Cable] = []
        for f in feats {
            guard let props = f["properties"] as? [String: Any], let geom = f["geometry"] as? [String: Any],
                  let id = props["id"] as? String, let name = props["name"] as? String else { continue }
            var segs: [[CLLocationCoordinate2D]] = []
            if (geom["type"] as? String) == "MultiLineString", let lines = geom["coordinates"] as? [[[Double]]] {
                for l in lines { segs.append(Feeds.decimate(l.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil })) }
            } else if (geom["type"] as? String) == "LineString", let l = geom["coordinates"] as? [[Double]] {
                segs.append(Feeds.decimate(l.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }))
            }
            segs = segs.filter { $0.count > 1 }
            guard !segs.isEmpty else { continue }
            let all = segs.flatMap { $0 }
            out.append(Cable(id: id, name: name, color: (props["color"] as? String) ?? "#8888ff", segments: segs,
                             minLat: all.map(\.latitude).min() ?? 0, maxLat: all.map(\.latitude).max() ?? 0,
                             minLon: all.map(\.longitude).min() ?? 0, maxLon: all.map(\.longitude).max() ?? 0))
        }
        return out
    }

    private static func decimate(_ pts: [CLLocationCoordinate2D], keepEvery n: Int = 3) -> [CLLocationCoordinate2D] {
        guard pts.count > 40 else { return pts }
        var out: [CLLocationCoordinate2D] = []
        for (i, p) in pts.enumerated() where i % n == 0 || i == pts.count - 1 { out.append(p) }
        return out
    }

    // MARK: Open-Meteo (keyless)

    func weather(at c: CLLocationCoordinate2D) async throws -> Weather {
        let url = String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&current=temperature_2m,wind_speed_10m,wind_direction_10m,cloud_cover,visibility&wind_speed_unit=kn", c.latitude, c.longitude)
        let d = try await fetch(url, cache: "wx.json")
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any], let cur = root["current"] as? [String: Any] else { throw FeedError.badResponse }
        return Weather(tempC: cur["temperature_2m"] as? Double ?? 0, windKt: cur["wind_speed_10m"] as? Double ?? 0,
                       windDir: cur["wind_direction_10m"] as? Double ?? 0, cloudPct: cur["cloud_cover"] as? Double ?? 0,
                       visibilityM: cur["visibility"] as? Double ?? 0, fetched: Date())
    }

    // MARK: Nominatim boundary polygons (keyless)

    func boundary(named name: String) async throws -> [[CLLocationCoordinate2D]] {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let d = try await fetch("https://nominatim.openstreetmap.org/search?q=\(q)&polygon_geojson=1&format=json&limit=1", cache: "boundary.json")
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]], let first = arr.first,
              let geo = first["geojson"] as? [String: Any], let type = geo["type"] as? String else { throw FeedError.badResponse }
        var rings: [[CLLocationCoordinate2D]] = []
        func ring(_ r: [[Double]]) -> [CLLocationCoordinate2D] { Feeds.decimate(r.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }, keepEvery: 4) }
        if type == "Polygon", let c = geo["coordinates"] as? [[[Double]]], let outer = c.first { rings.append(ring(outer)) }
        else if type == "MultiPolygon", let c = geo["coordinates"] as? [[[[Double]]]] {
            for poly in c { if let outer = poly.first { rings.append(ring(outer)) } }
            rings.sort { $0.count > $1.count }
            rings = Array(rings.prefix(6))
        }
        guard !rings.isEmpty else { throw FeedError.badResponse }
        return rings
    }

    // MARK: Nominatim parcel/address/owner search (keyless)

    func parcelRecords(query: String, near center: CLLocationCoordinate2D, limit: Int = 10) async throws -> [ParcelRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let west = center.longitude - 1.2
        let east = center.longitude + 1.2
        let south = center.latitude - 1.0
        let north = center.latitude + 1.0
        let viewbox = String(format: "%.5f,%.5f,%.5f,%.5f", west, north, east, south)
        let key = q.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let latKey = String(format: "%.2f", center.latitude)
        let lonKey = String(format: "%.2f", center.longitude)
        let cacheKey = "parcel-\(String(key.prefix(40)).ifEmpty("search"))-\(latKey)-\(lonKey).json"
        let url = "https://nominatim.openstreetmap.org/search?q=\(enc)&format=jsonv2&addressdetails=1&extratags=1&limit=\(max(1, min(limit, 30)))&viewbox=\(viewbox)&bounded=0"
        let d = try await fetch(url, cache: cacheKey)
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw FeedError.badResponse }
        return arr.compactMap { row in
            guard let la = row["lat"] as? String, let lo = row["lon"] as? String,
                  let lat = Double(la), let lon = Double(lo) else { return nil }
            let display = row["display_name"] as? String ?? "Unknown address"
            let name = row["name"] as? String
            let ext = row["extratags"] as? [String: Any]
            let addr = row["address"] as? [String: Any]
            let osmType = (row["osm_type"] as? String ?? "?").uppercased()
            let osmID = String(describing: row["osm_id"] ?? "")
            let parcelID = "\(osmType.prefix(1))\(osmID)"
            let house = (addr?["house_number"] as? String).ifEmpty(name ?? "")
            let road = (addr?["road"] as? String).ifEmpty(addr?["pedestrian"] as? String ?? "")
            let fallbackTitle = [house, road].filter { !$0.isEmpty }.joined(separator: " ")
            let owner = (ext?["owner"] as? String).ifEmpty((ext?["operator"] as? String).ifEmpty(ext?["contact:person"] as? String ?? ""))
            return ParcelRecord(
                id: parcelID.isEmpty ? "parcel-\(lat)-\(lon)" : parcelID,
                parcelID: parcelID.ifEmpty("—"),
                title: (name ?? "").ifEmpty(fallbackTitle.ifEmpty(display.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "Property record")),
                address: display,
                owner: owner.isEmpty ? nil : owner,
                lat: lat,
                lon: lon
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: Anthropic HUD summary (user key)

    func aiSummary(key: String, model: String, context: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw FeedError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model, "max_tokens": 40,
            "system": "You are a terse intelligence HUD. Reply with exactly five uppercase words summarizing the current view. No punctuation, no preamble.",
            "messages": [["role": "user", "content": context]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else { throw FeedError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: RainViewer radar / satellite frames

    func radarFrames() async throws -> [RadarFrame] {
        let d = try await fetch("https://api.rainviewer.com/public/weather-maps.json", cache: "rainviewer.json")
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw FeedError.badResponse }
        var out: [RadarFrame] = []
        if let radar = root["radar"] as? [String: Any] {
            for key in ["past", "nowcast"] {
                for fr in (radar[key] as? [[String: Any]]) ?? [] {
                    if let t = fr["time"] as? Double, let p = fr["path"] as? String { out.append(RadarFrame(time: Date(timeIntervalSince1970: t), path: p, kind: "radar")) }
                }
            }
        }
        if let sat = root["satellite"] as? [String: Any] {
            for fr in (sat["infrared"] as? [[String: Any]]) ?? [] {
                if let t = fr["time"] as? Double, let p = fr["path"] as? String { out.append(RadarFrame(time: Date(timeIntervalSince1970: t), path: p, kind: "satellite")) }
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    nonisolated static func tileURL(_ frame: RadarFrame, z: Int, x: Int, y: Int) -> URL? {
        if frame.kind == "radar" { return URL(string: "https://tilecache.rainviewer.com\(frame.path)/256/\(z)/\(x)/\(y)/2/1_1.png") }
        return URL(string: "https://tilecache.rainviewer.com\(frame.path)/256/\(z)/\(x)/\(y)/0/0_0.png")
    }

    // MARK: Open-Meteo wind grid + elevation

    func windGrid(center c: CLLocationCoordinate2D, spanDeg: Double, n: Int = 7) async throws -> [WindVector] {
        var lats: [String] = [], lons: [String] = []
        for i in 0..<n { for j in 0..<n {
            lats.append(String(format: "%.2f", c.latitude - spanDeg + 2 * spanDeg * Double(i) / Double(n - 1)))
            lons.append(String(format: "%.2f", c.longitude - spanDeg * 1.4 + 2.8 * spanDeg * Double(j) / Double(n - 1)))
        } }
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lats.joined(separator: ","))&longitude=\(lons.joined(separator: ","))&current=wind_speed_10m,wind_direction_10m&wind_speed_unit=kn"
        let d = try await fetch(url, cache: "wind.json")
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw FeedError.badResponse }
        return arr.enumerated().compactMap { i, e in
            guard let la = e["latitude"] as? Double, let lo = e["longitude"] as? Double, let cur = e["current"] as? [String: Any] else { return nil }
            return WindVector(id: "w\(i)", lat: la, lon: lo, speedKt: cur["wind_speed_10m"] as? Double ?? 0, dirDeg: cur["wind_direction_10m"] as? Double ?? 0)
        }
    }

    func elevations(_ pts: [CLLocationCoordinate2D]) async throws -> [Double] {
        var out: [Double] = []
        for chunk in stride(from: 0, to: pts.count, by: 100).map({ Array(pts[$0..<min($0 + 100, pts.count)]) }) {
            let la = chunk.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")
            let lo = chunk.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")
            let d = try await fetch("https://api.open-meteo.com/v1/elevation?latitude=\(la)&longitude=\(lo)", cache: "elev-\(chunk.count)-\(String(la.prefix(24)).replacingOccurrences(of: ",", with: "_")).json")
            guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any], let e = root["elevation"] as? [Double] else { throw FeedError.badResponse }
            out += e
        }
        return out
    }

    // MARK: Overpass: power grid, rail, peaks

    func powerGrid(center c: CLLocationCoordinate2D, spanDeg: Double) async throws -> ([PowerLine], [InfraNode]) {
        let s = max(0.15, min(spanDeg, 1.2))
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", c.latitude - s, c.longitude - s * 1.3, c.latitude + s, c.longitude + s * 1.3)
        let q = """
        [out:json][timeout:25];(
          way["power"="line"](\(bbox));
          nwr["power"~"^(plant|substation)$"](\(bbox));
        );out center geom tags 700;
        """
        let r = try await overpass(q, cache: "power.json")
        var lines: [PowerLine] = []
        var nodes: [InfraNode] = []
        for e in r.elements.compactMap(\.value) {
            let t = e.tags ?? [:]
            if e.type == "way", t["power"] == "line", let g = e.geometry, g.count > 1 {
                let v = Double((t["voltage"] ?? "0").split(separator: ";").first.map(String.init) ?? "0") ?? 0
                lines.append(PowerLine(id: "way-\(e.id)", voltage: v, name: t["name"] ?? t["ref"] ?? "Transmission line", operatorName: t["operator"] ?? "—",
                                       points: g.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }))
            } else if let la = e.lat ?? e.center?.lat, let lo = e.lon ?? e.center?.lon {
                let kind: InfraNode.Kind = t["power"] == "plant" ? .power : .substation
                nodes.append(InfraNode(id: "\(e.type)-\(e.id)", kind: kind, name: t["name"] ?? t["operator"] ?? kind.label.capitalized, lat: la, lon: lo, tags: t))
            }
        }
        return (lines, nodes)
    }

    func rail(center c: CLLocationCoordinate2D, spanDeg: Double) async throws -> ([RailLine], [RailStation]) {
        let s = max(0.1, min(spanDeg, 0.8))
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", c.latitude - s, c.longitude - s * 1.3, c.latitude + s, c.longitude + s * 1.3)
        let q = """
        [out:json][timeout:25];(
          way["railway"~"^(rail|subway|light_rail|tram)$"]["service"!~"yard|siding|spur|crossover"](\(bbox));
          way["railway"="rail"]["service"="yard"](\(bbox));
          nwr["railway"~"^(station|halt)$"](\(bbox));
        );out center geom tags 900;
        """
        let r = try await overpass(q, cache: "rail.json")
        var lines: [RailLine] = []
        var stations: [RailStation] = []
        for e in r.elements.compactMap(\.value) {
            let t = e.tags ?? [:]
            if e.type == "way", let g = e.geometry, g.count > 1, let rw = t["railway"], rw != "station" {
                let kind = t["service"] == "yard" ? "yard" : rw
                lines.append(RailLine(id: "way-\(e.id)", kind: kind, name: t["name"] ?? t["ref"] ?? kind, points: g.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }))
            } else if let la = e.lat ?? e.center?.lat, let lo = e.lon ?? e.center?.lon, ["station", "halt"].contains(t["railway"] ?? "") {
                stations.append(RailStation(id: "\(e.type)-\(e.id)", name: t["name"] ?? "Station", lat: la, lon: lo, kind: t["station"] ?? t["railway"] ?? "station"))
            }
        }
        return (lines, stations)
    }

    func peaks(center c: CLLocationCoordinate2D, spanDeg: Double) async throws -> [Peak] {
        let s = max(0.1, min(spanDeg, 1.5))
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", c.latitude - s, c.longitude - s * 1.3, c.latitude + s, c.longitude + s * 1.3)
        let q = "[out:json][timeout:20];node[\"natural\"=\"peak\"][\"ele\"](\(bbox));out tags 300;"
        let r = try await overpass(q, cache: "peaks.json")
        return r.elements.compactMap(\.value).compactMap { e in
            guard let la = e.lat, let lo = e.lon, let t = e.tags, let ele = Double((t["ele"] ?? "").replacingOccurrences(of: " m", with: "")) else { return nil }
            return Peak(id: "\(e.id)", name: t["name"] ?? "Peak", lat: la, lon: lo, elevationM: ele)
        }.sorted { $0.elevationM > $1.elevationM }
    }

    // MARK: Live trains

    func trains() async -> [Train] {
        async let a = amtrak()
        async let b = digitraffic()
        return await a + b
    }

    private func amtrak() async -> [Train] {
        guard let d = try? await fetch("https://api-v3.amtraker.com/v3/trains", cache: "amtrak.json"),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        var out: [Train] = []
        for (_, v) in root {
            for t in (v as? [[String: Any]]) ?? [] {
                guard let la = t["lat"] as? Double, let lo = t["lon"] as? Double else { continue }
                let num = "\(t["trainNum"] ?? "")"
                let name = (t["routeName"] as? String) ?? "Amtrak \(num)"
                let stations = t["stations"] as? [[String: Any]] ?? []
                let next = stations.first(where: { ($0["status"] as? String) == "Enroute" })?["name"] as? String ?? stations.last?["name"] as? String ?? "—"
                out.append(Train(id: "amtk-\(t["trainID"] ?? num)", name: "\(name) #\(num)", operatorName: "Amtrak", lat: la, lon: lo,
                                 speedKmh: ((t["velocity"] as? Double) ?? 0) * 1.609, heading: Train.heading(from: t["heading"] as? String),
                                 status: (t["trainState"] as? String) ?? "Active", nextStop: next, seenAt: Date()))
            }
        }
        return out
    }

    private func digitraffic() async -> [Train] {
        guard let d = try? await fetch("https://rata.digitraffic.fi/api/v1/train-locations/latest", cache: "digitraffic.json"),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard let loc = t["location"] as? [String: Any], let c = loc["coordinates"] as? [Double], c.count >= 2 else { return nil }
            let num = "\(t["trainNumber"] ?? "")"
            return Train(id: "vr-\(num)-\(t["departureDate"] ?? "")", name: "VR \(num)", operatorName: "VR (Finland)", lat: c[1], lon: c[0],
                         speedKmh: (t["speed"] as? Double) ?? 0, heading: 0, status: "Active", nextStop: "—", seenAt: Date())
        }
    }

    // MARK: Airports (OurAirports, medium+large only)

    func airports() async throws -> [Airport] {
        let d = try await fetch("https://davidmegginson.github.io/ourairports-data/airports.csv", cache: "airports.csv")
        guard let text = String(data: d, encoding: .utf8) else { throw FeedError.badResponse }
        var out: [Airport] = []
        out.reserveCapacity(5000)
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if first { first = false; continue }
            guard line.contains("large_airport") || line.contains("medium_airport") else { continue }
            let c = Feeds.csvSplit(String(line))
            guard c.count > 13, let la = Double(c[4]), let lo = Double(c[5]) else { continue }
            out.append(Airport(id: c[1], iata: c[13], name: c[3], type: c[2], lat: la, lon: lo, elevationFt: Double(c[6]) ?? 0, city: c[10], country: c[8]))
        }
        return out
    }

    nonisolated static func csvSplit(_ line: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    // MARK: METAR + NDBC buoys

    func metars(center c: CLLocationCoordinate2D, spanDeg: Double) async throws -> [WxStation] {
        let s = max(1.0, min(spanDeg, 8))
        let bbox = String(format: "%.2f,%.2f,%.2f,%.2f", c.latitude - s, c.longitude - s * 1.4, c.latitude + s, c.longitude + s * 1.4)
        let d = try await fetch("https://aviationweather.gov/api/data/metar?bbox=\(bbox)&format=json", cache: "metar.json")
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw FeedError.badResponse }
        return arr.compactMap { m in
            guard let id = m["icaoId"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { return nil }
            let temp = m["temp"] as? Double
            let alt = m["altim"] as? Double
            let t = (m["obsTime"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return WxStation(id: id, name: (m["name"] as? String) ?? id, kind: "METAR", lat: la, lon: lo, tempC: temp,
                             windDir: (m["wdir"] as? Double) ?? Double("\(m["wdir"] ?? "")"), windKt: (m["wspd"] as? Double),
                             pressureHpa: alt, visibilityMi: (m["visib"] as? Double) ?? Double("\(m["visib"] ?? "")".replacingOccurrences(of: "+", with: "")),
                             raw: (m["rawOb"] as? String) ?? "", time: t)
        }
    }

    func buoys() async throws -> [WxStation] {
        let d = try await fetch("https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt", cache: "ndbc.txt")
        guard let text = String(data: d, encoding: .utf8) else { throw FeedError.badResponse }
        var out: [WxStation] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard c.count > 14, let la = Double(c[1]), let lo = Double(c[2]) else { continue }
            func v(_ i: Int) -> Double? { c.count > i && c[i] != "MM" ? Double(c[i]) : nil }
            out.append(WxStation(id: c[0], name: "Buoy \(c[0])", kind: "BUOY", lat: la, lon: lo, tempC: v(14), windDir: v(8), windKt: v(9).map { $0 * 1.944 },
                                 pressureHpa: v(12), visibilityMi: nil, raw: line.trimmingCharacters(in: .whitespaces), time: nil))
        }
        return out
    }

    func stationHistory(at c: CLLocationCoordinate2D) async throws -> [(Date, Double, Double, Double)] {
        let url = String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&hourly=temperature_2m,wind_speed_10m,surface_pressure&past_days=1&forecast_days=1&wind_speed_unit=kn&timezone=UTC", c.latitude, c.longitude)
        let d = try await fetch(url, cache: "wxhist.json")
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any], let h = root["hourly"] as? [String: Any],
              let times = h["time"] as? [String], let temps = h["temperature_2m"] as? [Double?], let winds = h["wind_speed_10m"] as? [Double?], let press = h["surface_pressure"] as? [Double?] else { throw FeedError.badResponse }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm"; df.timeZone = TimeZone(identifier: "UTC")
        var out: [(Date, Double, Double, Double)] = []
        for i in 0..<min(times.count, temps.count, winds.count, press.count) {
            guard let t = df.date(from: times[i]), let tv = temps[i], let wv = winds[i], let pv = press[i] else { continue }
            out.append((t, tv, wv, pv))
        }
        return out
    }

    // MARK: NWS alerts + Cal Fire incidents

    func nwsAlerts() async throws -> [HazardAlert] {
        let d = try await fetch("https://api.weather.gov/alerts/active?status=actual&message_type=alert&limit=500", cache: "nws.json")
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any], let feats = root["features"] as? [[String: Any]] else { throw FeedError.badResponse }
        let iso = ISO8601DateFormatter()
        return feats.compactMap { f in
            guard let p = f["properties"] as? [String: Any], let id = p["id"] as? String else { return nil }
            var rings: [[CLLocationCoordinate2D]] = []
            if let g = f["geometry"] as? [String: Any], let type = g["type"] as? String {
                if type == "Polygon", let c = g["coordinates"] as? [[[Double]]], let o = c.first { rings = [o.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }] }
                else if type == "MultiPolygon", let c = g["coordinates"] as? [[[[Double]]]] { rings = c.compactMap { $0.first?.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil } } }
            }
            let all = rings.flatMap { $0 }
            guard !all.isEmpty else { return nil }    // zone-only alerts have no geometry; skip
            let la = all.map(\.latitude).reduce(0, +) / Double(all.count), lo = all.map(\.longitude).reduce(0, +) / Double(all.count)
            return HazardAlert(id: id, source: "NWS", event: (p["event"] as? String) ?? "Alert", headline: (p["headline"] as? String) ?? "",
                               severity: (p["severity"] as? String) ?? "Unknown", area: (p["areaDesc"] as? String) ?? "",
                               starts: (p["onset"] as? String).flatMap { iso.date(from: $0) }, ends: (p["ends"] as? String).flatMap { iso.date(from: $0) } ?? (p["expires"] as? String).flatMap { iso.date(from: $0) },
                               lat: la, lon: lo, rings: rings, url: id)
        }
    }

    func calFire() async throws -> [HazardAlert] {
        let d = try await fetch("https://incidents.fire.ca.gov/umbraco/api/IncidentApi/List?inactive=false", cache: "calfire.json")
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw FeedError.badResponse }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return arr.compactMap { i in
            guard let name = i["Name"] as? String, let la = i["Latitude"] as? Double, let lo = i["Longitude"] as? Double else { return nil }
            let acres = (i["AcresBurned"] as? Double) ?? 0
            let cont = (i["PercentContained"] as? Double) ?? 0
            return HazardAlert(id: "calfire-\(i["UniqueId"] ?? name)", source: "Cal Fire", event: "Wildfire · \(name)",
                               headline: String(format: "%.0f acres · %.0f%% contained · %@", acres, cont, (i["Location"] as? String) ?? ""),
                               severity: acres > 10_000 ? "Extreme" : acres > 1_000 ? "Severe" : "Moderate", area: (i["County"] as? String) ?? "California",
                               starts: (i["Started"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }, ends: nil,
                               lat: la, lon: lo, rings: [], url: i["Url"] as? String)
        }
    }

    // MARK: Broadcastify top feeds (HTML, no API key)

    func scannerFeeds() async throws -> [ScannerFeed] {
        let d = try await fetch("https://www.broadcastify.com/listen/top", cache: "scanner.html")
        guard let html = String(data: d, encoding: .utf8) else { throw FeedError.badResponse }
        let re = try NSRegularExpression(pattern: #"/listen/feed/(\d+)"[^>]*>([^<]{3,120})<"#)
        let listRe = try NSRegularExpression(pattern: #"(\d+)\s*(?:listeners|Listeners)"#)
        var out: [ScannerFeed] = []
        var seen = Set<String>()
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            var title = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.replacingOccurrences(of: "&amp;", with: "&")
            guard seen.insert(id).inserted, !title.isEmpty else { continue }
            let tail = ns.substring(with: NSRange(location: m.range.location, length: min(600, ns.length - m.range.location)))
            var listeners = 0
            if let lm = listRe.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) { listeners = Int((tail as NSString).substring(with: lm.range(at: 1))) ?? 0 }
            let genre = title.lowercased().contains("fire") ? "Fire/EMS" : title.lowercased().contains("police") || title.lowercased().contains("sheriff") ? "Police" : "Public Safety"
            out.append(ScannerFeed(id: id, title: title, genre: genre, lat: 0, lon: 0, listeners: listeners))
            if out.count >= 60 { break }
        }
        guard !out.isEmpty else { throw FeedError.badResponse }
        return out
    }

    // MARK: NOAA SWPC space weather

    func spaceWeather() async -> SpaceWeather {
        var sw = SpaceWeather()
        if let d = try? await fetch("https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json", cache: "kp.json"),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[Any]], let last = arr.last, last.count > 1 {
            sw.kp = Double("\(last[1])") ?? 0
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; df.timeZone = TimeZone(identifier: "UTC")
            sw.kpTime = df.date(from: "\(last[0])")
        }
        if let d = try? await fetch("https://services.swpc.noaa.gov/products/solar-wind/plasma-2-hour.json", cache: "plasma.json"),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[Any]], let last = arr.last(where: { $0.count > 2 && "\($0[2])" != "<null>" }) {
            sw.density = Double("\(last[1])") ?? 0
            sw.solarWindKmS = Double("\(last[2])") ?? 0
        }
        if let d = try? await fetch("https://services.swpc.noaa.gov/json/goes/primary/xrays-6-hour.json", cache: "xray.json"),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], let last = arr.last(where: { ($0["energy"] as? String) == "0.1-0.8nm" }) {
            let flux = (last["flux"] as? Double) ?? 0
            sw.xrayFlux = flux
            sw.xrayClass = flux >= 1e-4 ? String(format: "X%.1f", flux / 1e-4) : flux >= 1e-5 ? String(format: "M%.1f", flux / 1e-5) : flux >= 1e-6 ? String(format: "C%.1f", flux / 1e-6) : flux >= 1e-7 ? String(format: "B%.1f", flux / 1e-7) : "A"
        }
        if let d = try? await fetch("https://services.swpc.noaa.gov/json/ovation_aurora_latest.json", cache: "aurora.json"),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let coords = root["coordinates"] as? [[Double]] {
            sw.aurora = coords.compactMap { c in
                guard c.count >= 3, c[2] >= 15, Int(c[0]) % 4 == 0, Int(c[1]) % 2 == 0 else { return nil }
                return (lat: c[1], lon: c[0] > 180 ? c[0] - 360 : c[0], prob: c[2])
            }
        }
        sw.fetched = Date()
        return sw
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


extension Train {
    static func heading(from s: String?) -> Double { Camera.headingFrom(s) ?? 0 }
}

private extension Double {
    func distanceDeg(to c: CLLocationCoordinate2D, lon: Double) -> Double {
        let dl = self - c.latitude, dn = lon - c.longitude
        return dl * dl + dn * dn
    }
}
