import Foundation
import CoreLocation
import SwiftUI

// MARK: - Layers

enum Layer: String, CaseIterable, Identifiable, Codable {
    case flights, military, satellites, quakes, launches, cameras
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flights: return "Live Flights"
        case .military: return "Military Traffic"
        case .satellites: return "Satellites (ISS)"
        case .quakes: return "Earthquakes (24h)"
        case .launches: return "Space Missions"
        case .cameras: return "Public Cameras"
        }
    }
    var icon: String {
        switch self {
        case .flights: return "airplane"
        case .military: return "shield.lefthalf.filled"
        case .satellites: return "sparkle"
        case .quakes: return "waveform.path.ecg"
        case .launches: return "flame"
        case .cameras: return "video"
        }
    }
    var source: String {
        switch self {
        case .flights: return "adsb.lol"
        case .military: return "adsb.lol /mil"
        case .satellites: return "wheretheiss.at"
        case .quakes: return "USGS"
        case .launches: return "Launch Library 2"
        case .cameras: return "Public city camera portals"
        }
    }
}

// MARK: - Lossy decoding (one bad record never kills the feed)

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct FlexDouble: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = Double(s) }
        else { value = nil }
    }
}

// MARK: - Aircraft (adsb.lol v2)

struct Contact: Identifiable, Decodable, Equatable {
    let id: String
    let callsign: String
    let lat: Double
    let lon: Double
    let altFt: Int?
    let onGround: Bool
    let groundSpeedKt: Double?
    let track: Double
    let type: String?
    let registration: String?
    let squawk: String?
    let military: Bool
    let seenAt: Date

    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var displayName: String { callsign.isEmpty ? id.uppercased() : callsign }

    enum Keys: String, CodingKey { case hex, flight, lat, lon, alt_baro, gs, track, t, r, squawk, dbFlags }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .hex)
        callsign = ((try? c.decode(String.self, forKey: .flight)) ?? "").trimmingCharacters(in: .whitespaces)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        if let a = try? c.decode(Int.self, forKey: .alt_baro) { altFt = a; onGround = false }
        else if let a = try? c.decode(Double.self, forKey: .alt_baro) { altFt = Int(a); onGround = false }
        else if let s = try? c.decode(String.self, forKey: .alt_baro), s == "ground" { altFt = 0; onGround = true }
        else { altFt = nil; onGround = false }
        groundSpeedKt = try? c.decode(Double.self, forKey: .gs)
        track = (try? c.decode(Double.self, forKey: .track)) ?? 0
        type = try? c.decode(String.self, forKey: .t)
        registration = try? c.decode(String.self, forKey: .r)
        squawk = try? c.decode(String.self, forKey: .squawk)
        let flags = (try? c.decode(Int.self, forKey: .dbFlags)) ?? 0
        military = (flags & 1) == 1
        seenAt = Date()
    }
}

struct AdsbResponse: Decodable { let ac: [Lossy<Contact>] }

// MARK: - Earthquakes (USGS GeoJSON)

struct USGSFeed: Decodable { let features: [Lossy<QuakeFeature>] }
struct QuakeFeature: Decodable {
    let id: String
    let properties: Props
    let geometry: Geom
    struct Props: Decodable { let mag: Double?; let place: String?; let time: Double; let url: String? }
    struct Geom: Decodable { let coordinates: [Double] }
}

struct Quake: Identifiable, Equatable {
    let id: String
    let mag: Double
    let place: String
    let time: Date
    let lat: Double
    let lon: Double
    let depthKm: Double
    let url: String?
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init?(_ f: QuakeFeature) {
        guard f.geometry.coordinates.count >= 2 else { return nil }
        id = f.id
        mag = f.properties.mag ?? 0
        place = f.properties.place ?? "Unknown region"
        time = Date(timeIntervalSince1970: f.properties.time / 1000)
        lon = f.geometry.coordinates[0]
        lat = f.geometry.coordinates[1]
        depthKm = f.geometry.coordinates.count > 2 ? f.geometry.coordinates[2] : 0
        url = f.properties.url
    }

    var color: Color {
        switch mag {
        case ..<3: return .yellow
        case ..<5: return .orange
        default: return .red
        }
    }
}

// MARK: - ISS

struct ISSResponse: Decodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let velocity: Double
    let timestamp: Double
}

struct SatPos: Identifiable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let altKm: Double
    let velocityKmh: Double
    let time: Date
    let source: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var isISS: Bool { id == "25544" }
}

struct CameraFeed: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let city: String
    let lat: Double
    let lon: Double
    let provider: String
    let url: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    static let defaults: [CameraFeed] = [
        .init(id: "cam-nyc-times", name: "Times Sq", city: "New York", lat: 40.7580, lon: -73.9855, provider: "EarthCam", url: "https://www.earthcam.com/usa/newyork/timessquare/"),
        .init(id: "cam-london-traf", name: "Trafalgar Sq", city: "London", lat: 51.5080, lon: -0.1281, provider: "Trafalgar webcam", url: "https://www.earthcam.com/world/england/london/trafalgarsquare/"),
        .init(id: "cam-austin-6th", name: "6th Street", city: "Austin", lat: 30.2676, lon: -97.7395, provider: "Austin cam", url: "https://www.fox7austin.com/weather/cameras"),
        .init(id: "cam-tokyo-shibuya", name: "Shibuya Crossing", city: "Tokyo", lat: 35.6595, lon: 139.7005, provider: "Shibuya cam", url: "https://www.youtube.com/results?search_query=shibuya+live+camera"),
        .init(id: "cam-sf-bay", name: "Bay Bridge", city: "San Francisco", lat: 37.7983, lon: -122.3778, provider: "ABC7 cam", url: "https://abc7news.com/traffic/")
    ]
}

// MARK: - Launches (Launch Library 2)

struct LLResponse: Decodable { let results: [Lossy<LLLaunch>] }
struct LLLaunch: Decodable {
    let id: String
    let name: String
    let net: String
    let url: String?
    let status: Status?
    let launch_service_provider: Provider?
    let pad: Pad?
    struct Status: Decodable { let abbrev: String?; let name: String? }
    struct Provider: Decodable { let name: String? }
    struct Pad: Decodable {
        let name: String?
        let latitude: FlexDouble?
        let longitude: FlexDouble?
        let location: Loc?
        struct Loc: Decodable { let name: String? }
    }
}

struct Launch: Identifiable, Equatable {
    let id: String
    let name: String
    let net: Date
    let status: String
    let provider: String
    let pad: String
    let lat: Double
    let lon: Double
    let url: String?
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init?(_ l: LLLaunch) {
        guard let lat = l.pad?.latitude?.value, let lon = l.pad?.longitude?.value else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        guard let d = iso.date(from: l.net) ?? ISO8601DateFormatter().date(from: l.net) else { return nil }
        id = l.id
        name = l.name
        net = d
        status = l.status?.name ?? l.status?.abbrev ?? "Unknown"
        provider = l.launch_service_provider?.name ?? "Unknown provider"
        pad = [l.pad?.name, l.pad?.location?.name].compactMap { $0 }.joined(separator: ", ")
        self.lat = lat
        self.lon = lon
        url = l.url
    }
}

// MARK: - Unified entity (what the detail sheet renders)

struct MetaRow: Identifiable, Equatable {
    let key: String
    let value: String
    var id: String { key }
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
}

struct Entity: Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case aircraft, military, earthquake, satellite, launch, camera, place
        var icon: String {
            switch self {
            case .aircraft: return "airplane"
            case .military: return "shield.lefthalf.filled"
            case .earthquake: return "waveform.path.ecg"
            case .satellite: return "sparkle"
            case .launch: return "flame"
            case .camera: return "video.fill"
            case .place: return "mappin.and.ellipse"
            }
        }
        var label: String {
            switch self {
            case .aircraft: return "AIRCRAFT"
            case .military: return "MILITARY"
            case .earthquake: return "SEISMIC"
            case .satellite: return "ORBITAL"
            case .launch: return "LAUNCH"
            case .camera: return "CAMERA"
            case .place: return "LOCATION"
            }
        }
        var color: Color {
            switch self {
            case .aircraft: return .green
            case .military: return .orange
            case .earthquake: return .red
            case .satellite: return .cyan
            case .launch: return .pink
            case .camera: return .mint
            case .place: return .white
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let summary: String
    let lat: Double
    let lon: Double
    let time: Date?
    let meta: [MetaRow]
    let url: String?
    let viewDistance: Double

    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var shareText: String {
        "\(kind.label): \(title)\n\(subtitle)\n\(Fmt.coord(lat, lon))\n\(summary)\nhttps://maps.apple.com/?ll=\(lat),\(lon)&q=\(title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    }

    static func from(_ c: Contact) -> Entity {
        let alt = c.onGround ? "on ground" : (c.altFt.map { "\($0.formatted()) ft" } ?? "alt n/a")
        let spd = c.groundSpeedKt.map { "\(Int($0)) kt" } ?? "spd n/a"
        let sub = [c.type, c.registration].compactMap { $0 }.joined(separator: " · ")
        return Entity(
            id: "ac-\(c.id)",
            kind: c.military ? .military : .aircraft,
            title: c.displayName,
            subtitle: sub.isEmpty ? "ADS-B contact" : sub,
            summary: "\(c.military ? "Military" : "Civil") track · \(alt) · \(spd) · hdg \(Int(c.track))°",
            lat: c.lat, lon: c.lon, time: c.seenAt,
            meta: [
                MetaRow("ICAO", c.id.uppercased()),
                MetaRow("Callsign", c.callsign.isEmpty ? "—" : c.callsign),
                MetaRow("Type", c.type ?? "—"),
                MetaRow("Registration", c.registration ?? "—"),
                MetaRow("Altitude", alt),
                MetaRow("Ground speed", spd),
                MetaRow("Track", "\(Int(c.track))°"),
                MetaRow("Squawk", c.squawk ?? "—"),
                MetaRow("Source", "adsb.lol")
            ],
            url: "https://globe.adsb.lol/?icao=\(c.id)",
            viewDistance: 60_000)
    }

    static func from(_ q: Quake) -> Entity {
        Entity(
            id: "eq-\(q.id)",
            kind: .earthquake,
            title: String(format: "M%.1f", q.mag),
            subtitle: q.place,
            summary: "Magnitude \(String(format: "%.1f", q.mag)) · depth \(Int(q.depthKm)) km · \(Fmt.rel.localizedString(for: q.time, relativeTo: Date()))",
            lat: q.lat, lon: q.lon, time: q.time,
            meta: [
                MetaRow("Magnitude", String(format: "%.1f", q.mag)),
                MetaRow("Depth", String(format: "%.1f km", q.depthKm)),
                MetaRow("Time (UTC)", Fmt.utc(q.time)),
                MetaRow("Time (local)", Fmt.time(q.time)),
                MetaRow("Event ID", q.id),
                MetaRow("Source", "USGS")
            ],
            url: q.url,
            viewDistance: 400_000)
    }

    static func from(_ s: SatPos) -> Entity {
        Entity(
            id: "sat-\(s.id)",
            kind: .satellite,
            title: s.name.uppercased(),
            subtitle: "Low Earth orbit",
            summary: "Altitude \(Int(s.altKm)) km · \(Int(s.velocityKmh).formatted()) km/h · fix \(Fmt.rel.localizedString(for: s.time, relativeTo: Date()))",
            lat: s.lat, lon: s.lon, time: s.time,
            meta: [
                MetaRow("NORAD", s.id),
                MetaRow("Altitude", String(format: "%.1f km", s.altKm)),
                MetaRow("Velocity", "\(Int(s.velocityKmh).formatted()) km/h"),
                MetaRow("Fix time", Fmt.time(s.time)),
                MetaRow("Source", s.source)
            ],
            url: "https://wheretheiss.at",
            viewDistance: 3_000_000)
    }

    static func from(_ l: Launch) -> Entity {
        let now = Date()
        let when = l.net > now
            ? "T-minus \(Fmt.rel.localizedString(for: l.net, relativeTo: now).replacingOccurrences(of: "in ", with: ""))"
            : "Launched \(Fmt.rel.localizedString(for: l.net, relativeTo: now))"
        return Entity(
            id: "ll-\(l.id)",
            kind: .launch,
            title: l.name,
            subtitle: l.provider,
            summary: "\(when) · \(l.status) · \(l.pad)",
            lat: l.lat, lon: l.lon, time: l.net,
            meta: [
                MetaRow("Provider", l.provider),
                MetaRow("Pad", l.pad),
                MetaRow("NET (UTC)", Fmt.utc(l.net)),
                MetaRow("NET (local)", Fmt.time(l.net)),
                MetaRow("Status", l.status),
                MetaRow("Source", "Launch Library 2")
            ],
            url: l.url,
            viewDistance: 25_000)
    }

    static func place(lat: Double, lon: Double, name: String, detail: String, distance: Double) -> Entity {
        Entity(
            id: "pt-\(String(format: "%.4f-%.4f", lat, lon))",
            kind: .place,
            title: name,
            subtitle: detail,
            summary: "Tapped location · \(Fmt.coord(lat, lon))",
            lat: lat, lon: lon, time: nil,
            meta: [
                MetaRow("Latitude", String(format: "%.5f", lat)),
                MetaRow("Longitude", String(format: "%.5f", lon)),
                MetaRow("Source", "Apple Maps geocoder")
            ],
            url: nil,
            viewDistance: distance)
    }

    static func from(_ cam: CameraFeed) -> Entity {
        Entity(
            id: cam.id,
            kind: .camera,
            title: cam.name,
            subtitle: cam.city,
            summary: "Public camera overlay · \(cam.provider)",
            lat: cam.lat,
            lon: cam.lon,
            time: nil,
            meta: [
                MetaRow("City", cam.city),
                MetaRow("Provider", cam.provider),
                MetaRow("Source", "Public camera directory")
            ],
            url: cam.url,
            viewDistance: 35_000
        )
    }
}

enum SensorStyle: String, CaseIterable, Identifiable, Codable {
    case normal, nvg, flir, crt, noir
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .nvg: return "NVG"
        case .flir: return "FLIR"
        case .crt: return "CRT"
        case .noir: return "Noir"
        }
    }
}

enum MissionPreset: String, CaseIterable, Identifiable {
    case liveContacts, space, environmental
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liveContacts: return "Live Contacts"
        case .space: return "Space Mission"
        case .environmental: return "Environmental"
        }
    }
    var icon: String {
        switch self {
        case .liveContacts: return "airplane.circle"
        case .space: return "sparkles"
        case .environmental: return "leaf"
        }
    }
}

// MARK: - Bookmarks

struct Bookmark: Identifiable, Codable, Equatable {
    var id: String
    var kind: Entity.Kind
    var title: String
    var subtitle: String
    var summary: String
    var lat: Double
    var lon: Double
    var viewDistance: Double
    var savedAt: Date

    init(_ e: Entity) {
        id = e.id; kind = e.kind; title = e.title; subtitle = e.subtitle; summary = e.summary
        lat = e.lat; lon = e.lon; viewDistance = e.viewDistance; savedAt = Date()
    }

    var entity: Entity {
        Entity(id: id, kind: kind, title: title, subtitle: subtitle, summary: summary,
               lat: lat, lon: lon, time: savedAt,
               meta: [MetaRow("Saved", Fmt.time(savedAt)), MetaRow("Coordinates", Fmt.coord(lat, lon))],
               url: nil, viewDistance: viewDistance)
    }
}

// MARK: - Formatting

enum Fmt {
    static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'Z'"
        return f
    }()
    static func utc(_ d: Date) -> String { utcFormatter.string(from: d) }
    static func time(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
    static func coord(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.4f°%@  %.4f°%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
