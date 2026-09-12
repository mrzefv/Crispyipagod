import SwiftUI
import MapKit

// MARK: - Detail sheet

struct DetailSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.openURL) private var openURL
    let entity: Entity
    @State private var imageTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                if entity.kind.trackable { trackRow }
                extraRow
                if let img = entity.imageURL, let url = URL(string: img + "?t=\(imageTick)") { cameraImage(url) }
                summaryBlock
                metaGrid
                if entity.kind == .place { PlaceRecordsView(entity: entity) }
                HStack(spacing: 8) {
                    if let u = entity.url, let url = URL(string: u) {
                        Button { openURL(url) } label: { Label("Source", systemImage: "arrow.up.right.square") }
                    }
                    Button {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: entity.coord))
                        item.name = entity.title
                        item.openInMaps(launchOptions: [MKLaunchOptionsMapTypeKey: MKMapType.satellite.rawValue])
                    } label: { Label("Apple Maps", systemImage: "map") }
                    if entity.kind != .camera {
                        Button { s.handoffToNearestCamera(from: entity) } label: { Label("Nearest cam", systemImage: "video") }
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .buttonStyle(.bordered)
                Text("Public-source data. May be delayed, modeled, or wrong. Not for navigation or safety-critical use.")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(entity.kind.color.opacity(0.15))
                Image(systemName: entity.kind.icon).font(.system(size: 22, weight: .bold)).foregroundStyle(entity.kind.color)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(entity.kind.label).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(entity.kind.color)
                Text(entity.title).font(.system(size: 19, weight: .bold, design: .monospaced)).lineLimit(2)
                Text(entity.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                Text(Fmt.coord(entity.lat, entity.lon)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ActionChip(icon: s.isBookmarked(entity) ? "bookmark.fill" : "bookmark",
                       title: s.isBookmarked(entity) ? "Saved" : "Save",
                       active: s.isBookmarked(entity)) { s.toggleBookmark(entity) }
            ActionChip(icon: "clock.arrow.circlepath", title: "Timeline", active: false) { s.openTimeline(at: entity.time) }
            ShareLink(item: entity.shareText + "\n\nOpen in GodsEye: " + s.deepLink) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share").font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }

    private var trackRow: some View {
        HStack(spacing: 8) {
            ActionChip(icon: "scope", title: s.trackedID == entity.id ? "Tracking" : "Track", active: s.trackedID == entity.id) {
                if s.trackedID == entity.id { s.stopTracking() } else { s.track(entity) }
            }
            if entity.kind == .aircraft || entity.kind == .military || entity.kind == .ship {
                ActionChip(icon: "airplane.departure", title: "Cockpit", active: s.trackedID == entity.id && s.chase) {
                    if s.trackedID != entity.id { s.track(entity) }
                    if !s.chase { s.toggleChase() }
                }
            }
        }
    }

    @ViewBuilder private var extraRow: some View {
        if entity.kind == .camera, let cam = s.cameras.first(where: { "cam-\($0.id)" == entity.id }) {
            HStack(spacing: 8) {
                ActionChip(icon: cam.isLiveVideo ? "play.tv" : "eye", title: "Live view", active: true) { s.openLive(cam) }
                ActionChip(icon: s.cctv.watching.contains(cam.id) ? "record.circle.fill" : "record.circle",
                           title: s.cctv.watching.contains(cam.id) ? "Watching" : "Watch",
                           active: s.cctv.watching.contains(cam.id),
                           action: { s.cctv.toggleWatch(cam.id) })
                ActionChip(icon: "film.stack", title: "\(s.cctv.frameCounts[cam.id] ?? 0) frames", active: false) { s.openLive(cam) }
            }
        }
        HStack(spacing: 8) {
            if entity.kind == .place, s.layers.contains(.radar) {
                ActionChip(icon: "cloud.bolt.rain", title: "Track storm", active: false) { s.selected = nil; s.trackStorm(at: entity.coord) }
            }
            if entity.kind == .station, let w = s.stations.first(where: { "wx-\($0.id)" == entity.id }) {
                ActionChip(icon: "chart.xyaxis.line", title: "24h series", active: false) { s.selected = nil; Task { try? await Task.sleep(nanoseconds: 400_000_000); s.showStation = w } }
            }
            if entity.kind == .scanner, let f = s.scanners.first(where: { "scan-\($0.id)" == entity.id }) {
                ActionChip(icon: "speaker.wave.2", title: s.scannerNow?.id == f.id ? "Listening" : "Listen", active: s.scannerNow?.id == f.id) { s.listen(f) }
            }
            if entity.kind == .airport {
                ActionChip(icon: "airplane.arrival", title: "Runways", active: s.layers.contains(.airport)) { s.layers.insert(.airport); s.fly(to: entity.coord, distance: 6_000, pitch: 50) }
            }
            if entity.kind == .peak || entity.kind == .place {
                ActionChip(icon: "mountain.2", title: "Elevation", active: false) { Task { if let e = await s.elevation(at: entity.coord) { s.show(String(format: "Elevation %.0f m · %.0f ft", e, e * 3.281)) } } }
            }
            if entity.kind == .launch, let l = s.launches.first(where: { "ll-\($0.id)" == entity.id }) {
                ActionChip(icon: "play.rectangle", title: "Replay ascent", active: false) { s.startReplay(l) }
            }
            if entity.kind == .radio, let r = s.radioStations.first(where: { "radio-\($0.id)" == entity.id }) {
                ActionChip(icon: "dot.radiowaves.left.and.right", title: s.radio.current?.id == r.id ? "Playing" : "Tune in", active: s.radio.current?.id == r.id) { s.tune(r) }
            }
            ActionChip(icon: "rotate.3d", title: s.orbiting ? "Orbiting" : "Orbit", active: s.orbiting) {
                if s.orbiting { s.stopOrbit() } else { s.fly(to: entity.coord, distance: entity.viewDistance, pitch: 60); s.startOrbit() }
            }
            ActionChip(icon: "qrcode", title: "QR", active: false) { s.selected = nil; Task { try? await Task.sleep(nanoseconds: 400_000_000); s.showQR = true } }
        }
    }

    private func cameraImage(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LIVE STILL").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Button { imageTick += 1 } label: { Image(systemName: "arrow.clockwise").font(.caption) }
            }
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Label("Camera offline", systemImage: "video.slash").frame(maxWidth: .infinity).padding(30)
                default: ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .modifier(SensorFilter(mode: s.sensor))
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUMMARY").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            Text(entity.summary).font(.system(size: 14))
            if let t = entity.time {
                Text("\(Fmt.time(t)) · \(Fmt.rel.localizedString(for: t, relativeTo: Date()))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private var metaGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("METADATA").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(entity.meta) { row in
                    HStack(alignment: .top) {
                        Text(row.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .padding(.vertical, 7)
                    Divider().opacity(0.4)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        }
    }
}

struct ActionChip: View {
    let icon: String
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .foregroundStyle(active ? Color.black : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.08))))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline / playback

struct TimelineView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    private var frac: Binding<Double> {
        Binding(get: { s.cursorFraction }, set: { s.setCursor(fraction: $0) })
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.isLive ? "LIVE" : "REPLAY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                        .foregroundStyle(s.isLive ? s.accent : .orange)
                    Text(Fmt.time(s.effectiveTime))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                }
                Spacer()
                Button { s.goLive() } label: {
                    Text("GO LIVE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(s.isLive ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.tint)))
                        .foregroundStyle(s.isLive ? Color.secondary : Color.black)
                }
                .buttonStyle(.plain)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }

            scrubber

            HStack(spacing: 14) {
                Button { s.jump(forward: false) } label: { Image(systemName: "backward.end.fill") }
                Button { s.togglePlay() } label: { Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40)) }
                Button { s.jump(forward: true) } label: { Image(systemName: "forward.end.fill") }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(s.timelineEvents.count) EVENTS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    Text("\(s.visibleQuakes.count) EQ SHOWN").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .font(.title2)

            if let e = s.focusedEvent ?? s.nearestEvent() {
                Button { s.select(e) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: e.kind.icon).foregroundStyle(e.kind.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                            Text(e.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let t = e.time {
                            Text(Fmt.rel.localizedString(for: t, relativeTo: Date())).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onDisappear { s.pause() }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08)).frame(height: 6).offset(y: 10)
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 26)
                        .offset(x: geo.size.width * s.fraction(of: Date()))
                    ForEach(s.timelineEvents) { e in
                        Circle()
                            .fill(e.kind.color)
                            .frame(width: e.kind == .launch ? 7 : 5, height: e.kind == .launch ? 7 : 5)
                            .offset(x: geo.size.width * s.fraction(of: e.time ?? Date()) - 3, y: 10.5)
                            .opacity(e.id == s.focusedEvent?.id ? 1 : 0.7)
                    }
                    Slider(value: frac, in: 0...1).tint(s.isLive ? s.accent : .orange).frame(height: 26)
                }
            }
            .frame(height: 26)
            HStack {
                Text("-24H").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("NOW").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("+72H").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}
