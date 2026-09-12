import SwiftUI

@main
struct GodsEyeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(state.accent)
                .dynamicTypeSize(.small ... .large)
                .ignoresSafeArea(.keyboard)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if s.ready {
                RootTabView().transition(.opacity)
            } else {
                SplashView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: s.ready)
        .task { await s.boot() }
        .onReceive(s.location.$coordinate) { c in if c != nil && s.alertISS { s.computePasses() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                s.cctv.resume()
            } else if phase == .background {
                s.cctv.stop()
            }
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        TabView(selection: $s.tab) {
            GlobeView()
                .tabItem { Label("Globe", systemImage: "globe.americas.fill") }
                .tag(0)
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.black.opacity(0.85), for: .tabBar)
    }
}

// MARK: - Splash

struct SplashView: View {
    @EnvironmentObject var s: AppState
    @State private var spin = false
    @State private var pulse = false
    @State private var scan = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [s.accent.opacity(0.12), .clear], center: .center, startRadius: 10, endRadius: 320)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle().stroke(s.accent.opacity(0.18), lineWidth: 1).frame(width: 150, height: 150)
                    Circle().stroke(s.accent.opacity(0.12), lineWidth: 1).frame(width: 110, height: 110)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(s.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 150, height: 150)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: spin)
                    Circle()
                        .trim(from: 0, to: 0.15)
                        .stroke(s.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 110, height: 110)
                        .rotationEffect(.degrees(spin ? -360 : 0))
                        .animation(.linear(duration: 2.6).repeatForever(autoreverses: false), value: spin)
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(s.accent)
                        .scaleEffect(pulse ? 1.06 : 0.94)
                        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: pulse)
                    Rectangle()
                        .fill(s.accent.opacity(0.35))
                        .frame(width: 150, height: 1)
                        .offset(y: scan ? 70 : -70)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: scan)
                        .mask(Circle().frame(width: 150, height: 150))
                }

                VStack(spacing: 8) {
                    Text("GOD'S EYE")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .tracking(8)
                    Text("NO PLACE LEFT BEHIND")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Circle().fill(s.accent).frame(width: 6, height: 6)
                        .opacity(pulse ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    Text(s.status)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(s.accent)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: s.status)
                }
                .padding(.top, 12)
            }

            VStack {
                Spacer()
                Text("MRZEFV · OPEN SIGNALS ONLY")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
        }
        .onAppear { spin = true; pulse = true; scan = true }
    }
}
