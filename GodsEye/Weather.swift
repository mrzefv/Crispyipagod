import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - Radar compositor: stitches RainViewer tiles for the current viewport into one image

struct RadarComposite: Equatable {
    let image: UIImage
    let nw: CLLocationCoordinate2D   // top-left corner
    let se: CLLocationCoordinate2D   // bottom-right corner
    let frame: RadarFrame
    static func == (a: RadarComposite, b: RadarComposite) -> Bool { a.frame == b.frame && a.nw.latitude == b.nw.latitude && a.nw.longitude == b.nw.longitude }
}

enum TileMath {
    static func zoom(forDistance d: Double, width: Double) -> Int {
        // meters-per-pixel ≈ d / width (rough for MapKit camera distance); tiles at 256 px
        let mpp = max(d / max(width, 1), 1)
        let z = log2(156_543.03 / mpp)
        return max(1, min(9, Int(z.rounded())))
    }
    static func tile(_ c: CLLocationCoordinate2D, z: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(z))
        let x = Int((c.longitude + 180) / 360 * n)
        let latR = max(-85, min(85, c.latitude)) * .pi / 180
        let y = Int((1 - log(tan(latR) + 1 / cos(latR)) / .pi) / 2 * n)
        return (max(0, min(Int(n) - 1, x)), max(0, min(Int(n) - 1, y)))
    }
    static func coord(x: Int, y: Int, z: Int) -> CLLocationCoordinate2D {
        let n = pow(2.0, Double(z))
        let lon = Double(x) / n * 360 - 180
        let latR = atan(sinh(.pi * (1 - 2 * Double(y) / n)))
        return CLLocationCoordinate2D(latitude: latR * 180 / .pi, longitude: lon)
    }
}

@MainActor
final class RadarEngine: ObservableObject {
    @Published var frames: [RadarFrame] = []
    @Published var index = 0
    @Published var composite: RadarComposite?
    @Published var satComposite: RadarComposite?
    @Published var playing = false
    @Published var loading = false
    private var cache: [String: UIImage] = [:]
    private var playTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?

    var radarFrames: [RadarFrame] { frames.filter { $0.kind == "radar" } }
    var satFrames: [RadarFrame] { frames.filter { $0.kind == "satellite" } }
    var current: RadarFrame? { radarFrames.indices.contains(index) ? radarFrames[index] : radarFrames.last }
    var latestIndex: Int { max(0, radarFrames.lastIndex(where: { $0.time <= Date() }) ?? radarFrames.count - 1) }

    func load() async {
        if let f = try? await Feeds.shared.radarFrames() {
            frames = f
            index = latestIndex
        }
    }

    func rebuild(center: CLLocationCoordinate2D, distance: Double, viewWidth: Double, radar: Bool, sat: Bool) {
        buildTask?.cancel()
        guard radar || sat else { composite = nil; satComposite = nil; return }
        buildTask = Task { [weak self] in
            guard let self else { return }
            self.loading = true
            defer { self.loading = false }
            if radar, let fr = self.current { self.composite = await self.build(fr, center: center, distance: distance, viewWidth: viewWidth) }
            else { self.composite = nil }
            if sat, let fr = self.satFrames.last { self.satComposite = await self.build(fr, center: center, distance: distance, viewWidth: viewWidth) }
            else { self.satComposite = nil }
        }
    }

    func build(_ frame: RadarFrame, center: CLLocationCoordinate2D, distance: Double, viewWidth: Double) async -> RadarComposite? {
        let z = TileMath.zoom(forDistance: distance, width: viewWidth)
        let cT = TileMath.tile(center, z: z)
        let cols = 4, rows = 6
        let x0 = cT.x - cols / 2, y0 = cT.y - rows / 2
        let n = Int(pow(2.0, Double(z)))
        let size = CGSize(width: 256 * cols, height: 256 * rows)
        let renderer = UIGraphicsImageRenderer(size: size)
        var tiles: [(Int, Int, UIImage)] = []
        await withTaskGroup(of: (Int, Int, UIImage?).self) { group in
            for i in 0..<cols { for j in 0..<rows {
                let x = ((x0 + i) % n + n) % n, y = y0 + j
                guard y >= 0, y < n else { continue }
                let key = "\(frame.id)/\(z)/\(x)/\(y)"
                if let img = cache[key] { tiles.append((i, j, img)); continue }
                group.addTask {
                    guard let url = Feeds.tileURL(frame, z: z, x: x, y: y), let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) else { return (i, j, nil) }
                    return (i, j, img)
                }
            } }
            for await (i, j, img) in group {
                if let img { tiles.append((i, j, img)); cache["\(frame.id)/\(z)/\(((x0 + i) % n + n) % n)/\(y0 + j)"] = img }
            }
        }
        if cache.count > 400 { cache = [:] }
        guard !Task.isCancelled, !tiles.isEmpty else { return nil }
        let img = renderer.image { ctx in
            for (i, j, t) in tiles { t.draw(in: CGRect(x: 256 * i, y: 256 * j, width: 256, height: 256)) }
        }
        return RadarComposite(image: img, nw: TileMath.coord(x: x0, y: y0, z: z), se: TileMath.coord(x: x0 + cols, y: y0 + rows, z: z), frame: frame)
    }

    func togglePlay(rebuild: @escaping () -> Void) {
        if playing { playing = false; playTask?.cancel(); return }
        playing = true
        playTask?.cancel()
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.playing else { return }
                self.index = (self.index + 1) % max(1, self.radarFrames.count)
                rebuild()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    // MARK: Storm tracking (blob centroid drift across the last frames)

    func trackStorm(near tap: CLLocationCoordinate2D, center: CLLocationCoordinate2D, distance: Double, viewWidth: Double) async -> StormCell? {
        let recent = Array(radarFrames.filter { $0.time <= Date() }.suffix(3))
        guard recent.count >= 2 else { return nil }
        var centroids: [(Date, CLLocationCoordinate2D, Double)] = []
        for fr in recent {
            guard let comp = await build(fr, center: center, distance: distance, viewWidth: viewWidth),
                  let c = RadarEngine.blobCentroid(comp, near: tap) else { continue }
            centroids.append((fr.time, c.0, c.1))
        }
        guard let first = centroids.first, let last = centroids.last, centroids.count >= 2 else { return nil }
        let dt = max(60, last.0.timeIntervalSince(first.0))
        let dist = first.1.distance(to: last.1)
        let hdg = Geo.bearing(from: first.1, to: last.1)
        return StormCell(id: String(format: "%.2f-%.2f", tap.latitude, tap.longitude), lat: last.1.latitude, lon: last.1.longitude,
                         speedKmh: dist / dt * 3.6, headingDeg: dist < 500 ? 0 : hdg, intensity: last.2, history: centroids.map { $0.1 })
    }

    /// Finds the precipitation blob nearest `near` in a composite; returns centroid + mean intensity.
    nonisolated static func blobCentroid(_ comp: RadarComposite, near: CLLocationCoordinate2D) -> (CLLocationCoordinate2D, Double)? {
        guard let cg = comp.image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        let cell = 8
        let cw = w / cell, ch = h / cell
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var grid = [Double](repeating: 0, count: cw * ch)
        for gy in 0..<ch { for gx in 0..<cw {
            var acc = 0.0, cnt = 0.0
            var y = gy * cell
            while y < min(h, (gy + 1) * cell) {
                var x = gx * cell
                while x < min(w, (gx + 1) * cell) {
                    let o = y * bpr + x * bpp
                    let a = bpp == 4 ? Double(ptr[o + 3]) / 255 : 1
                    if a > 0.2 { acc += a; cnt += 1 }
                    x += 2
                }
                y += 2
            }
            grid[gy * cw + gx] = cnt > 0 ? acc / cnt : 0
        } }
        // pixel position of the tap
        let fx = (near.longitude - comp.nw.longitude) / (comp.se.longitude - comp.nw.longitude)
        func mercY(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        let fy = (mercY(comp.nw.latitude) - mercY(near.latitude)) / (mercY(comp.nw.latitude) - mercY(comp.se.latitude))
        let tx = Int(fx * Double(cw)), ty = Int(fy * Double(ch))
        guard tx >= 0, ty >= 0, tx < cw, ty < ch else { return nil }
        // flood fill from the strongest cell within a radius
        var best = (-1, -1, 0.0)
        for dy in -6...6 { for dx in -6...6 {
            let x = tx + dx, y = ty + dy
            guard x >= 0, y >= 0, x < cw, y < ch else { continue }
            if grid[y * cw + x] > best.2 { best = (x, y, grid[y * cw + x]) }
        } }
        guard best.2 > 0.25 else { return nil }
        var visited = Set<Int>(), stack = [best.1 * cw + best.0]
        var sx = 0.0, sy = 0.0, sw = 0.0
        while let i = stack.popLast(), visited.count < 4000 {
            guard visited.insert(i).inserted, grid[i] > 0.25 else { continue }
            let x = i % cw, y = i / cw
            sx += Double(x) * grid[i]; sy += Double(y) * grid[i]; sw += grid[i]
            if x > 0 { stack.append(i - 1) }; if x < cw - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - cw) }; if y < ch - 1 { stack.append(i + cw) }
        }
        guard sw > 0 else { return nil }
        let px = sx / sw / Double(cw), py = sy / sw / Double(ch)
        let lon = comp.nw.longitude + px * (comp.se.longitude - comp.nw.longitude)
        let my = mercY(comp.nw.latitude) - py * (mercY(comp.nw.latitude) - mercY(comp.se.latitude))
        let lat = (2 * atan(exp(my)) - .pi / 2) * 180 / .pi
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), min(1, sw / Double(visited.count)))
    }
}

// MARK: - Radar image pinned to the map with MapProxy (top-down only)

struct RadarOverlayView: View {
    let composite: RadarComposite
    let proxy: MapProxy
    let opacity: Double
    let heading: Double
    let pitch: Double

    var body: some View {
        if pitch < 12,
           let p1 = proxy.convert(composite.nw, to: .local),
           let p2 = proxy.convert(composite.se, to: .local) {
            let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            Image(uiImage: composite.image)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(opacity)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Solar geometry: subsolar point, night terminator, sunlit test

enum Solar {
    static func subsolar(_ date: Date) -> CLLocationCoordinate2D {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * .pi / 180
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180
        let eps = (23.439 - 0.0000004 * n) * .pi / 180
        let dec = asin(sin(eps) * sin(lambda))
        let ra = atan2(cos(eps) * sin(lambda), cos(lambda))
        let gmst = SGP4.gmst(date)
        var lon = (ra - gmst) * 180 / .pi
        lon = lon.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }; if lon < -180 { lon += 360 }
        return CLLocationCoordinate2D(latitude: dec * 180 / .pi, longitude: lon)
    }

    /// Night-side polygon (antisolar hemisphere), closed at the pole away from the sun.
    static func nightPolygon(_ date: Date) -> [CLLocationCoordinate2D] {
        let ss = subsolar(date)
        let anti = CLLocationCoordinate2D(latitude: -ss.latitude, longitude: ss.longitude + 180 > 180 ? ss.longitude - 180 : ss.longitude + 180)
        var pts: [CLLocationCoordinate2D] = []
        for i in 0...72 {
            let b = Double(i) * 5
            pts.append(anti.moved(meters: 10_007_000, bearing: b))   // 90° great-circle from antisolar point
        }
        return pts
    }

    static func sunElevation(at c: CLLocationCoordinate2D, date: Date) -> Double {
        let ss = subsolar(date)
        let d = c.distance(to: ss) / 6_371_000
        return 90 - d * 180 / .pi
    }

    /// Satellite sunlit test: angle between sat and antisolar direction vs Earth's shadow cylinder.
    static func isSunlit(satLat: Double, satLon: Double, altKm: Double, date: Date) -> Bool {
        let ss = subsolar(date)
        let ang = CLLocationCoordinate2D(latitude: satLat, longitude: satLon).distance(to: ss) / 6_371_000
        if ang < .pi / 2 { return true }
        let r = 6371 + altKm
        return r * sin(ang) > 6371
    }
}
