import Foundation
import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import UserNotifications
import ActivityKit
import CoreLocation

// MARK: - Radio player

@MainActor
final class RadioPlayer: ObservableObject {
    @Published var current: RadioStation?
    @Published var playing = false
    private var player: AVPlayer?

    func play(_ st: RadioStation) {
        guard let url = URL(string: st.url_resolved) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
        current = st
        playing = true
    }
    func toggle() {
        guard let p = player else { return }
        if playing { p.pause() } else { p.play() }
        playing.toggle()
    }
    func stop() {
        player?.pause(); player = nil; playing = false; current = nil
    }
}

// MARK: - Alerts (local notifications)

@MainActor
final class Alerts {
    static let shared = Alerts()
    private var fired = Set<String>()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func fire(id: String, title: String, body: String) {
        guard !fired.contains(id) else { return }
        fired.insert(id)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func schedule(id: String, title: String, body: String, at date: Date) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Live Activity

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<TrackActivityAttributes>?

    func start(_ e: Entity) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attrs = TrackActivityAttributes(title: e.title, kind: e.kind.label)
        let state = TrackActivityAttributes.ContentState(lat: e.lat, lon: e.lon, summary: e.summary, updated: Date())
        activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil), pushType: nil)
    }

    func update(_ e: Entity, coord: CLLocationCoordinate2D) {
        guard let a = activity else { return }
        let state = TrackActivityAttributes.ContentState(lat: coord.latitude, lon: coord.longitude, summary: e.summary, updated: Date())
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}

// MARK: - QR

enum QR {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - ISS pass prediction (ground-distance approximation from SGP4)

enum PassPredictor {
    /// Approximate passes over an observer in the next `hours`; elevation from geometry (no refraction).
    static func passes(_ sat: SGP4, observer: CLLocationCoordinate2D, hours: Double = 24, minElevation: Double = 10) -> [ISSPass] {
        var out: [ISSPass] = []
        let step = 30.0
        var t = Date()
        let end = t.addingTimeInterval(hours * 3600)
        var inPass = false
        var start = t, peak = t, maxEl = -90.0, minGround = 1e9
        while t < end {
            if let g = sat.geodetic(at: t) {
                let ground = observer.distance(to: CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon)) / 1000
                let el = elevation(groundKm: ground, altKm: g.altKm)
                if el >= minElevation {
                    if !inPass { inPass = true; start = t; maxEl = el; peak = t; minGround = ground }
                    if el > maxEl { maxEl = el; peak = t; minGround = ground }
                } else if inPass {
                    inPass = false
                    out.append(ISSPass(start: start, peak: peak, end: t, maxElevationDeg: maxEl, minGroundKm: minGround))
                    if out.count >= 6 { break }
                }
            }
            t = t.addingTimeInterval(step)
        }
        return out
    }

    private static func elevation(groundKm: Double, altKm: Double) -> Double {
        let R = 6371.0
        let theta = groundKm / R
        let r = R + altKm
        // observer to satellite vector in the plane
        let x = r * sin(theta)
        let y = r * cos(theta) - R
        return atan2(y, x) * 180 / .pi   // geometric elevation above local horizon
    }
}

// MARK: - Launch replay (reconstructed estimate)

struct LaunchReplay {
    let launch: Launch
    let azimuth: Double
    static let duration: Double = 560

    init(_ l: Launch) {
        launch = l
        // Coarse azimuth priors: Vandenberg / polar sites go south, everything else goes east.
        if (l.lat > 34 && l.lat < 35 && l.lon < -120) || l.lat > 60 { azimuth = 185 }
        else if l.lat < -30 { azimuth = 90 }
        else { azimuth = l.lat > 40 ? 100 : 60 }
    }

    /// Ground-track point + altitude at T+seconds.
    func state(at t: Double) -> (coord: CLLocationCoordinate2D, altKm: Double, speedKmh: Double, phase: String) {
        let tt = max(0, min(t, LaunchReplay.duration))
        let f = tt / LaunchReplay.duration
        let downrange = pow(f, 1.7) * 1_650_000            // meters
        let alt = tt < 150 ? 0.0035 * tt * tt : min(200, 78 + (tt - 150) * 0.3)
        let speed = 200 + f * 27_000
        let phase = tt < 8 ? "LIFTOFF" : tt < 70 ? "MAX-Q" : tt < 150 ? "MECO" : tt < 170 ? "STAGE SEP" : tt < 500 ? "SES-1" : "SECO · ORBIT"
        return (launch.coord.moved(meters: downrange, bearing: azimuth), alt, speed, phase)
    }

    func track(upTo t: Double) -> [CLLocationCoordinate2D] {
        stride(from: 0, through: max(0, min(t, LaunchReplay.duration)), by: 8).map { state(at: $0).coord }
    }
}

// MARK: - Scene files (.gev JSON)

enum SceneIO {
    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func save(_ s: SceneFile) -> URL? {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(s) else { return nil }
        let safe = s.name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "scene" : safe).gev")
        try? d.write(to: url, options: .atomic)
        return url
    }
    static func load(_ url: URL) -> SceneFile? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SceneFile.self, from: d)
    }
    static func list() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "gev" } ?? []
    }
}

// MARK: - Geodesy helpers

enum Geo {
    static func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, points n: Int = 64) -> [CLLocationCoordinate2D] {
        let la1 = a.latitude * .pi / 180, lo1 = a.longitude * .pi / 180
        let la2 = b.latitude * .pi / 180, lo2 = b.longitude * .pi / 180
        let d = 2 * asin(sqrt(pow(sin((la1 - la2) / 2), 2) + cos(la1) * cos(la2) * pow(sin((lo1 - lo2) / 2), 2)))
        guard d > 0 else { return [a, b] }
        return (0...n).map { i in
            let f = Double(i) / Double(n)
            let A = sin((1 - f) * d) / sin(d), B = sin(f * d) / sin(d)
            let x = A * cos(la1) * cos(lo1) + B * cos(la2) * cos(lo2)
            let y = A * cos(la1) * sin(lo1) + B * cos(la2) * sin(lo2)
            let z = A * sin(la1) + B * sin(la2)
            return CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
        }
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dl)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Viewshed cone polygon for a camera: estimated heading, 60° FOV, range meters.
    static func cone(at c: CLLocationCoordinate2D, heading: Double, fov: Double = 60, range: Double = 140) -> [CLLocationCoordinate2D] {
        var pts = [c]
        for i in 0...8 {
            let b = heading - fov / 2 + fov * Double(i) / 8
            pts.append(c.moved(meters: range, bearing: b))
        }
        return pts
    }

    static func stableHeading(for id: String) -> Double {
        Double(id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 100_000 } % 360)
    }
}
