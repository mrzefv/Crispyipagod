import Foundation
import CoreLocation
import SwiftUI

// MARK: - Layers

enum Layer: String, CaseIterable, Identifiable, Codable {
    case flights, military, ships, satellites, quakes, launches, cctv, traffic, fires, bikeshare, radio, infra, cables, airport
    case radar, satir, wind, power, rail, trains, airports, stations, alerts, space, scanner, peaks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flights: return "Live Flights"
        case .military: return "Military Traffic"
        case .ships: return "Live Vessels (AIS)"
        case .satellites: return "Satellites"
        case .quakes: return "Earthquakes (24h)"
        case .launches: return "Space Missions"
        case .cctv: return "Public CCTV"
        case .traffic: return "Traffic Flow"
        case .fires: return "Active Fires (24h)"
        case .bikeshare: return "Bikeshare"
        case .radio: return "World Radio"
        case .infra: return "Infrastructure"
        case .cables: return "Submarine Cables"
        case .airport: return "Airport Detail"
        case .radar: return "Weather Radar"
        case .satir: return "Satellite IR Clouds"
        case .wind: return "Wind Vectors"
        case .power: return "Power Grid"
        case .rail: return "Rail Network"
        case .trains: return "Live Trains"
        case .airports: return "Airports"
        case .stations: return "Weather Stations"
        case .alerts: return "NWS Alerts & Incidents"
        case .space: return "Sun & Space Weather"
        case .scanner: return "Scanner Feeds"
        case .peaks: return "Peaks & Terrain"
        }
    }
    var icon: String {
        switch self {
        case .flights: return "airplane"
        case .military: return "shield.lefthalf.filled"
        case .ships: return "ferry"
        case .satellites: return "sparkle"
        case .quakes: return "waveform.path.ecg"
        case .launches: return "flame"
        case .cctv: return "video"
        case .traffic: return "car.2"
        case .fires: return "flame.circle"
        case .bikeshare: return "bicycle"
        case .radio: return "radio"
        case .infra: return "server.rack"
        case .cables: return "cable.connector"
        case .airport: return "airplane.arrival"
        case .radar: return "cloud.rain"
        case .satir: return "cloud.fill"
        case .wind: return "wind"
        case .power: return "bolt"
        case .rail: return "tram.fill"
        case .trains: return "train.side.front.car"
        case .airports: return "airplane.circle"
        case .stations: return "thermometer.medium"
        case .alerts: return "exclamationmark.triangle"
        case .space: return "sun.max"
        case .scanner: return "antenna.radiowaves.left.and.right"
        case .peaks: return "mountain.2"
        }
    }
    var source: String {
        switch self {
        case .flights: return "adsb.lol"
        case .military: return "adsb.lol /mil"
        case .ships: return "AISStream (key)"
        case .satellites: return "CelesTrak GP · SGP4"
        case .quakes: return "USGS"
        case .launches: return "Launch Library 2"
        case .cctv: return "TfL · NYC DOT · Caltrans · Austin"
        case .traffic: return "Apple Maps"
        case .fires: return "NASA FIRMS (key)"
        case .bikeshare: return "GBFS"
        case .radio: return "Radio Browser"
        case .infra: return "OSM Overpass"
        case .cables: return "TeleGeography"
        case .airport: return "OSM Overpass"
        case .radar: return "RainViewer"
        case .satir: return "RainViewer"
        case .wind: return "Open-Meteo"
        case .power: return "OSM Overpass"
        case .rail: return "OSM Overpass"
        case .trains: return "Amtrak · Digitraffic"
        case .airports: return "OurAirports"
        case .stations: return "aviationweather.gov · NDBC"
        case .alerts: return "NWS · Cal Fire"
        case .space: return "NOAA SWPC"
        case .scanner: return "Broadcastify"
        case .peaks: return "OSM · Open-Meteo"
        }
    }
    var needsKey: Bool { self == .ships || self == .fires }
}

// MARK: - Sensor modes / missions

enum SensorMode: String, CaseIterable, Identifiable, Codable {
    case normal, nvg, flir, crt, noir, snow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .nvg: return "NVG"
        case .flir: return "FLIR"
        case .crt: return "CRT"
        case .noir: return "Noir"
        case .snow: return "Snow"
        }
    }
    var key: String { "\(SensorMode.allCases.firstIndex(of: self)! + 1)" }
}

enum Mission: String, CaseIterable, Identifiable {
    case liveContacts, space, environmental, london, weather, grid, situational
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liveContacts: return "Live Contacts"
        case .space: return "Space & Sun"
        case .environmental: return "Environmental"
        case .london: return "City Watch"
        case .weather: return "Weather Ops"
        case .grid: return "Grid & Rail"
        case .situational: return "Situational"
        }
    }
    var icon: String {
        switch self {
        case .liveContacts: return "airplane.circle"
        case .space: return "sparkles"
        case .environmental: return "globe.europe.africa"
        case .london: return "video.circle"
        case .weather: return "cloud.bolt.rain"
        case .grid: return "bolt.horizontal"
        case .situational: return "exclamationmark.triangle"
        }
    }
    var layers: Set<Layer> {
        switch self {
        case .liveContacts: return [.flights, .military, .ships, .trains]
        case .space: return [.satellites, .launches, .space]
        case .environmental: return [.quakes, .fires, .alerts]
        case .london: return [.cctv, .traffic, .flights]
        case .weather: return [.radar, .wind, .stations, .alerts]
        case .grid: return [.power, .rail, .trains, .infra]
        case .situational: return [.alerts, .fires, .scanner, .cctv, .flights]
        }
    }
    var camera: (lat: Double, lon: Double, distance: Double, pitch: Double) {
        switch self {
        case .liveContacts: return (40.64, -73.78, 900_000, 45)
        case .space: return (20, -30, 26_000_000, 0)
        case .environmental: return (10, 140, 22_000_000, 0)
        case .london: return (51.505, -0.09, 22_000, 55)
        case .weather: return (36, -95, 3_500_000, 0)
        case .grid: return (40.75, -74.0, 120_000, 0)
        case .situational: return (34.05, -118.25, 400_000, 30)
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

    enum AircraftClass { case heli, light, jet, heavy, drone }
    var aircraftClass: AircraftClass {
        let t = (type ?? "").uppercased()
        if ["R22","R44","R66","EC35","EC45","EC30","EC55","EC75","H60","UH1","AS50","AS55","AS65","A139","A109","B06","B407","B412","B429","S76","S92","H500","H47","H64","MI8","MI17","B105","EC20","A169","H160","B222","B230","B430"].contains(t) || t.hasPrefix("EC1") || t.hasPrefix("AS3") { return .heli }
        if ["MQ9","RQ4","MQ4","MQ1","Q4","RQ1"].contains(t) { return .drone }
        if ["B744","B748","B77W","B77L","B772","B773","B788","B789","B78X","A388","A332","A333","A339","A342","A343","A345","A346","A359","A35K","B763","B762","B764","MD11","C17","C5M","A124","A225","KC10","K35R","E3TF","E3CF","B52","RC135","C130","C30J","A400","IL76","AN12","B742","B741","B743","DC10"].contains(t) { return .heavy }
        if t.hasPrefix("C1") || t.hasPrefix("C2") || t.hasPrefix("P28") || t.hasPrefix("PA") || t.hasPrefix("SR2") || t.hasPrefix("DA4") || t.hasPrefix("DA2") || t.hasPrefix("BE") || t.hasPrefix("M20") || t.hasPrefix("RV") || t.hasPrefix("DV20") || t.hasPrefix("AC1") || t.hasPrefix("GLID") || t == "ULAC" || t == "GYRO" { return .light }
        return .jet
    }
    var glyph: String {
        switch aircraftClass {
        case .heli: return "fanblades.fill"
        case .light: return "paperplane.fill"
        case .jet: return "airplane"
        case .heavy: return "airplane"
        case .drone: return "arrowtriangle.up.fill"
        }
    }

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
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
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

// MARK: - Ships (AISStream)

struct Ship: Identifiable, Equatable {
    let id: String          // MMSI
    var name: String
    var lat: Double
    var lon: Double
    var sogKt: Double
    var cog: Double
    var heading: Double
    var navStatus: Int
    var seenAt: Date
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "MMSI \(id)" : name.trimmingCharacters(in: .whitespaces) }
    var statusText: String {
        switch navStatus {
        case 0: return "Under way (engine)"
        case 1: return "At anchor"
        case 2: return "Not under command"
        case 3: return "Restricted manoeuvrability"
        case 5: return "Moored"
        case 7: return "Fishing"
        case 8: return "Under way (sailing)"
        default: return "Status \(navStatus)"
        }
    }
}

// MARK: - Satellites (CelesTrak GP + SGP4)

struct Satellite: Identifiable, Equatable {
    enum Class: String { case station, starlink, weather, gps, other
        var color: Color {
            switch self {
            case .station: return .cyan
            case .starlink: return Color(red: 0.75, green: 0.75, blue: 1.0)
            case .weather: return .mint
            case .gps: return .yellow
            case .other: return .white
            }
        }
        var label: String {
            switch self {
            case .station: return "STATION"
            case .starlink: return "STARLINK"
            case .weather: return "WEATHER"
            case .gps: return "NAV"
            case .other: return "OTHER"
            }
        }
    }
    let id: String
    let name: String
    let cls: Class
    var lat: Double
    var lon: Double
    var altKm: Double
    var speedKmh: Double
    var periodMin: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    static func classify(_ name: String) -> Class {
        let n = name.uppercased()
        if n.contains("ISS") || n.contains("TIANGONG") || n.contains("CSS") || n.contains("ZARYA") { return .station }
        if n.contains("STARLINK") { return .starlink }
        if n.contains("NOAA") || n.contains("METOP") || n.contains("GOES") || n.contains("METEOR") || n.contains("FENGYUN") || n.contains("TERRA") || n.contains("AQUA") || n.contains("SUOMI") { return .weather }
        if n.contains("NAVSTAR") || n.contains("GPS") || n.contains("GLONASS") || n.contains("GALILEO") || n.contains("BEIDOU") { return .gps }
        return .other
    }
}

// MARK: - CCTV (TfL JamCams)

struct TfLPlace: Decodable {
    let id: String
    let commonName: String
    let lat: Double
    let lon: Double
    let additionalProperties: [Prop]
    struct Prop: Decodable { let key: String; let value: String }
}

struct Camera: Identifiable, Equatable {
    let id: String
    let name: String
    let source: String          // "TfL", "NYC DOT", "Caltrans", "Austin"
    let lat: Double
    let lon: Double
    let imageURL: String        // still snapshot (refreshable)
    let videoURL: String?       // short MP4 clip (TfL) — looped
    let streamURL: String?      // HLS live stream (Caltrans)
    let available: Bool
    let heading: Double?        // published direction if any
    let region: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var isLiveVideo: Bool { streamURL != nil }

    init(id: String, name: String, source: String, lat: Double, lon: Double, imageURL: String, videoURL: String? = nil, streamURL: String? = nil, available: Bool = true, heading: Double? = nil, region: String = "") {
        self.id = id; self.name = name; self.source = source; self.lat = lat; self.lon = lon
        self.imageURL = imageURL; self.videoURL = videoURL; self.streamURL = streamURL
        self.available = available; self.heading = heading; self.region = region
    }

    init?(_ p: TfLPlace) {
        let props = Dictionary(p.additionalProperties.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let img = props["imageUrl"], !img.isEmpty else { return nil }
        self.init(id: "tfl-" + p.id, name: p.commonName, source: "TfL", lat: p.lat, lon: p.lon, imageURL: img,
                  videoURL: props["videoUrl"], streamURL: nil,
                  available: (props["available"] ?? "true").lowercased() == "true", heading: nil, region: "London")
    }

    static func headingFrom(_ dir: String?) -> Double? {
        switch (dir ?? "").lowercased() {
        case "north", "n": return 0
        case "northeast", "ne": return 45
        case "east", "e": return 90
        case "southeast", "se": return 135
        case "south", "s": return 180
        case "southwest", "sw": return 225
        case "west", "w": return 270
        case "northwest", "nw": return 315
        default: return nil
        }
    }
}

// MARK: - Fires (NASA FIRMS CSV)

struct Fire: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let frp: Double
    let brightness: Double
    let confidence: String
    let time: Date
    let satellite: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Bikeshare (GBFS)

struct GBFSSystem { let name: String; let lat: Double; let lon: Double; let base: String }
struct GBFSInfo: Decodable { let data: D; struct D: Decodable { let stations: [Lossy<St>] }
    struct St: Decodable { let station_id: String; let name: String; let lat: Double; let lon: Double; let capacity: Int? } }
struct GBFSStatus: Decodable { let data: D; struct D: Decodable { let stations: [Lossy<St>] }
    struct St: Decodable { let station_id: String; let num_bikes_available: Int?; let num_docks_available: Int? } }

struct BikeStation: Identifiable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    var bikes: Int
    var docks: Int
    let system: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Radio (Radio Browser)

struct RadioStation: Identifiable, Decodable, Equatable {
    let stationuuid: String
    let name: String
    let url_resolved: String
    let country: String
    let geo_lat: Double?
    let geo_long: Double?
    let tags: String?
    let codec: String?
    let clickcount: Int?
    var id: String { stationuuid }
    var lat: Double { geo_lat ?? 0 }
    var lon: Double { geo_long ?? 0 }
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - OSM Overpass (infra + airport)

struct OverpassResponse: Decodable {
    let elements: [Lossy<El>]
    struct El: Decodable {
        let type: String
        let id: Int
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?
        let geometry: [Center]?
        struct Center: Decodable { let lat: Double; let lon: Double }
    }
}

struct InfraNode: Identifiable, Equatable {
    enum Kind: String { case datacenter, dam, power, substation
        var icon: String { switch self { case .datacenter: return "server.rack"; case .dam: return "water.waves"; case .power: return "bolt.fill"; case .substation: return "bolt.square" } }
        var label: String { rawValue.uppercased() }
    }
    let id: String
    let kind: Kind
    let name: String
    let lat: Double
    let lon: Double
    let tags: [String: String]
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct AirportFeature: Identifiable, Equatable {
    enum Kind { case runway, taxiway, apron, terminal }
    let id: String
    let kind: Kind
    let name: String
    let points: [CLLocationCoordinate2D]
    static func == (a: AirportFeature, b: AirportFeature) -> Bool { a.id == b.id }
}

// MARK: - Submarine cables (TeleGeography public geojson)

struct Cable: Identifiable, Equatable {
    let id: String
    let name: String
    let color: String
    let segments: [[CLLocationCoordinate2D]]
    let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    static func == (a: Cable, b: Cable) -> Bool { a.id == b.id }
}

// MARK: - Scenes, passes, measurement

struct Keyframe: Identifiable, Codable, Equatable {
    var id = UUID()
    var lat: Double
    var lon: Double
    var distance: Double
    var heading: Double
    var pitch: Double
    var hold: Double = 3
    var travel: Double = 3
}

struct SceneFile: Codable {
    var name: String
    var keyframes: [Keyframe]
    var sensor: String
    var layers: [String]
}

struct ISSPass: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let peak: Date
    let end: Date
    let maxElevationDeg: Double
    let minGroundKm: Double
}

struct Weather: Equatable {
    let tempC: Double
    let windKt: Double
    let windDir: Double
    let cloudPct: Double
    let visibilityM: Double
    let fetched: Date
    var text: String {
        String(format: "%.0f°C · WIND %03.0f°/%.0fkt · CLD %.0f%% · VIS %.0fkm", tempC, windDir, windKt, cloudPct, visibilityM / 1000)
    }
}

// MARK: - Weather radar (RainViewer)

struct RadarFrame: Identifiable, Equatable {
    let time: Date
    let path: String
    let kind: String   // "radar" | "satellite"
    var id: String { kind + path }
}

struct WindVector: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let speedKt: Double
    let dirDeg: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct StormCell: Identifiable, Equatable {
    let id: String
    var lat: Double
    var lon: Double
    var speedKmh: Double
    var headingDeg: Double
    var intensity: Double
    var history: [CLLocationCoordinate2D]
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    static func == (a: StormCell, b: StormCell) -> Bool { a.id == b.id && a.lat == b.lat && a.lon == b.lon }
}

// MARK: - Power grid / rail / peaks (Overpass)

struct PowerLine: Identifiable, Equatable {
    let id: String
    let voltage: Double
    let name: String
    let operatorName: String
    let points: [CLLocationCoordinate2D]
    static func == (a: PowerLine, b: PowerLine) -> Bool { a.id == b.id }
    var color: Color {
        switch voltage {
        case ..<69_000: return .yellow
        case ..<230_000: return .orange
        case ..<400_000: return .red
        default: return .purple
        }
    }
}

struct RailLine: Identifiable, Equatable {
    let id: String
    let kind: String   // rail | subway | light_rail | tram | yard
    let name: String
    let points: [CLLocationCoordinate2D]
    static func == (a: RailLine, b: RailLine) -> Bool { a.id == b.id }
}

struct RailStation: Identifiable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let kind: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct Peak: Identifiable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let elevationM: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Trains

struct Train: Identifiable, Equatable {
    let id: String
    let name: String
    let operatorName: String
    var lat: Double
    var lon: Double
    var speedKmh: Double
    var heading: Double
    var status: String
    var nextStop: String
    var seenAt: Date
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Airports (OurAirports)

struct Airport: Identifiable, Equatable {
    let id: String     // ident (ICAO or local)
    let iata: String
    let name: String
    let type: String   // large_airport | medium_airport
    let lat: Double
    let lon: Double
    let elevationFt: Double
    let city: String
    let country: String
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Weather stations (METAR + NDBC)

struct WxStation: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String   // METAR | BUOY
    let lat: Double
    let lon: Double
    let tempC: Double?
    let windDir: Double?
    let windKt: Double?
    let pressureHpa: Double?
    let visibilityMi: Double?
    let raw: String
    let time: Date?
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Alerts & incidents

struct HazardAlert: Identifiable, Equatable {
    let id: String
    let source: String   // NWS | CalFire
    let event: String
    let headline: String
    let severity: String
    let area: String
    let starts: Date?
    let ends: Date?
    let lat: Double
    let lon: Double
    let rings: [[CLLocationCoordinate2D]]
    let url: String?
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    static func == (a: HazardAlert, b: HazardAlert) -> Bool { a.id == b.id }
    var color: Color {
        switch severity.lowercased() {
        case "extreme": return .purple
        case "severe": return .red
        case "moderate": return .orange
        default: return .yellow
        }
    }
}

// MARK: - Scanner feeds

struct ScannerFeed: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let genre: String
    var lat: Double
    var lon: Double
    var listeners: Int
    var streamURL: String { "https://broadcastify.cdnstream1.com/\(id)" }
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Space weather

struct SpaceWeather: Equatable {
    var kp: Double = 0
    var kpTime: Date? = nil
    var solarWindKmS: Double = 0
    var density: Double = 0
    var xrayFlux: Double = 0
    var xrayClass: String = "—"
    var aurora: [(lat: Double, lon: Double, prob: Double)] = []
    var fetched: Date? = nil
    static func == (a: SpaceWeather, b: SpaceWeather) -> Bool { a.kp == b.kp && a.fetched == b.fetched }
    var stormLevel: String {
        switch kp { case ..<4: return "QUIET"; case ..<5: return "ACTIVE"; case ..<6: return "G1 MINOR"; case ..<7: return "G2 MODERATE"; case ..<8: return "G3 STRONG"; case ..<9: return "G4 SEVERE"; default: return "G5 EXTREME" }
    }
}

struct AuroraPoint: Identifiable, Equatable {
    let id: Int
    let lat: Double
    let lon: Double
    let prob: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
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
        case aircraft, military, ship, earthquake, satellite, launch, camera, place, fire, bike, radio, infra, cable
        case train, airport, station, alert, scanner, peak, storm
        var icon: String {
            switch self {
            case .aircraft: return "airplane"
            case .military: return "shield.lefthalf.filled"
            case .ship: return "ferry"
            case .earthquake: return "waveform.path.ecg"
            case .satellite: return "sparkle"
            case .launch: return "flame"
            case .camera: return "video"
            case .place: return "mappin.and.ellipse"
            case .fire: return "flame.circle"
            case .bike: return "bicycle"
            case .radio: return "radio"
            case .infra: return "server.rack"
            case .cable: return "cable.connector"
            case .train: return "train.side.front.car"
            case .airport: return "airplane.circle"
            case .station: return "thermometer.medium"
            case .alert: return "exclamationmark.triangle"
            case .scanner: return "antenna.radiowaves.left.and.right"
            case .peak: return "mountain.2"
            case .storm: return "cloud.bolt.rain"
            }
        }
        var label: String {
            switch self {
            case .aircraft: return "AIRCRAFT"
            case .military: return "MILITARY"
            case .ship: return "VESSEL"
            case .earthquake: return "SEISMIC"
            case .satellite: return "ORBITAL"
            case .launch: return "LAUNCH"
            case .camera: return "CAMERA"
            case .place: return "LOCATION"
            case .fire: return "THERMAL"
            case .bike: return "BIKESHARE"
            case .radio: return "RADIO"
            case .infra: return "INFRA"
            case .cable: return "CABLE"
            case .train: return "RAIL"
            case .airport: return "AIRPORT"
            case .station: return "WX STATION"
            case .alert: return "ALERT"
            case .scanner: return "SCANNER"
            case .peak: return "TERRAIN"
            case .storm: return "STORM CELL"
            }
        }
        var color: Color {
            switch self {
            case .aircraft: return .green
            case .military: return .orange
            case .ship: return .blue
            case .earthquake: return .red
            case .satellite: return .cyan
            case .launch: return .pink
            case .camera: return .purple
            case .place: return .white
            case .fire: return Color(red: 1.0, green: 0.4, blue: 0.1)
            case .bike: return .mint
            case .radio: return .yellow
            case .infra: return .teal
            case .cable: return .indigo
            case .train: return Color(red: 0.9, green: 0.5, blue: 1.0)
            case .airport: return Color(red: 0.6, green: 0.9, blue: 1.0)
            case .station: return Color(red: 0.6, green: 1.0, blue: 0.9)
            case .alert: return .red
            case .scanner: return Color(red: 1.0, green: 0.85, blue: 0.3)
            case .peak: return Color(red: 0.8, green: 0.75, blue: 0.6)
            case .storm: return Color(red: 0.4, green: 0.7, blue: 1.0)
            }
        }
        var trackable: Bool { self == .aircraft || self == .military || self == .ship || self == .satellite || self == .train || self == .storm }
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
    var imageURL: String? = nil
    var heading: Double = 0

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
            viewDistance: 60_000,
            imageURL: nil,
            heading: c.track)
    }

    static func from(_ v: Ship) -> Entity {
        Entity(
            id: "sh-\(v.id)",
            kind: .ship,
            title: v.displayName,
            subtitle: v.statusText,
            summary: "\(String(format: "%.1f", v.sogKt)) kt · COG \(Int(v.cog))° · fix \(Fmt.rel.localizedString(for: v.seenAt, relativeTo: Date()))",
            lat: v.lat, lon: v.lon, time: v.seenAt,
            meta: [
                MetaRow("MMSI", v.id),
                MetaRow("Speed", String(format: "%.1f kt", v.sogKt)),
                MetaRow("Course", "\(Int(v.cog))°"),
                MetaRow("Heading", v.heading >= 511 ? "—" : "\(Int(v.heading))°"),
                MetaRow("Nav status", v.statusText),
                MetaRow("Source", "AISStream")
            ],
            url: "https://www.marinetraffic.com/en/ais/details/ships/mmsi:\(v.id)",
            viewDistance: 20_000,
            imageURL: nil,
            heading: v.cog)
    }

    static func from(_ sat: Satellite) -> Entity {
        Entity(
            id: "sat-\(sat.id)",
            kind: .satellite,
            title: sat.name,
            subtitle: "\(sat.cls.label) · period \(Int(sat.periodMin)) min",
            summary: "Altitude \(Int(sat.altKm)) km · \(Int(sat.speedKmh).formatted()) km/h · SGP4 propagated",
            lat: sat.lat, lon: sat.lon, time: Date(),
            meta: [
                MetaRow("NORAD", sat.id),
                MetaRow("Class", sat.cls.label),
                MetaRow("Altitude", String(format: "%.1f km", sat.altKm)),
                MetaRow("Velocity", "\(Int(sat.speedKmh).formatted()) km/h"),
                MetaRow("Period", String(format: "%.1f min", sat.periodMin)),
                MetaRow("Source", "CelesTrak GP")
            ],
            url: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(sat.id)",
            viewDistance: 3_000_000)
    }

    static func from(_ cam: Camera) -> Entity {
        Entity(
            id: "cam-\(cam.id)",
            kind: .camera,
            title: cam.name,
            subtitle: "\(cam.source) · \(cam.region) · " + (cam.isLiveVideo ? "HLS live" : cam.videoURL != nil ? "clip + stills" : "stills") + (cam.available ? "" : " · offline"),
            summary: cam.isLiveVideo ? "Public camera with a live video stream." : "Public traffic camera. Stills refresh every few seconds to minutes; position is published, view direction is \(cam.heading == nil ? "estimated" : "published").",
            lat: cam.lat, lon: cam.lon, time: nil,
            meta: [
                MetaRow("Camera ID", cam.id),
                MetaRow("Source", cam.source),
                MetaRow("Region", cam.region),
                MetaRow("Direction", cam.heading.map { "\(Int($0))°" } ?? "estimated"),
                MetaRow("Live video", cam.isLiveVideo ? "yes (HLS)" : "no"),
                MetaRow("Available", cam.available ? "yes" : "no")
            ],
            url: cam.streamURL ?? cam.videoURL ?? cam.imageURL,
            viewDistance: 1_200,
            imageURL: cam.imageURL,
            heading: cam.heading ?? 0)
    }

    static func from(_ f: Fire) -> Entity {
        Entity(
            id: "fire-\(f.id)",
            kind: .fire,
            title: String(format: "FRP %.0f MW", f.frp),
            subtitle: "\(f.satellite) · confidence \(f.confidence)",
            summary: "Thermal anomaly · brightness \(Int(f.brightness)) K · \(Fmt.rel.localizedString(for: f.time, relativeTo: Date()))",
            lat: f.lat, lon: f.lon, time: f.time,
            meta: [MetaRow("FRP", String(format: "%.1f MW", f.frp)), MetaRow("Brightness", "\(Int(f.brightness)) K"),
                   MetaRow("Confidence", f.confidence), MetaRow("Acquired (UTC)", Fmt.utc(f.time)), MetaRow("Source", "NASA FIRMS VIIRS")],
            url: "https://firms.modaps.eosdis.nasa.gov/map/#d:24hrs;@\(f.lon),\(f.lat),9z",
            viewDistance: 60_000)
    }

    static func from(_ b: BikeStation) -> Entity {
        Entity(
            id: "bike-\(b.id)",
            kind: .bike,
            title: b.name,
            subtitle: b.system,
            summary: "\(b.bikes) bikes · \(b.docks) docks available",
            lat: b.lat, lon: b.lon, time: Date(),
            meta: [MetaRow("Bikes", "\(b.bikes)"), MetaRow("Docks", "\(b.docks)"), MetaRow("Station ID", b.id), MetaRow("Source", "GBFS")],
            url: nil, viewDistance: 1_500)
    }

    static func from(_ r: RadioStation) -> Entity {
        Entity(
            id: "radio-\(r.id)",
            kind: .radio,
            title: r.name,
            subtitle: r.country,
            summary: "\(r.codec ?? "stream") · \(r.tags ?? "") · \(r.clickcount ?? 0) listens",
            lat: r.lat, lon: r.lon, time: nil,
            meta: [MetaRow("Country", r.country), MetaRow("Codec", r.codec ?? "—"), MetaRow("Tags", r.tags ?? "—"), MetaRow("Source", "Radio Browser")],
            url: r.url_resolved, viewDistance: 12_000)
    }

    static func from(_ n: InfraNode) -> Entity {
        Entity(
            id: "infra-\(n.id)",
            kind: .infra,
            title: n.name,
            subtitle: n.kind.label,
            summary: n.tags.filter { ["operator", "plant:source", "plant:output:electrical", "height", "dam:type"].contains($0.key) }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " · ").ifEmpty("OSM-mapped \(n.kind.rawValue)"),
            lat: n.lat, lon: n.lon, time: nil,
            meta: n.tags.sorted { $0.key < $1.key }.prefix(10).map { MetaRow($0.key, $0.value) } + [MetaRow("Source", "OpenStreetMap")],
            url: "https://www.openstreetmap.org/\(n.id.replacingOccurrences(of: "-", with: "/"))",
            viewDistance: 4_000)
    }

    static func from(_ t: Train) -> Entity {
        Entity(id: "train-\(t.id)", kind: .train, title: t.name, subtitle: t.operatorName,
               summary: "\(Int(t.speedKmh)) km/h · \(t.status) · next \(t.nextStop)",
               lat: t.lat, lon: t.lon, time: t.seenAt,
               meta: [MetaRow("Operator", t.operatorName), MetaRow("Speed", "\(Int(t.speedKmh)) km/h"), MetaRow("Heading", "\(Int(t.heading))°"),
                      MetaRow("Status", t.status), MetaRow("Next stop", t.nextStop), MetaRow("Source", t.operatorName == "Amtrak" ? "Amtraker" : "Digitraffic")],
               url: nil, viewDistance: 12_000, imageURL: nil, heading: t.heading)
    }

    static func from(_ a: Airport) -> Entity {
        Entity(id: "apt-\(a.id)", kind: .airport, title: a.iata.isEmpty ? a.id : "\(a.iata) · \(a.id)", subtitle: a.name,
               summary: "\(a.type.replacingOccurrences(of: "_", with: " ")) · \(a.city), \(a.country) · elev \(Int(a.elevationFt)) ft",
               lat: a.lat, lon: a.lon, time: nil,
               meta: [MetaRow("ICAO", a.id), MetaRow("IATA", a.iata.isEmpty ? "—" : a.iata), MetaRow("Type", a.type), MetaRow("Elevation", "\(Int(a.elevationFt)) ft"),
                      MetaRow("City", a.city), MetaRow("Country", a.country), MetaRow("Source", "OurAirports")],
               url: "https://ourairports.com/airports/\(a.id)/", viewDistance: 9_000)
    }

    static func from(_ w: WxStation) -> Entity {
        let t = w.tempC.map { String(format: "%.0f°C", $0) } ?? "—"
        let wind = (w.windDir != nil && w.windKt != nil) ? String(format: "%03.0f°/%.0fkt", w.windDir!, w.windKt!) : "—"
        let p = w.pressureHpa.map { String(format: "%.0f hPa", $0) } ?? "—"
        return Entity(id: "wx-\(w.id)", kind: .station, title: w.id, subtitle: "\(w.kind) · \(w.name)",
               summary: "\(t) · wind \(wind) · \(p)" + (w.visibilityMi.map { String(format: " · vis %.0f mi", $0) } ?? ""),
               lat: w.lat, lon: w.lon, time: w.time,
               meta: [MetaRow("Temperature", t), MetaRow("Wind", wind), MetaRow("Pressure", p), MetaRow("Raw", w.raw), MetaRow("Source", w.kind == "METAR" ? "aviationweather.gov" : "NOAA NDBC")],
               url: nil, viewDistance: 20_000)
    }

    static func from(_ h: HazardAlert) -> Entity {
        Entity(id: "alert-\(h.id)", kind: .alert, title: h.event, subtitle: "\(h.source) · \(h.severity) · \(h.area)",
               summary: h.headline,
               lat: h.lat, lon: h.lon, time: h.starts,
               meta: [MetaRow("Severity", h.severity), MetaRow("Area", h.area), MetaRow("Starts", h.starts.map(Fmt.time) ?? "—"), MetaRow("Ends", h.ends.map(Fmt.time) ?? "—"), MetaRow("Source", h.source)],
               url: h.url, viewDistance: 150_000)
    }

    static func from(_ f: ScannerFeed) -> Entity {
        Entity(id: "scan-\(f.id)", kind: .scanner, title: f.title, subtitle: f.genre,
               summary: "\(f.listeners) listening · live dispatch audio",
               lat: f.lat, lon: f.lon, time: nil,
               meta: [MetaRow("Feed ID", f.id), MetaRow("Genre", f.genre), MetaRow("Listeners", "\(f.listeners)"), MetaRow("Source", "Broadcastify")],
               url: "https://www.broadcastify.com/listen/feed/\(f.id)", viewDistance: 40_000)
    }

    static func from(_ p: Peak) -> Entity {
        Entity(id: "peak-\(p.id)", kind: .peak, title: p.name, subtitle: "Summit",
               summary: "\(Int(p.elevationM)) m · \(Int(p.elevationM * 3.281)) ft",
               lat: p.lat, lon: p.lon, time: nil,
               meta: [MetaRow("Elevation", "\(Int(p.elevationM)) m"), MetaRow("Source", "OpenStreetMap")],
               url: nil, viewDistance: 6_000)
    }

    static func from(_ s: StormCell) -> Entity {
        Entity(id: "storm-\(s.id)", kind: .storm, title: "Storm cell", subtitle: "Radar-derived (estimate)",
               summary: String(format: "moving %03.0f° at %.0f km/h · intensity %.0f%%", s.headingDeg, s.speedKmh, s.intensity * 100),
               lat: s.lat, lon: s.lon, time: Date(),
               meta: [MetaRow("Heading", "\(Int(s.headingDeg))°"), MetaRow("Speed", "\(Int(s.speedKmh)) km/h"), MetaRow("Source", "RainViewer frames")],
               url: nil, viewDistance: 120_000, imageURL: nil, heading: s.headingDeg)
    }

    static func from(_ c: Cable) -> Entity {
        let mid = c.segments.first.flatMap { $0.count > 0 ? $0[$0.count / 2] : nil } ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        return Entity(
            id: "cable-\(c.id)",
            kind: .cable,
            title: c.name,
            subtitle: "Submarine cable",
            summary: "\(c.segments.count) segment(s) · \(c.segments.reduce(0) { $0 + $1.count }) vertices",
            lat: mid.latitude, lon: mid.longitude, time: nil,
            meta: [MetaRow("Cable ID", c.id), MetaRow("Source", "TeleGeography")],
            url: "https://www.submarinecablemap.com/submarine-cable/\(c.id)",
            viewDistance: 2_000_000)
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
                MetaRow("Source", "wheretheiss.at")
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
}

struct ParcelRecord: Identifiable, Equatable {
    let id: String
    let osmRecordID: String
    let title: String
    let address: String
    let owner: String?
    let lat: Double
    let lon: Double
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


extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension Optional where Wrapped == String {
    /// nil or "" -> fallback, otherwise the wrapped string.
    func ifEmpty(_ fallback: String) -> String {
        switch self {
        case .some(let v) where !v.isEmpty: return v
        default: return fallback
        }
    }
}
