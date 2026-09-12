import SwiftUI
import Combine
import CoreLocation

// MARK: - Sensor looks (GPU-composited filters over the live map)

struct SensorFilter: ViewModifier {
    let mode: SensorMode
    @ViewBuilder func body(content: Content) -> some View {
        switch mode {
        case .normal:
            content
        case .nvg:
            content.saturation(0).contrast(1.25).brightness(0.05)
                .colorMultiply(Color(red: 0.45, green: 1.0, blue: 0.5))
        case .flir:
            content.saturation(0).colorInvert().contrast(1.6).brightness(-0.05)
                .colorMultiply(Color(red: 1.0, green: 0.62, blue: 0.15))
        case .crt:
            content.saturation(0.25).contrast(1.15)
                .colorMultiply(Color(red: 0.55, green: 1.0, blue: 0.65))
        case .noir:
            content.saturation(0).contrast(1.45).brightness(-0.08)
        case .snow:
            content.saturation(0.15).brightness(0.18).contrast(0.9)
                .colorMultiply(Color(red: 0.85, green: 0.92, blue: 1.0))
        }
    }
}

struct SensorOverlay: View {
    let mode: SensorMode
    @State private var flicker = false

    var body: some View {
        switch mode {
        case .normal:
            EmptyView()
        case .nvg:
            ZStack {
                Scanlines(spacing: 3, opacity: 0.10)
                RadialGradient(colors: [.clear, .clear, .black.opacity(0.75)], center: .center, startRadius: 120, endRadius: 520)
            }
        case .flir:
            ZStack {
                Scanlines(spacing: 4, opacity: 0.06)
                LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
            }
        case .crt:
            ZStack {
                Scanlines(spacing: 2, opacity: 0.22)
                RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 200, endRadius: 560)
                Color.white.opacity(flicker ? 0.015 : 0)
                    .onAppear { withAnimation(.easeInOut(duration: 0.08).repeatForever()) { flicker = true } }
            }
        case .noir:
            ZStack {
                Scanlines(spacing: 3, opacity: 0.05)
                RadialGradient(colors: [.clear, .black.opacity(0.8)], center: .center, startRadius: 150, endRadius: 560)
            }
        case .snow:
            LinearGradient(colors: [.white.opacity(0.18), .clear, .white.opacity(0.12)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct Scanlines: View {
    let spacing: CGFloat
    let opacity: Double
    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            var y: CGFloat = 0
            var path = Path()
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += spacing
            }
            ctx.fill(path, with: .color(.black.opacity(opacity)))
        }
    }
}

// MARK: - Military HUD

struct HUDView: View {
    @EnvironmentObject var s: AppState
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Group {
                    Rectangle().frame(width: 1, height: 26).offset(y: -30)
                    Rectangle().frame(width: 1, height: 26).offset(y: 30)
                    Rectangle().frame(width: 26, height: 1).offset(x: -30)
                    Rectangle().frame(width: 26, height: 1).offset(x: 30)
                    Circle().stroke(lineWidth: 1).frame(width: 90, height: 90)
                    Circle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 6])).frame(width: 220, height: 220)
                }
                .foregroundStyle(s.accent.opacity(0.7))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                ForEach(0..<4, id: \.self) { i in
                    Bracket()
                        .stroke(s.accent.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees(Double(i) * 90))
                        .position(x: i == 0 || i == 3 ? 24 : geo.size.width - 24,
                                  y: i < 2 ? 130 : geo.size.height - 150)
                }
            }

            VStack(spacing: 0) {
                Spacer().frame(height: 150)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        hud("POS", Fmt.coord(s.center.latitude, s.center.longitude))
                        hud("ALT", altText)
                        hud("HDG", String(format: "%03.0f°", s.heading))
                        hud("PIT", String(format: "%02.0f°", s.pitch))
                        hud("SNS", s.sensor.title.uppercased())
                        hud("TIME", Fmt.utcFormatter.string(from: now))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        hud("AC", "\(s.visibleContacts.count)", trailing: true)
                        hud("SAT", "\(s.visibleSatellites.count)", trailing: true)
                        hud("SH", "\(s.visibleShips.count)", trailing: true)
                        hud("EQ", "\(s.visibleQuakes.count)", trailing: true)
                        hud("LNK", s.feedErrors == 0 ? "NOMINAL" : "ERR \(s.feedErrors)", trailing: true)
                        hud("MODE", s.isTracking ? (s.chase ? "COCKPIT" : "TRACK") : (s.directing ? "DIRECTOR" : "SCAN"), trailing: true)
                    }
                }
                .padding(.horizontal, 12)
                Spacer()
                if let e = s.trackedEntity, let c = s.trackedCoord {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TGT \(e.title)").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text(Fmt.coord(c.latitude, c.longitude)).font(.system(size: 9, design: .monospaced))
                            Text(e.summary).font(.system(size: 9, design: .monospaced)).lineLimit(2)
                            Text("RNG \(String(format: "%.1f", c.distance(to: s.center) / 1000)) km · BRG \(Int(bearing(from: s.center, to: c)))°")
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(e.kind.color.opacity(0.8), lineWidth: 1))
                        .foregroundStyle(e.kind.color)
                        .frame(maxWidth: 230, alignment: .leading)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 160)
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(s.accent)
        }
        .onReceive(timer) { now = $0 }
    }

    private var altText: String {
        let d = s.distance
        if d > 1_000_000 { return String(format: "%.2f Mm", d / 1_000_000) }
        if d > 1_000 { return String(format: "%.1f km", d / 1_000) }
        return "\(Int(d)) m"
    }

    private func hud(_ k: String, _ v: String, trailing: Bool = false) -> some View {
        HStack(spacing: 4) {
            if trailing { Text(v) }
            Text(k).foregroundStyle(s.accent.opacity(0.6))
            if !trailing { Text(v) }
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Color.black.opacity(0.35))
    }

    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dl)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }
}

struct Bracket: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
