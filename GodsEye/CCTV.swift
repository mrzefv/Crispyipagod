import SwiftUI
import AVKit

@MainActor
final class CamRecorder {
    var watching: Set<String> {
        didSet {
            let sorted = Array(watching).sorted()
            ud.set(sorted, forKey: watchingKey)
            onChange?()
            start()
        }
    }
    var frameCounts: [String: Int] = [:] { didSet { onChange?() } }
    var storageBytes: Int64 = 0 { didSet { onChange?() } }
    var intervalSeconds: UInt64 {
        didSet {
            ud.set(Int(intervalSeconds), forKey: intervalKey)
            onChange?()
            start()
        }
    }
    var cameraLookup: ((String) -> Camera?)?
    var onChange: (() -> Void)?

    private let ud = UserDefaults.standard
    private let fm = FileManager.default
    private let watchingKey = "cctvWatching"
    private let intervalKey = "cctvIntervalSeconds"
    private var timer: Timer?
    private let maxFramesPerCamera = 400

    init() {
        watching = Set(ud.stringArray(forKey: watchingKey) ?? [])
        let storedInterval = ud.integer(forKey: intervalKey)
        intervalSeconds = UInt64(storedInterval == 0 ? 20 : storedInterval)
        refreshMetrics()
    }

    deinit { timer?.invalidate() }

    func start() {
        timer?.invalidate()
        timer = nil
        refreshMetrics()
        guard !watching.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.captureWatched()
            }
        }
        Task { await captureWatched() }
    }

    func toggleWatch(_ id: String) {
        if watching.contains(id) {
            watching.remove(id)
        } else {
            watching.insert(id)
        }
    }

    func clearAll() {
        try? fm.removeItem(at: rootURL)
        frameCounts = [:]
        storageBytes = 0
    }

    private func captureWatched() async {
        for id in watching.sorted() {
            guard let cam = cameraLookup?(id),
                  let url = cacheBustedURL(from: cam.imageURL) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                saveFrame(data, for: id)
            } catch {
                continue
            }
        }
        refreshMetrics()
    }

    private func saveFrame(_ data: Data, for id: String) {
        let dir = cameraDirectory(for: id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let frames = frameURLs(in: dir)
        if let last = frames.last, let lastData = try? Data(contentsOf: last), lastData == data { return }
        let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        try? data.write(to: url, options: .atomic)
        let updated = frameURLs(in: dir)
        if updated.count > maxFramesPerCamera {
            for extra in updated.prefix(updated.count - maxFramesPerCamera) {
                try? fm.removeItem(at: extra)
            }
        }
    }

    private func refreshMetrics() {
        var counts: [String: Int] = [:]
        var totalBytes: Int64 = 0
        let root = rootURL
        if let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for dir in dirs where dir.hasDirectoryPath {
                let frames = frameURLs(in: dir)
                counts[dir.lastPathComponent] = frames.count
                for frame in frames {
                    totalBytes += Int64((try? frame.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
        }
        frameCounts = counts
        storageBytes = totalBytes
    }

    private func frameURLs(in dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]))?
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private func cameraDirectory(for id: String) -> URL {
        rootURL.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private var rootURL: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base.appendingPathComponent("cctv-frames", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        return root
    }

    private func cacheBustedURL(from string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return URL(string: string) }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "t" }
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 / 6))))
        components.queryItems = items
        return components.url
    }
}

struct CameraLiveView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    let rec: CamRecorder
    let camera: Camera

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var imageTick = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                mediaCard
                infoCard
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 60)
            .padding(.bottom, 20)

            controls
        }
        .task(id: camera.id) { startPlayback() }
        .task(id: camera.id) {
            guard !camera.isLiveVideo, camera.videoURL == nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                imageTick += 1
            }
        }
        .onAppear {
            s.fly(to: camera.coord,
                  distance: 1_200,
                  pitch: 72,
                  heading: camera.heading ?? Geo.stableHeading(for: camera.id),
                  duration: 0.8)
        }
        .onDisappear { stopPlayback() }
        .statusBarHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            CircleButton(system: "xmark") { dismiss() }
            Spacer()
            if let prev = s.neighborCamera(of: camera, forward: false) {
                CircleButton(system: "chevron.left") { s.liveCamera = prev }
            }
            CircleButton(system: rec.watching.contains(camera.id) ? "record.circle.fill" : "record.circle") {
                rec.toggleWatch(camera.id)
            }
            if let next = s.neighborCamera(of: camera, forward: true) {
                CircleButton(system: "chevron.right") { s.liveCamera = next }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var mediaCard: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
            } else {
                AsyncImage(url: stillURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Label("Camera offline", systemImage: "video.slash")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundStyle(.secondary)
                    default:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topLeading) {
            Text(camera.isLiveVideo ? "LIVE HLS" : camera.videoURL != nil ? "LIVE CLIP" : "LIVE STILL")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(10)
        }
        .modifier(SensorFilter(mode: s.sensor))
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(camera.name)
                .font(.system(size: 20, weight: .bold))
            Text("\(camera.source) · \(camera.region.ifEmpty("Public CCTV"))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(Fmt.coord(camera.lat, camera.lon))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                Label("\(rec.frameCounts[camera.id] ?? 0) frames", systemImage: "film.stack")
                Spacer()
                if !camera.available { Label("Offline", systemImage: "wifi.slash") }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var stillURL: URL? {
        guard var components = URLComponents(string: camera.imageURL) else { return URL(string: camera.imageURL) }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "t" }
        items.append(URLQueryItem(name: "t", value: "\(imageTick)"))
        components.queryItems = items
        return components.url
    }

    private func startPlayback() {
        stopPlayback()
        guard let urlString = camera.streamURL ?? camera.videoURL,
              let url = URL(string: urlString) else { return }
        let player = AVPlayer(url: url)
        if camera.streamURL == nil {
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }
        self.player = player
        player.play()
    }

    private func stopPlayback() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player?.pause()
        player = nil
    }
}

private struct CircleButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
