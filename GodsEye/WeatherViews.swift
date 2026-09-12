import SwiftUI
import Charts
import MapKit

// MARK: - Radar sheet (frame scrubber)

struct RadarSheet: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var r: RadarEngine

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.current.map { $0.time > Date() ? "NOWCAST" : "RADAR" } ?? "RADAR").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(r.current.map { $0.time > Date() } ?? false ? .orange : s.accent)
                    Text(r.current.map { Fmt.time($0.time) } ?? "loading…").font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text("\(r.radarFrames.count) frames · 2h past + 30m nowcast · " + (s.pitch < 12 ? "pinned to map" : "tilt down to view")).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if r.loading { ProgressView() }
                Button { r.togglePlay { s.rebuildRadar() } } label: { Image(systemName: r.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36)) }.buttonStyle(.plain)
            }
            Slider(value: Binding(get: { Double(r.index) }, set: { r.index = Int($0); s.rebuildRadar() }), in: 0...Double(max(0, r.radarFrames.count - 1)), step: 1)
                .tint(s.accent)
            HStack {
                Text("-2H").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Toggle("IR clouds", isOn: Binding(get: { s.layers.contains(.satir) }, set: { if $0 { s.layers.insert(.satir) } else { s.layers.remove(.satir) } })).font(.system(size: 11, design: .monospaced)).toggleStyle(.button)
                Toggle("Wind", isOn: Binding(get: { s.layers.contains(.wind) }, set: { if $0 { s.layers.insert(.wind) } else { s.layers.remove(.wind) } })).font(.system(size: 11, design: .monospaced)).toggleStyle(.button)
                Spacer()
                Text("+30M").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Opacity").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: $s.radarOpacity, in: 0.2...1).tint(.secondary)
            }
            Text("Tap the map on a storm, then “Track storm” in its sheet — the app compares the last three frames and projects the cell's drift.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - Weather station time-series

struct StationSheet: View {
    @EnvironmentObject var s: AppState
    let station: WxStation
    @State private var series: [(Date, Double, Double, Double)] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(station.id) · \(station.name)").font(.system(size: 14, weight: .bold, design: .monospaced)).lineLimit(1)
            Text(Entity.from(station).summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity) }
            else if series.isEmpty { Text("No history available").foregroundStyle(.secondary) }
            else {
                chart("TEMP °C", series.map { ($0.0, $0.1) }, color: .orange)
                chart("WIND kt", series.map { ($0.0, $0.2) }, color: .cyan)
                chart("PRESSURE hPa", series.map { ($0.0, $0.3) }, color: .mint)
            }
            Text(station.raw).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(16)
        .task {
            series = (try? await Feeds.shared.stationHistory(at: station.coord)) ?? []
            loading = false
        }
    }

    private func chart(_ title: String, _ pts: [(Date, Double)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.0), y: .value("v", p.1)).foregroundStyle(color)
                }
                RuleMark(x: .value("now", Date())).foregroundStyle(.white.opacity(0.3))
            }
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 70)
        }
    }
}

// MARK: - Terrain profile between the two Measure points

struct ProfileSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TERRAIN PROFILE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            if s.profileLoading { ProgressView().frame(maxWidth: .infinity) }
            else if s.profile.isEmpty { Text("Measure two points, then open the profile.").foregroundStyle(.secondary) }
            else {
                let elevs = s.profile.map(\.elev)
                Text(String(format: "%.1f km · min %.0f m · max %.0f m · gain %.0f m", s.profile.last?.dist ?? 0, elevs.min() ?? 0, elevs.max() ?? 0, gain()))
                    .font(.system(size: 11, design: .monospaced))
                Chart {
                    ForEach(Array(s.profile.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("km", p.dist), y: .value("m", p.elev)).foregroundStyle(s.accent.opacity(0.25))
                        LineMark(x: .value("km", p.dist), y: .value("m", p.elev)).foregroundStyle(s.accent)
                    }
                }
                .chartXAxisLabel("km").chartYAxisLabel("m")
                .frame(height: 180)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func gain() -> Double {
        var g = 0.0
        for i in 1..<s.profile.count where s.profile[i].elev > s.profile[i - 1].elev { g += s.profile[i].elev - s.profile[i - 1].elev }
        return g
    }
}

// MARK: - Sun & space weather panel

struct SpaceSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        let sw = s.space
        let ss = Solar.subsolar(Date())
        VStack(alignment: .leading, spacing: 10) {
            Text("SUN & SPACE WEATHER").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                tile("Kp index", String(format: "%.1f", sw.kp), sw.stormLevel, color: sw.kp >= 5 ? .red : sw.kp >= 4 ? .orange : s.accent)
                tile("X-ray", sw.xrayClass, String(format: "%.1e W/m²", sw.xrayFlux), color: sw.xrayClass.hasPrefix("X") || sw.xrayClass.hasPrefix("M") ? .orange : .mint)
                tile("Solar wind", String(format: "%.0f km/s", sw.solarWindKmS), String(format: "%.1f p/cm³", sw.density), color: .cyan)
                tile("Subsolar", Fmt.coord(ss.latitude, ss.longitude), "sun directly overhead", color: .yellow)
                if let me = s.location.coordinate {
                    let el = Solar.sunElevation(at: me, date: Date())
                    tile("Sun at you", String(format: "%.0f°", el), el < -6 ? "night" : el < 0 ? "twilight" : "day", color: el < 0 ? .indigo : .yellow)
                    let visible = s.satellites.filter { Solar.isSunlit(satLat: $0.lat, satLon: $0.lon, altKm: $0.altKm, date: Date()) && $0.coord.distance(to: me) < 1_500_000 }
                    tile("Sats visible", "\(visible.count)", el < -6 ? "sunlit & overhead" : "needs darkness", color: .cyan)
                    let maxA = s.auroraPoints.filter { $0.coord.distance(to: me) < 600_000 }.map(\.prob).max() ?? 0
                    tile("Aurora", "\(Int(maxA))%", "probability within 600 km", color: maxA > 30 ? .green : .secondary)
                }
                tile("Aurora oval", "\(s.auroraPoints.count) pts", "OVATION ≥15%", color: .green)
            }
            if let f = sw.fetched { Text("SWPC \(Fmt.rel.localizedString(for: f, relativeTo: Date()))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary) }
            Button { Task { await s.refreshSpace() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.font(.system(size: 11, weight: .semibold, design: .monospaced)).buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func tile(_ k: String, _ v: String, _ sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }
}

// MARK: - Scanner list

struct ScannerSheet: View {
    @EnvironmentObject var s: AppState
    @State private var manualID = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SCANNER FEEDS").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                    Text(s.scannerNow?.title ?? "Public dispatch audio · Broadcastify top feeds").font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                }
                Spacer()
                if s.scannerNow != nil { Button { s.stopScanner() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)) }.buttonStyle(.plain) }
            }
            HStack {
                TextField("Broadcastify feed ID", text: $manualID).keyboardType(.numberPad).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button("Listen") { s.listen(ScannerFeed(id: manualID, title: "Feed \(manualID)", genre: "Manual", lat: s.center.latitude, lon: s.center.longitude, listeners: 0)) }
                    .disabled(manualID.isEmpty).buttonStyle(.bordered)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if s.scanners.isEmpty {
                Button { Task { await s.refreshScanners() } } label: { Label("Load top feeds", systemImage: "arrow.down.circle") }.buttonStyle(.bordered)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            List(s.scanners.sorted { $0.coord.distance(to: s.center) < $1.coord.distance(to: s.center) }) { f in
                HStack(spacing: 10) {
                    Image(systemName: f.genre == "Fire/EMS" ? "flame" : f.genre == "Police" ? "shield" : "antenna.radiowaves.left.and.right").foregroundStyle(Entity.Kind.scanner.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.system(size: 12, weight: .bold, design: .monospaced)).lineLimit(1)
                        Text("\(f.genre) · \(f.listeners) listening · \(Int(f.coord.distance(to: s.center) / 1000)) km").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { s.listen(f); s.fly(to: f.coord, distance: 30_000, pitch: 40) } label: {
                        Image(systemName: s.scannerNow?.id == f.id ? "speaker.wave.2.fill" : "play.fill")
                    }.buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
        .padding(14)
        .task { if s.scanners.isEmpty { await s.refreshScanners() } }
    }
}
