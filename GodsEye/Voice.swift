import Foundation
import Speech
import AVFoundation

// On-device speech → simple command grammar. No cloud keys.

@MainActor
final class VoiceController: ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var lastCommand = ""
    @Published var available = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) != nil

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    var onCommand: ((String) -> Void)?

    func toggle() { listening ? stop(commit: true) : start() }

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard auth == .authorized else { self?.lastCommand = "Speech permission denied"; return }
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { ok in
                        Task { @MainActor in
                            guard ok else { self?.lastCommand = "Microphone permission denied"; return }
                            self?.begin()
                        }
                    }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { ok in
                        Task { @MainActor in
                            guard ok else { self?.lastCommand = "Microphone permission denied"; return }
                            self?.begin()
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { lastCommand = "Speech unavailable"; return }
        stop(commit: false)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { lastCommand = "Mic failed: \(error.localizedDescription)"; return }
        transcript = ""
        listening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let r = result {
                    self.transcript = r.bestTranscription.formattedString
                    self.armSilence()
                    if r.isFinal { self.stop(commit: true) }
                }
                if error != nil { self.stop(commit: !self.transcript.isEmpty) }
            }
        }
        armSilence()
    }

    private func armSilence() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, let self, self.listening, !self.transcript.isEmpty else { return }
            self.stop(commit: true)
        }
    }

    func stop(commit: Bool) {
        silenceTask?.cancel()
        let text = transcript
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if commit, !text.isEmpty {
            lastCommand = text
            onCommand?(text)
        }
    }
}

// MARK: - Command grammar

enum VoiceCommand: Equatable {
    case goTo(String)
    case trackNearest(kind: String?)      // "aircraft", "ship", "satellite", "military", nil = anything
    case trackCallsign(String)
    case cockpit(Bool)
    case stopTracking
    case sensor(SensorMode)
    case layer(Layer, Bool)
    case resetGlobe
    case hud(Bool)
    case detection(Bool)
    case director(Bool)
    case mission(Mission)
    case timeline
    case nearestCamera
    case annotate(String)
    case clearAnnotations
    case outline(String)
    case measure(String, String)
    case orbit(Bool)
    case radioNear(String)
    case issPass
    case replayLaunch
    case radarToggle(Bool)
    case listenScanner(String)
    case spaceWeather
    case terrainProfile
    case unknown

    static func parse(_ raw: String) -> VoiceCommand {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }

        if has("clear the map", "clear annotations", "clear marks") { return .clearAnnotations }
        if has("how far is", "distance from", "distance between", "measure from") {
            var body = t
            for p in ["how far is", "distance from", "distance between", "measure from", "what is the", "what's the"] { body = body.replacingOccurrences(of: p, with: "") }
            let sep = body.contains(" from ") ? " from " : (body.contains(" to ") ? " to " : " and ")
            let parts = body.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if parts.count >= 2 { return .measure(parts[0], parts[1]) }
        }
        if has("outline", "draw the border", "boundary of", "highlight the state", "highlight the country") {
            var name = t
            for p in ["outline the state of", "outline the country of", "outline", "draw the border of", "boundary of", "highlight the state of", "highlight the country of", "the"] { name = name.replacingOccurrences(of: p, with: " ") }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .outline(name) }
        }
        if has("orbit") { return .orbit(!has("stop", "off")) }
        if has("play radio", "radio near", "radio station", "tune to") {
            var place = t
            for p in ["play a news radio station near", "play radio near", "play a radio station near", "radio station near", "radio near", "tune to", "play radio"] { place = place.replacingOccurrences(of: p, with: "") }
            return .radioNear(place.trimmingCharacters(in: .whitespaces).ifEmpty("here"))
        }
        if has("radar") && has("turn on", "show", "turn off", "hide", "enable", "disable") { return .radarToggle(!has("turn off", "hide", "disable")) }
        if has("scanner", "dispatch", "listen to police", "listen to fire") {
            var place = t
            for p in ["listen to the police scanner near", "listen to police scanner near", "play the scanner near", "scanner near", "police scanner", "fire scanner", "listen to police", "listen to fire", "scanner", "dispatch", "near", "play", "listen to"] { place = place.replacingOccurrences(of: p, with: " ") }
            return .listenScanner(place.trimmingCharacters(in: .whitespaces))
        }
        if has("space weather", "aurora", "geomagnetic", "solar storm", "kp index") { return .spaceWeather }
        if has("terrain profile", "elevation profile", "profile between") { return .terrainProfile }
        if has("iss pass", "when does the iss", "next iss", "space station pass") { return .issPass }
        if has("replay the launch", "launch replay", "replay launch", "play the launch") { return .replayLaunch }
        if has("mark this", "annotate", "drop a pin", "mark here") {
            let label = t.replacingOccurrences(of: "mark this as", with: "").replacingOccurrences(of: "annotate", with: "").replacingOccurrences(of: "mark here", with: "").replacingOccurrences(of: "mark this", with: "").replacingOccurrences(of: "drop a pin", with: "").trimmingCharacters(in: .whitespaces)
            return .annotate(label.isEmpty ? "MARK" : label.uppercased())
        }
        if has("reset globe", "reset the globe", "zoom out to a globe", "globe view", "back to earth") { return .resetGlobe }
        if has("stop tracking", "untrack", "release target") { return .stopTracking }
        if has("cockpit", "chase cam", "chase camera") { return .cockpit(!has("exit", "leave", "off")) }
        if has("nearest camera", "nearest cam", "closest camera", "street view", "look through a camera") { return .nearestCamera }
        if has("timeline", "playback", "replay") { return .timeline }
        if has("night vision", "nvg") { return .sensor(.nvg) }
        if has("thermal", "flir", "infrared") { return .sensor(.flir) }
        if has("crt") { return .sensor(.crt) }
        if has("noir", "black and white") { return .sensor(.noir) }
        if has("snow mode") { return .sensor(.snow) }
        if has("normal view", "normal mode", "normal sensor", "clear sensor") { return .sensor(.normal) }
        if has("hud") { return .hud(!has("off", "hide", "disable")) }
        if has("detection", "bounding box") { return .detection(!has("off", "hide", "disable")) }
        if has("director", "cinematic", "tour") { return .director(!has("stop", "off", "end")) }
        if has("live contacts mission", "show me live contacts") { return .mission(.liveContacts) }
        if has("space mission", "show me space") { return .mission(.space) }
        if has("environmental") { return .mission(.environmental) }
        if has("london watch") { return .mission(.london) }

        let layerWords: [(Layer, [String])] = [
            (.flights, ["flights", "flight layer", "aircraft layer", "planes"]),
            (.military, ["military"]),
            (.ships, ["ships", "vessels", "boats"]),
            (.satellites, ["satellites"]),
            (.quakes, ["earthquakes", "quakes", "seismic"]),
            (.launches, ["launches", "space missions", "rockets"]),
            (.cctv, ["cameras", "cctv"]),
            (.traffic, ["traffic"])
        ]
        if has("turn on", "turn off", "enable", "disable", "show", "hide") {
            for (layer, words) in layerWords where words.contains(where: { t.contains($0) }) {
                return .layer(layer, !has("turn off", "disable", "hide"))
            }
        }

        if has("track") {
            let kind: String? = has("ship", "vessel", "boat") ? "ship"
                : has("satellite") ? "satellite"
                : has("military") ? "military"
                : has("aircraft", "plane", "flight", "helicopter", "contact") ? "aircraft" : nil
            if has("nearest", "closest", "that", "this", "something") || kind != nil { return .trackNearest(kind: kind) }
            let cs = t.replacingOccurrences(of: "track", with: "").trimmingCharacters(in: .whitespaces)
            if !cs.isEmpty { return .trackCallsign(cs.replacingOccurrences(of: " ", with: "").uppercased()) }
            return .trackNearest(kind: nil)
        }

        for prefix in ["take me to", "fly to", "go to", "show me", "navigate to", "jump to", "fly me to"] {
            if let r = t.range(of: prefix) {
                var dest = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let andR = dest.range(of: " and ") { dest = String(dest[..<andR.lowerBound]) }
                if !dest.isEmpty { return .goTo(dest) }
            }
        }
        return .unknown
    }
}
