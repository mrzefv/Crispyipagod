import Foundation
import SwiftUI
import AVKit
import AVFoundation
import UIKit

// MARK: - CamRecorder
// Watches public cameras and stores still frames on disk on a fixed interval.
// Frames live in Documents/CCTV/<camera id>/<unix ms>.jpg

@MainActor
final class CamRecorder: ObservableObject {
    @Published var watching: Set<String> {
        didSet { UserDefaults.standard.set(Array(watching).sorted(), forKey: "cctv.watching"); if !watching.isEmpty { start() } }
    }
    @Published private(set) var frameCounts: [String: Int] = [:]
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var lastCapture: [String: Date] = [:]
    @Published private(set) var running = false

    var intervalSeconds: UInt64 {
        didSet {
            UserDefaults.standard.set(Int(intervalSeconds), forKey: "cctv.interval")
            if loop != nil { stop(); start() }
        }
    }
    var cameraLookup: ((String) -> Camera?)?

    private var loop: Task<Void, Never>?
    private let fm = FileManager.default
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init() {
        let ud = UserDefaults.standard
        watching = Set(ud.stringArray(forKey: "cctv.watching") ?? [])
        let iv = ud.integer(forKey: "cctv.interval")
        intervalSeconds = iv >= 5 ? UInt64(iv) : 20
        rescan()
    }

    // MARK: Storage

    var root: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CCTV", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    private func dir(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        let d = root.appendingPathComponent(safe, isDirectory: true)
        if !fm.fileExists(atPath: d.path) { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        return d
    }

    /// Stored frames for a camera, newest first.
    func frames(for id: String) -> [URL] {
        let d = dir(for: id)
        let items = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func date(of frame: URL) -> Date {
        let ms = Double(frame.deletingPathExtension().lastPathComponent) ?? 0
        return Date(timeIntervalSince1970: ms / 1000)
    }

    func rescan() {
        var counts: [String: Int] = [:]
        var bytes: Int64 = 0
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { $0.pathExtension == "jpg" }
            counts[d.lastPathComponent] = files.count
            for f in files { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        frameCounts = counts
        storageBytes = bytes
    }

    func clear(_ id: String) {
        try? fm.removeItem(at: dir(for: id))
        rescan()
    }

    func clearAll() {
        try? fm.removeItem(at: root)
        rescan()
    }

    // MARK: Control

    func toggleWatch(_ id: String) {
        if watching.contains(id) { watching.remove(id) } else { watching.insert(id) }
    }

    func start() {
        guard loop == nil else { return }
        running = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.watching.isEmpty { self.stop(); return }
                await self.captureAll()
                try? await Task.sleep(nanoseconds: self.intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        running = false
    }

    private func captureAll() async {
        for id in watching {
            guard let cam = cameraLookup?(id), let url = URL(string: cam.imageURL) else { continue }
            await capture(cam, url: url)
        }
    }

    /// Fetch one still and store it. Returns the saved file URL.
    @discardableResult
    func capture(_ cam: Camera, url: URL? = nil) async -> URL? {
        guard let src = url ?? URL(string: cam.imageURL) else { return nil }
        var comps = URLComponents(url: src, resolvingAgainstBaseURL: false)
        var q = comps?.queryItems ?? []
        q.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970))))
        comps?.queryItems = q
        guard let req = comps?.url else { return nil }
        guard let res = try? await session.data(from: req) else { return nil }
        let (data, resp) = res
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count > 512, UIImage(data: data) != nil else { return nil }
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let file = dir(for: cam.id).appendingPathComponent("\(ms).jpg")
        do { try data.write(to: file, options: .atomic) } catch { return nil }
        frameCounts[cam.id, default: 0] += 1
        storageBytes += Int64(data.count)
        lastCapture[cam.id] = Date()
        return file
    }
}

// MARK: - CameraLiveView
// Full-screen live viewer: HLS stream > looped clip > auto-refreshing still.

struct CameraLiveView: View {
    @ObservedObject var rec: CamRecorder
    @State var camera: Camera
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var stillURL: URL?
    @State private var tick = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var frames: [URL] = []
    @State private var reviewing: FrameRef?
    @State private var snapping = false
    @State private var stillInterval: Double = 5
    @State private var loopToken: NSObjectProtocol?

    init(rec: CamRecorder, camera: Camera) {
        _rec = ObservedObject(wrappedValue: rec)
        _camera = State(initialValue: camera)
    }

    private var watched: Bool { rec.watching.contains(camera.id) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                viewer
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16/9, contentMode: .fit)
                    .background(Color.black)
                    .clipped()
                controls
                recordings
                Spacer(minLength: 0)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { load(camera) ; frames = rec.frames(for: camera.id) }
        .onDisappear { teardown() }
        .onChange(of: rec.frameCounts[camera.id] ?? 0) { _, _ in frames = rec.frames(for: camera.id) }
        .fullScreenCover(item: $reviewing) { ref in FrameReview(url: ref.url, date: rec.date(of: ref.url), all: frames, rec: rec, camID: camera.id) }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name).font(.system(size: 14, weight: .bold, design: .monospaced)).lineLimit(1)
                Text("\(camera.source) · \(camera.region.isEmpty ? Fmt.coord(camera.lat, camera.lon) : camera.region)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(camera.isLiveVideo ? Color.red : camera.videoURL != nil ? Color.orange : Color.purple).frame(width: 7, height: 7)
                Text(camera.isLiveVideo ? "LIVE" : camera.videoURL != nil ? "CLIP" : "STILL")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var viewer: some View {
        if let player {
            VideoPlayer(player: player)
                .disabled(false)
        } else {
            ZStack {
                AsyncImage(url: stillURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: offline
                    default: ZStack { Color.black; ProgressView().tint(.purple) }
                    }
                }
                .id(tick)
                VStack {
                    Spacer()
                    HStack {
                        Text("REFRESH \(Int(stillInterval))s")
                        Spacer()
                        Text(Date(), style: .time)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.45))
                }
            }
        }
    }

    private var offline: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.slash").font(.title)
            Text("No image from feed").font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(.secondary)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                LiveButton(icon: "chevron.left", title: "Prev") { jump(forward: false) }
                LiveButton(icon: watched ? "record.circle.fill" : "record.circle", title: watched ? "Watching" : "Watch", active: watched, tint: .red) {
                    rec.toggleWatch(camera.id)
                }
                LiveButton(icon: snapping ? "hourglass" : "camera.shutter.button", title: "Snap") { snap() }
                LiveButton(icon: "chevron.right", title: "Next") { jump(forward: true) }
            }
            HStack(spacing: 8) {
                LiveButton(icon: "location.viewfinder", title: "On map") {
                    dismiss()
                    Task { try? await Task.sleep(nanoseconds: 300_000_000); s.select(Entity.from(camera)) }
                }
                LiveButton(icon: "square.and.arrow.up", title: "Share") { share() }
                if !camera.isLiveVideo && camera.videoURL == nil {
                    Menu {
                        ForEach([2.0, 5.0, 10.0, 30.0], id: \.self) { v in
                            Button("\(Int(v))s refresh") { stillInterval = v; startStillLoop() }
                        }
                    } label: {
                        LiveLabel(icon: "timer", title: "\(Int(stillInterval))s")
                    }
                }
            }
            HStack(spacing: 12) {
                Stat("FRAMES", "\(rec.frameCounts[camera.id] ?? 0)")
                Stat("EVERY", "\(rec.intervalSeconds)s")
                Stat("LAST", rec.lastCapture[camera.id].map { Fmt.rel.localizedString(for: $0, relativeTo: Date()) } ?? "—")
                Stat("HDG", camera.heading.map { "\(Int($0))°" } ?? "est")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private var recordings: some View {
        if !frames.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("RECORDED").font(.system(size: 10, weight: .black, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { rec.clear(camera.id); frames = [] }
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                }
                .padding(.horizontal, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(frames.prefix(200), id: \.self) { f in
                            Button { reviewing = FrameRef(url: f) } label: {
                                ZStack(alignment: .bottomLeading) {
                                    Thumb(url: f).frame(width: 112, height: 63).clipped()
                                    Text(rec.date(of: f), style: .time)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(Color.black.opacity(0.6))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 63)
            }
            .foregroundStyle(.white)
        }
    }

    // MARK: Logic

    private func load(_ cam: Camera) {
        teardown()
        camera = cam
        frames = rec.frames(for: cam.id)
        if let st = cam.streamURL, let u = URL(string: st) {
            let p = AVPlayer(url: u)
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            p.play()
        } else if let v = cam.videoURL, let u = URL(string: v) {
            let item = AVPlayerItem(url: u)
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            player = p
            loopToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
            p.play()
        } else {
            player = nil
            startStillLoop()
        }
    }

    private func startStillLoop() {
        refreshTask?.cancel()
        bumpStill()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(stillInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await MainActor.run { bumpStill() }
            }
        }
    }

    private func bumpStill() {
        guard var c = URLComponents(string: camera.imageURL) else { stillURL = nil; return }
        var q = c.queryItems ?? []
        q.removeAll { $0.name == "_t" }
        q.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970))))
        c.queryItems = q
        stillURL = c.url
        tick += 1
    }

    private func teardown() {
        refreshTask?.cancel(); refreshTask = nil
        player?.pause()
        if let loopToken { NotificationCenter.default.removeObserver(loopToken) }
        loopToken = nil
        player = nil
    }

    private func jump(forward: Bool) {
        guard let n = s.neighborCamera(of: camera, forward: forward) else { s.show("No nearby camera"); return }
        withAnimation(.easeInOut(duration: 0.2)) { load(n) }
    }

    private func snap() {
        guard !snapping else { return }
        snapping = true
        Task {
            if let f = await rec.capture(camera) {
                frames = rec.frames(for: camera.id)
                s.show("Frame saved · \(Fmt.time(rec.date(of: f)))")
            } else {
                s.show("Snapshot failed")
            }
            snapping = false
        }
    }

    private func share() {
        var items: [Any] = ["\(camera.name) · \(camera.source)\n\(Fmt.coord(camera.lat, camera.lon))"]
        if let u = URL(string: camera.streamURL ?? camera.videoURL ?? camera.imageURL) { items.append(u) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        top.present(vc, animated: true)
    }
}

// MARK: - Small pieces

private struct LiveButton: View {
    let icon: String
    let title: String
    var active = false
    var tint: Color = .purple
    let action: () -> Void
    var body: some View {
        Button(action: action) { LiveLabel(icon: icon, title: title, active: active, tint: tint) }
            .buttonStyle(.plain)
    }
}

private struct LiveLabel: View {
    let icon: String
    let title: String
    var active = false
    var tint: Color = .purple
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.9))
        .background(RoundedRectangle(cornerRadius: 10).fill(active ? tint.opacity(0.85) : Color.white.opacity(0.08)))
    }
}

private struct Stat: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        VStack(spacing: 2) {
            Text(k).font(.system(size: 8, weight: .black, design: .monospaced)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Thumb: View {
    let url: URL
    @State private var img: UIImage?
    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let img { Image(uiImage: img).resizable().scaledToFill() }
        }
        .task(id: url) {
            let u = url
            let loaded: UIImage? = await Task.detached(priority: .utility) {
                guard let d = try? Data(contentsOf: u), let full = UIImage(data: d) else { return nil }
                return full.preparingThumbnail(of: CGSize(width: 224, height: 126)) ?? full
            }.value
            img = loaded
        }
    }
}

private struct FrameRef: Identifiable { let url: URL; var id: String { url.absoluteString } }

// MARK: - Frame review (swipe through stored frames)

private struct FrameReview: View {
    let url: URL
    let date: Date
    let all: [URL]
    let rec: CamRecorder
    let camID: String
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var list: [URL] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12))) }
                    Spacer()
                    if list.indices.contains(index) {
                        Text("\(index + 1)/\(list.count) · \(Fmt.time(rec.date(of: list[index])))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    Spacer()
                    Button(role: .destructive) { delete() } label: { Image(systemName: "trash").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12))) }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                if !list.isEmpty {
                    TabView(selection: $index) {
                        ForEach(Array(list.enumerated()), id: \.offset) { i, f in
                            Full(url: f).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    Spacer(); Text("No frames").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary); Spacer()
                }
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onAppear { list = all; index = max(0, all.firstIndex(of: url) ?? 0) }
    }

    private func delete() {
        guard list.indices.contains(index) else { return }
        try? FileManager.default.removeItem(at: list[index])
        list.remove(at: index)
        rec.rescan()
        if list.isEmpty { dismiss() } else { index = min(index, list.count - 1) }
    }

    private struct Full: View {
        let url: URL
        @State private var img: UIImage?
        var body: some View {
            ZStack {
                if let img { Image(uiImage: img).resizable().scaledToFit() } else { ProgressView().tint(.purple) }
            }
            .task(id: url) {
                let u = url
                img = await Task.detached(priority: .userInitiated) { (try? Data(contentsOf: u)).flatMap(UIImage.init(data:)) }.value
            }
        }
    }
}
