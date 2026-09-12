import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct GlobeView: View {
    @EnvironmentObject var s: AppState
    @State private var showSearch = false
    @State private var showLayers = false
    @State private var showModes = false

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
                .modifier(SensorFilter(mode: s.sensor))
            SensorOverlay(mode: s.sensor)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            if s.hud { HUDView().allowsHitTesting(false) }

            VStack(spacing: 8) {
                topBar
                if s.isTracking { TrackingBar() }
                Spacer()
                if let t = s.toast { ToastView(text: t).transition(.move(edge: .bottom).combined(with: .opacity)) }
                BottomPanel(showLayers: $showLayers, showModes: $showModes)
            }
            .animation(.easeInOut(duration: 0.25), value: s.toast)

            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showTimeline) {
                    TimelineView()
                        .presentationDetents([.fraction(0.38), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.38)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showRoster) {
                    RosterSheet()
                        .presentationDetents([.fraction(0.42), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showRadio) {
                    RadioTunerSheet()
                        .presentationDetents([.fraction(0.34), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.34)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showReplay, onDismiss: { s.endReplay() }) {
                    ReplaySheet()
                        .presentationDetents([.fraction(0.3)])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.3)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showScenes) {
                    ScenesSheet()
                        .presentationDetents([.fraction(0.45), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showQR) {
                    QRSheet().presentationDetents([.medium]).presentationDragIndicator(.visible)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showRadar) {
                    RadarSheet(r: s.radar)
                        .presentationDetents([.fraction(0.4), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                        .presentationDragIndicator(.visible).presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(item: $s.showStation) { st in
                    StationSheet(station: st)
                        .presentationDetents([.fraction(0.55), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
                        .presentationDragIndicator(.visible).presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showProfile) {
                    ProfileSheet().presentationDetents([.fraction(0.45)]).presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45))).presentationDragIndicator(.visible).presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showSpace) {
                    SpaceSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $s.showScanner) {
                    ScannerSheet().presentationDetents([.fraction(0.5), .large]).presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5))).presentationDragIndicator(.visible).presentationBackground(.ultraThinMaterial)
                }
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: $showModes) {
                    ModesSheet()
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
        }
        .sheet(item: $s.selected) { e in
            DetailSheet(entity: e)
                .presentationDetents([.fraction(0.48), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.48)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .onOpenURL { url in s.open(url: url) }
        .fullScreenCover(item: $s.liveCamera) { cam in
            CameraLiveView(rec: s.cctv, camera: cam).environmentObject(s)
        }
        .fullScreenCover(isPresented: $s.show3D) {
            Scene3DView().environmentObject(s)
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $s.camera, interactionModes: .all) {
                mcTracks
                mcAir
                mcCams
                mcGeo
                mcGround
                mcUser
            }
            .mapStyle(s.mapStyle)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { ctx in s.cameraChanged(ctx) }
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) { s.tapPoint(c) }
            }
            .overlay {
                GeometryReader { geo in
                    RadarOverlays(r: s.radar, proxy: proxy)
                    .onAppear { s.viewWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in s.viewWidth = w }
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Map content (split so the type-checker stays fast)

    @MapContentBuilder private var mcTracks: some MapContent {
        // Trails
        if s.trail.count > 1 {
            MapPolyline(coordinates: s.trail)
                .stroke(s.trackedEntity?.kind.color ?? s.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        if s.satTrack.count > 1 {
            MapPolyline(coordinates: s.satTrack)
                .stroke(Color.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
        }

        // Tracked target (dead-reckoned position)
        if let tc = s.trackedCoord, let te = s.trackedEntity, te.kind == .aircraft || te.kind == .military {
            Annotation("", coordinate: tc, anchor: .center) {
                Image(systemName: "scope")
                    .font(.system(size: 30, weight: .thin))
                    .foregroundStyle(te.kind.color)
            }
            .annotationTitles(.hidden)
        }

        // Wakes (short trailing lines behind moving contacts)
        if s.wakes, s.distance < 800_000 {
            ForEach(s.visibleContacts) { c in
                if let gs = c.groundSpeedKt, gs > 40 {
                    MapPolyline(coordinates: [c.coord, c.coord.moved(meters: -gs * 0.514 * 90, bearing: c.track)])
                        .stroke((c.military ? Color.orange : s.accent).opacity(0.45), lineWidth: 1.5)
                }
            }
            ForEach(s.visibleShips) { v in
                if v.sogKt > 1 {
                    MapPolyline(coordinates: [v.coord, v.coord.moved(meters: -v.sogKt * 0.514 * 600, bearing: v.cog)])
                        .stroke(Color.blue.opacity(0.45), lineWidth: 1.5)
                }
            }
        }

        // Fires
        ForEach(s.visibleFires) { f in
            Annotation("", coordinate: f.coord, anchor: .center) {
                Circle().fill(Entity.Kind.fire.color.opacity(0.75))
                    .frame(width: min(4 + f.frp / 8, 16), height: min(4 + f.frp / 8, 16))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
                    .onTapGesture { s.select(Entity.from(f)) }
            }
            .annotationTitles(.hidden)
        }

        // Measure
        if s.measureLine.count > 1 {
            MapPolyline(coordinates: s.measureLine).stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
        if let a = s.measureA {
            Annotation("A", coordinate: a, anchor: .center) { Image(systemName: "a.circle.fill").font(.title3).foregroundStyle(.white) }
        }
        if let b = s.measureB, let a = s.measureA {
            Annotation("B", coordinate: b, anchor: .center) { Image(systemName: "b.circle.fill").font(.title3).foregroundStyle(.white) }
            Annotation("", coordinate: Geo.greatCircle(a, b, points: 2)[1], anchor: .bottom) {
                Text(String(format: "%.1f km", a.distance(to: b) / 1000))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
            }
            .annotationTitles(.hidden)
        }

        // Launch replay
        if let r = s.replay {
            let st = r.state(at: s.replayT)
            MapPolyline(coordinates: r.track(upTo: s.replayT)).stroke(Color.pink, lineWidth: 3)
            MapPolyline(coordinates: r.track(upTo: LaunchReplay.duration)).stroke(Color.pink.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
            Annotation("", coordinate: st.coord, anchor: .center) {
                VStack(spacing: 2) {
                    Image(systemName: "paperplane.fill").rotationEffect(.degrees(r.azimuth - 45)).foregroundStyle(.pink).font(.title3)
                    Text("\(st.phase) · \(Int(st.altKm)) km").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).background(Color.black.opacity(0.7))
                }
            }
            .annotationTitles(.hidden)
        }
    }

    @MapContentBuilder private var mcAir: some MapContent {
        // Aircraft
        if s.layers.contains(.flights) || s.layers.contains(.military) {
            ForEach(s.visibleContacts) { c in
                Annotation(c.displayName, coordinate: c.coord, anchor: .center) {
                    MarkerGlyph(system: c.glyph,
                                color: c.military ? .orange : s.accent,
                                size: c.aircraftClass == .heavy ? 15 : 11,
                                rotation: c.glyph == "airplane" ? c.track - 90 : (c.glyph == "paperplane.fill" ? c.track - 45 : c.track),
                                id: c.id.uppercased(),
                                tracked: s.trackedID == "ac-\(c.id)",
                                detection: s.detection)
                        .onTapGesture { s.select(Entity.from(c)) }
                }
                .annotationTitles(showContactLabels ? .visible : .hidden)
            }
        }

        // Ships
        ForEach(s.visibleShips) { v in
            Annotation(v.displayName, coordinate: v.coord, anchor: .center) {
                MarkerGlyph(system: "arrowtriangle.up.fill", color: .blue, size: 11,
                            rotation: v.cog, id: v.id, tracked: s.trackedID == "sh-\(v.id)", detection: s.detection)
                    .onTapGesture { s.select(Entity.from(v)) }
            }
            .annotationTitles(s.showLabels && s.distance < 120_000 ? .visible : .hidden)
        }

        // Satellites
        ForEach(s.visibleSatellites) { sat in
            Annotation(sat.name, coordinate: sat.coord, anchor: .center) {
                ZStack {
                    if sat.cls == .station {
                        Circle().stroke(Color.cyan.opacity(0.5), lineWidth: 1).frame(width: 30, height: 30)
                    }
                    Image(systemName: sat.cls == .station ? "sparkle" : "circle.fill")
                        .font(.system(size: sat.cls == .station ? 14 : 5, weight: .bold))
                        .foregroundStyle(sat.cls.color)
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .overlay { if s.detection { DetectionBox(id: sat.id, color: sat.cls.color) } }
                .onTapGesture { s.select(Entity.from(sat)) }
            }
            .annotationTitles(s.showLabels && (sat.cls == .station || s.distance < 4_000_000) ? .visible : .hidden)
        }

        // Airport surfaces
        if s.layers.contains(.airport) {
            ForEach(s.airportFeatures) { f in
                switch f.kind {
                case .runway: MapPolyline(coordinates: f.points).stroke(Color.white.opacity(0.85), lineWidth: 5)
                case .taxiway: MapPolyline(coordinates: f.points).stroke(Color.yellow.opacity(0.7), lineWidth: 2)
                case .apron: MapPolygon(coordinates: f.points).foregroundStyle(Color.gray.opacity(0.18)).stroke(Color.gray.opacity(0.5), lineWidth: 1)
                case .terminal: MapPolygon(coordinates: f.points).foregroundStyle(Color.cyan.opacity(0.15)).stroke(Color.cyan.opacity(0.6), lineWidth: 1)
                }
            }
        }

        // Submarine cables
        ForEach(s.visibleCables) { cable in
            ForEach(Array(cable.segments.enumerated()), id: \.offset) { seg in
                MapPolyline(coordinates: seg.element)
                    .stroke(Color(hex: cable.color).opacity(0.8), lineWidth: 1.5)
            }
        }

        // Airports
        ForEach(s.visibleAirports) { a in
            Annotation(a.iata.isEmpty ? a.id : a.iata, coordinate: a.coord, anchor: .center) {
                Image(systemName: "airplane.circle").font(.system(size: a.type == "large_airport" ? 14 : 10)).foregroundStyle(Entity.Kind.airport.color)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
                    .onTapGesture { s.select(Entity.from(a)) }
            }
            .annotationTitles(s.showLabels && (a.type == "large_airport" || s.distance < 800_000) ? .visible : .hidden)
        }
    }

    @MapContentBuilder private var mcCams: some MapContent {
        // CCTV
        ForEach(s.visibleCameras) { cam in
            Annotation(cam.name, coordinate: cam.coord, anchor: .center) {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.25)).frame(width: 22, height: 22)
                    if s.cctv.watching.contains(cam.id) { Circle().stroke(Color.red, lineWidth: 1.5).frame(width: 22, height: 22) }
                    Image(systemName: cam.isLiveVideo ? "video.fill" : "video").font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .onTapGesture { s.select(Entity.from(cam)) }
            }
            .annotationTitles(.hidden)
        }

        // Voice / manual annotations
        ForEach(s.annotations) { a in
            Annotation(a.label, coordinate: a.coord, anchor: .bottom) {
                VStack(spacing: 2) {
                    Text(a.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(s.accent))
                        .foregroundStyle(.black)
                    Image(systemName: "mappin").foregroundStyle(s.accent)
                }
            }
            .annotationTitles(.hidden)
        }

        // Property lines (county parcels) + OSM building footprint for the last looked-up place
        ForEach(s.propertyLines) { poly in
            ForEach(Array(poly.rings.enumerated()), id: \.offset) { ring in
                if poly.kind == .building {
                    MapPolygon(coordinates: ring.element)
                        .foregroundStyle(Color.cyan.opacity(0.10))
                        .stroke(Color.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                } else {
                    MapPolygon(coordinates: ring.element)
                        .foregroundStyle(poly.isTarget ? Color.yellow.opacity(0.18) : Color.clear)
                        .stroke(poly.isTarget ? Color.yellow : Color.yellow.opacity(0.55), lineWidth: poly.isTarget ? 2.5 : 1)
                }
            }
        }

        // Camera viewsheds
        if s.viewsheds, s.layers.contains(.cctv), s.distance < 6_000 {
            ForEach(s.visibleCameras) { cam in
                MapPolygon(coordinates: Geo.cone(at: cam.coord, heading: Geo.stableHeading(for: cam.id)))
                    .foregroundStyle(Color.purple.opacity(0.18))
                    .stroke(Color.purple.opacity(0.6), lineWidth: 1)
            }
        }

        // Region outlines
        ForEach(s.regions) { r in
            ForEach(Array(r.rings.enumerated()), id: \.offset) { ring in
                MapPolygon(coordinates: ring.element)
                    .foregroundStyle(s.accent.opacity(0.10))
                    .stroke(s.accent, lineWidth: 2)
            }
        }
    }

    @MapContentBuilder private var mcGeo: some MapContent {
        // Earthquakes
        ForEach(s.visibleQuakes) { q in
            Annotation(String(format: "M%.1f", q.mag), coordinate: q.coord, anchor: .center) {
                ZStack {
                    Circle().fill(q.color.opacity(0.22)).frame(width: quakeSize(q) * 2, height: quakeSize(q) * 2)
                    Circle().stroke(q.color, lineWidth: 1.5).frame(width: quakeSize(q), height: quakeSize(q))
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture { s.select(Entity.from(q)) }
            }
            .annotationTitles(q.mag >= 5 && s.showLabels ? .visible : .hidden)
        }

        // Launch pads
        ForEach(s.visibleLaunches) { l in
            Annotation(l.name, coordinate: l.coord, anchor: .bottom) {
                Image(systemName: l.net > Date() ? "flame" : "flame.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.pink)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture { s.select(Entity.from(l)) }
            }
            .annotationTitles(.hidden)
        }

        // Hazards
        ForEach(s.visibleHazards) { h in
            ForEach(Array(h.rings.enumerated()), id: \.offset) { ring in
                MapPolygon(coordinates: ring.element).foregroundStyle(h.color.opacity(0.18)).stroke(h.color.opacity(0.8), lineWidth: 1.5)
            }
            Annotation(h.event, coordinate: h.coord, anchor: .center) {
                Image(systemName: h.source == "Cal Fire" ? "flame.fill" : "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(h.color)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
                    .onTapGesture { s.select(Entity.from(h)) }
            }
            .annotationTitles(s.distance < 2_000_000 && s.showLabels ? .visible : .hidden)
        }

        // Weather stations
        ForEach(s.visibleStations) { w in
            Annotation(w.tempC.map { "\(Int($0))°" } ?? w.id, coordinate: w.coord, anchor: .center) {
                ZStack {
                    Circle().fill(Entity.Kind.station.color.opacity(0.2)).frame(width: 18, height: 18)
                    if let d = w.windDir, let k = w.windKt, k > 0 {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(d + 180)).foregroundStyle(Entity.Kind.station.color)
                    } else {
                        Image(systemName: w.kind == "BUOY" ? "water.waves" : "thermometer.medium").font(.system(size: 8)).foregroundStyle(Entity.Kind.station.color)
                    }
                }
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .onTapGesture { s.select(Entity.from(w)) }
            }
            .annotationTitles(s.showLabels && s.distance < 1_500_000 ? .visible : .hidden)
        }

        // Storm cells
        ForEach(s.storms) { st in
            if st.history.count > 1 { MapPolyline(coordinates: st.history).stroke(Entity.Kind.storm.color, lineWidth: 2) }
            MapPolyline(coordinates: [st.coord, st.coord.moved(meters: st.speedKmh / 3.6 * 3600, bearing: st.headingDeg)])
                .stroke(Entity.Kind.storm.color.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            Annotation("+60 min", coordinate: st.coord.moved(meters: st.speedKmh / 3.6 * 3600, bearing: st.headingDeg), anchor: .center) {
                Circle().stroke(Entity.Kind.storm.color, lineWidth: 1.5).frame(width: 14, height: 14)
            }
            Annotation("", coordinate: st.coord, anchor: .center) {
                Image(systemName: "cloud.bolt.rain.fill").foregroundStyle(Entity.Kind.storm.color).font(.title3)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
                    .onTapGesture { s.select(Entity.from(st)) }
            }
            .annotationTitles(.hidden)
        }

        // Night side + aurora
        if s.layers.contains(.space) {
            if s.night.count > 3 {
                MapPolygon(coordinates: s.night).foregroundStyle(Color.black.opacity(0.35)).stroke(Color.yellow.opacity(0.5), lineWidth: 1)
            }
            ForEach(s.auroraPoints) { a in
                Annotation("", coordinate: a.coord, anchor: .center) {
                    Circle().fill(Color.green.opacity(min(0.85, a.prob / 100 + 0.15))).frame(width: 6, height: 6)
                }
                .annotationTitles(.hidden)
            }
            Annotation("SUN", coordinate: Solar.subsolar(Date()), anchor: .center) {
                Image(systemName: "sun.max.fill").foregroundStyle(.yellow).font(.title2)
            }
            .annotationTitles(.visible)
        }

        // Wind vectors
        if s.layers.contains(.wind) {
            ForEach(s.winds) { w in
                Annotation("", coordinate: w.coord, anchor: .center) {
                    VStack(spacing: 0) {
                        Image(systemName: "arrow.up").font(.system(size: 12 + min(w.speedKt, 40) / 4, weight: .bold))
                            .rotationEffect(.degrees(w.dirDeg + 180))
                            .foregroundStyle(w.speedKt > 25 ? .orange : .cyan)
                        Text("\(Int(w.speedKt))").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.cyan)
                    }
                }
                .annotationTitles(.hidden)
            }
        }

        // Quake depth rings (seismic upgrade)
        if s.layers.contains(.quakes), s.distance < 3_000_000 {
            ForEach(s.visibleQuakes.filter { $0.mag >= 4 }) { q in
                MapCircle(center: q.coord, radius: pow(10, 0.5 * q.mag) * 120)
                    .foregroundStyle((q.depthKm < 70 ? Color.red : q.depthKm < 300 ? Color.orange : Color.blue).opacity(0.12))
                    .stroke((q.depthKm < 70 ? Color.red : q.depthKm < 300 ? Color.orange : Color.blue).opacity(0.6), lineWidth: 1)
            }
        }
    }

    @MapContentBuilder private var mcGround: some MapContent {
        // Bikeshare
        ForEach(s.visibleBikes) { b in
            Annotation(b.name, coordinate: b.coord, anchor: .center) {
                ZStack {
                    Circle().fill(Color.mint.opacity(0.25)).frame(width: 20, height: 20)
                    Text(b.bikes >= 0 ? "\(b.bikes)" : "?").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.mint)
                }
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .onTapGesture { s.select(Entity.from(b)) }
            }
            .annotationTitles(.hidden)
        }

        // Radio
        ForEach(s.visibleRadio) { r in
            Annotation(r.name, coordinate: r.coord, anchor: .center) {
                Image(systemName: s.radio.current?.id == r.id ? "dot.radiowaves.left.and.right" : "radio")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .onTapGesture { s.select(Entity.from(r)) }
            }
            .annotationTitles(.hidden)
        }

        // Infrastructure
        if s.layers.contains(.infra), s.distance < 400_000 {
            ForEach(s.infra) { n in
                Annotation(n.name, coordinate: n.coord, anchor: .center) {
                    Image(systemName: n.kind.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.teal)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(n)) }
                }
                .annotationTitles(s.distance < 30_000 && s.showLabels ? .visible : .hidden)
            }
        }

        // Power grid
        if s.layers.contains(.power), s.distance < 250_000 {
            ForEach(s.powerLines) { l in
                MapPolyline(coordinates: l.points).stroke(l.color.opacity(0.8), lineWidth: l.voltage >= 230_000 ? 2.5 : 1.5)
            }
            ForEach(s.powerNodes) { n in
                Annotation(n.name, coordinate: n.coord, anchor: .center) {
                    Image(systemName: n.kind.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(n)) }
                }
                .annotationTitles(s.distance < 40_000 && s.showLabels ? .visible : .hidden)
            }
        }

        // Rail
        if s.layers.contains(.rail), s.distance < 150_000 {
            ForEach(s.railLines) { l in
                MapPolyline(coordinates: l.points)
                    .stroke(l.kind == "yard" ? Color.gray : l.kind == "subway" ? Color.orange : l.kind == "tram" || l.kind == "light_rail" ? Color.mint : Entity.Kind.train.color,
                            style: StrokeStyle(lineWidth: l.kind == "yard" ? 1 : 2, dash: l.kind == "rail" ? [] : [4, 3]))
            }
            ForEach(s.railStations) { st in
                Annotation(st.name, coordinate: st.coord, anchor: .center) {
                    Circle().fill(.white).frame(width: 6, height: 6).overlay(Circle().stroke(Entity.Kind.train.color, lineWidth: 1.5)).frame(width: 18, height: 18).contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.place(lat: st.lat, lon: st.lon, name: st.name, detail: "Rail \(st.kind)", distance: 3_000)) }
                }
                .annotationTitles(s.distance < 25_000 && s.showLabels ? .visible : .hidden)
            }
        }

        // Live trains
        ForEach(s.visibleTrains) { t in
            Annotation(t.name, coordinate: t.coord, anchor: .center) {
                MarkerGlyph(system: "train.side.front.car", color: Entity.Kind.train.color, size: 12, rotation: 0, id: t.id, tracked: s.trackedID == "train-\(t.id)", detection: s.detection)
                    .onTapGesture { s.select(Entity.from(t)) }
            }
            .annotationTitles(s.distance < 600_000 && s.showLabels ? .visible : .hidden)
        }

        // Scanners
        if s.layers.contains(.scanner) {
            ForEach(s.scanners) { f in
                Annotation(f.title, coordinate: f.coord, anchor: .center) {
                    Image(systemName: s.scannerNow?.id == f.id ? "speaker.wave.2.fill" : "antenna.radiowaves.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Entity.Kind.scanner.color)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(f)) }
                }
                .annotationTitles(.hidden)
            }
        }

        // Peaks
        if s.layers.contains(.peaks), s.distance < 300_000 {
            ForEach(s.peaks.prefix(120)) { p in
                Annotation("\(p.name) \(Int(p.elevationM))m", coordinate: p.coord, anchor: .bottom) {
                    Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(Entity.Kind.peak.color)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                        .onTapGesture { s.select(Entity.from(p)) }
                }
                .annotationTitles(s.distance < 80_000 && s.showLabels ? .visible : .hidden)
            }
        }

        // Historical trace of tracked aircraft
        if s.traceHistory.count > 1 {
            MapPolyline(coordinates: s.traceHistory)
                .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1.5))
        }
    }

    @MapContentBuilder private var mcUser: some MapContent {
        if s.location.coordinate != nil { UserAnnotation() }
    }

    private var showContactLabels: Bool { s.showLabels && s.distance < 250_000 }

    private func quakeSize(_ q: Quake) -> CGFloat { CGFloat(6 + max(0, q.mag - 1) * 3.2) }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            GlassButton(icon: "magnifyingglass", label: "Search") { showSearch = true }
                .sheet(isPresented: $showSearch) {
                    SearchSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: "square.3.layers.3d", label: "Layers", badge: s.layers.count) { showLayers = true }
                .sheet(isPresented: $showLayers) {
                    LayersSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            GlassButton(icon: s.isLive ? "clock" : "clock.badge.exclamationmark",
                        label: s.isLive ? "Time" : "Replay",
                        active: !s.isLive) { s.openTimeline(at: nil) }
            VoiceButton(voice: s.voice)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - Marker glyph (+ detection box)

struct MarkerGlyph: View {
    let system: String
    let color: Color
    let size: CGFloat
    let rotation: Double
    let id: String
    let tracked: Bool
    let detection: Bool

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotation))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .overlay {
                if tracked { Circle().stroke(color, lineWidth: 1.5).frame(width: 26, height: 26) }
                if detection { DetectionBox(id: id, color: color) }
            }
    }
}

struct DetectionBox: View {
    let id: String
    let color: Color
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(color.opacity(0.9), lineWidth: 1).frame(width: 24, height: 24)
            Text(id)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 2)
                .background(color)
                .offset(y: -10)
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Glass button

struct GlassButton: View {
    let icon: String
    let label: String
    var badge: Int? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let b = badge {
                    Text("\(b)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
            }
            .foregroundStyle(active ? Color.black : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                if active { Capsule().fill(.tint) } else { Capsule().fill(.ultraThinMaterial) }
            }
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct VoiceButton: View {
    @ObservedObject var voice: VoiceController

    var body: some View {
        Button { voice.toggle() } label: {
            Image(systemName: voice.listening ? "waveform" : "mic.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(voice.listening ? Color.black : Color.primary)
                .frame(width: 42, height: 36)
                .background { if voice.listening { Capsule().fill(.tint) } else { Capsule().fill(.ultraThinMaterial) } }
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
                .symbolEffect(.variableColor.iterative, isActive: voice.listening)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tracking bar

struct TrackingBar: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        if let e = s.trackedEntity {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(e.kind.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TRACKING · \(e.title)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
                    Text(s.weather.map { "WX " + $0.text } ?? e.summary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { s.stepRoster(forward: false) } label: { Image(systemName: "chevron.left") }
                Button { s.toggleChase() } label: {
                    Image(systemName: s.chase ? "airplane.departure" : "video")
                        .foregroundStyle(s.chase ? Color.black : Color.primary)
                        .padding(6)
                        .background(Circle().fill(s.chase ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1))))
                }
                Button { s.stepRoster(forward: true) } label: { Image(systemName: "chevron.right") }
                Button { s.stopTracking() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
            .font(.system(size: 14, weight: .semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(e.kind.color.opacity(0.5), lineWidth: 1))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
            .padding(.bottom, 4)
    }
}

// MARK: - Bottom panel

struct BottomPanel: View {
    @EnvironmentObject var s: AppState
    @Binding var showLayers: Bool
    @Binding var showModes: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.centerName)
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                    Text(Fmt.coord(s.center.latitude, s.center.longitude) + "  ·  " + altitudeText)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(s.isLive ? s.accent : .orange).frame(width: 6, height: 6)
                        Text(s.isLive ? "LIVE" : "REPLAY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(s.isLive ? s.accent : .orange)
                        if s.sensor != .normal {
                            Text(s.sensor.title.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12)))
                        }
                    }
                    Text(countsText).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            // One row. Tap = primary action. Press & hold = grouped menu (system haptic).
            HStack(spacing: 6) {
                HoldAction(icon: "location.fill", title: "Locate", primary: { s.locateMe() }) {
                    Button { s.locateMe() } label: { Label("Locate me", systemImage: "location.fill") }
                    Button { s.resetGlobe() } label: { Label("Reset globe", systemImage: "globe") }
                    Button { s.toggleOrbit() } label: { Label(s.orbiting ? "Stop orbit" : "Orbit here", systemImage: "rotate.3d") }
                    Button { if s.measureMode { s.clearMeasure() } else { s.toggleMeasure() } } label: { Label(s.measureMode ? "Clear measure" : "Measure", systemImage: "ruler") }
                    Button { s.loadProfile() } label: { Label("Elevation profile", systemImage: "chart.xyaxis.line") }
                    Button { s.showQR = true } label: { Label("QR / deep link", systemImage: "qrcode") }
                }
                HoldAction(icon: "list.bullet.rectangle", title: "Contacts", primary: { s.showRoster = true }) {
                    Button { s.showRoster = true } label: { Label("Contacts roster", systemImage: "list.bullet.rectangle") }
                    Toggle(isOn: layerBinding(.trains)) { Label("Live trains", systemImage: "train.side.front.car") }
                    Toggle(isOn: layerBinding(.alerts)) { Label("Alerts", systemImage: "exclamationmark.triangle") }
                    Toggle(isOn: $s.showLabels) { Label("Labels", systemImage: "tag") }
                    Toggle(isOn: $s.wakes) { Label("Wakes", systemImage: "wind") }
                    Button { Task { await s.refreshAll() } } label: { Label("Refresh feeds", systemImage: "arrow.clockwise") }
                }
                HoldAction(icon: "camera.aperture", title: "Modes", active: s.sensor != .normal || s.hud || s.detection, primary: { showModes = true }) {
                    Button { showModes = true } label: { Label("Modes sheet", systemImage: "camera.aperture") }
                    Button { s.show3D = true } label: { Label("3D scene", systemImage: "cube.transparent") }
                    Picker("Sensor", selection: $s.sensor) {
                        ForEach(SensorMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    Toggle(isOn: $s.hud) { Label("Military HUD", systemImage: "scope") }
                    Toggle(isOn: $s.detection) { Label("Detection boxes", systemImage: "viewfinder") }
                }
                HoldAction(icon: s.directing ? "stop.fill" : "film", title: "Director", active: s.directing || s.scenePlaying, primary: { s.toggleDirector() }) {
                    Button { s.toggleDirector() } label: { Label(s.directing ? "Stop director" : "Start director", systemImage: s.directing ? "stop.fill" : "film") }
                    Button { s.showScenes = true } label: { Label("Scenes", systemImage: "record.circle") }
                    Button { s.toggleOrbit() } label: { Label(s.orbiting ? "Stop orbit" : "Orbit", systemImage: "rotate.3d") }
                }
                HoldAction(icon: "radio", title: "Audio", active: s.radio.playing || s.scannerNow != nil, primary: { s.showRadio = true }) {
                    Button { s.showRadio = true } label: { Label("World radio", systemImage: "radio") }
                    Button { if !s.layers.contains(.scanner) { s.layers.insert(.scanner) }; s.showScanner = true } label: { Label("Scanner feeds", systemImage: "antenna.radiowaves.left.and.right") }
                    Button { s.voice.toggle() } label: { Label(s.voice.listening ? "Stop listening" : "Voice command", systemImage: "mic") }
                }
                HoldAction(icon: "square.3.layers.3d", title: "Layers", active: s.layers.contains(.radar) || s.layers.contains(.space), primary: { showLayers = true }) {
                    Button { showLayers = true } label: { Label("Layers sheet", systemImage: "square.3.layers.3d") }
                    Button { s.show3D = true } label: { Label("3D scene · Esri / Google / OSM", systemImage: "cube.transparent") }
                    if !s.propertyLines.isEmpty {
                        Button(role: .destructive) { s.propertyLines = [] } label: { Label("Clear property lines", systemImage: "rectangle.dashed") }
                    }
                    Button { if !s.layers.contains(.radar) { s.layers.insert(.radar) }; s.showRadar = true } label: { Label("Weather radar", systemImage: "cloud.rain") }
                    Button { if !s.layers.contains(.space) { s.layers.insert(.space) }; s.showSpace = true } label: { Label("Space weather", systemImage: "sun.max") }
                    Toggle(isOn: layerBinding(.cctv)) { Label("Public CCTV", systemImage: "video") }
                    Toggle(isOn: layerBinding(.flights)) { Label("Flights", systemImage: "airplane") }
                    Toggle(isOn: layerBinding(.ships)) { Label("Ships", systemImage: "ferry") }
                    Toggle(isOn: layerBinding(.satellites)) { Label("Satellites", systemImage: "sparkle") }
                    Toggle(isOn: layerBinding(.quakes)) { Label("Earthquakes", systemImage: "waveform.path.ecg") }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func layerBinding(_ l: Layer) -> Binding<Bool> {
        Binding(get: { s.layers.contains(l) }, set: { on in if on { s.layers.insert(l) } else { s.layers.remove(l) } })
    }

    private var altitudeText: String {
        let d = s.distance
        if d > 1_000_000 { return String(format: "%.0f Mm", d / 1_000_000) }
        if d > 1_000 { return String(format: "%.0f km", d / 1_000) }
        return "\(Int(d)) m"
    }

    private var countsText: String {
        var parts: [String] = []
        if s.layers.contains(.flights) || s.layers.contains(.military) { parts.append("\(s.visibleContacts.count) AC") }
        if s.layers.contains(.ships) { parts.append("\(s.visibleShips.count) SH") }
        if s.layers.contains(.satellites) { parts.append("\(s.visibleSatellites.count) SAT") }
        if s.layers.contains(.quakes) { parts.append("\(s.visibleQuakes.count) EQ") }
        if s.layers.contains(.cctv) { parts.append("\(s.visibleCameras.count) CAM") }
        if let t = s.lastUpdate { parts.append(Fmt.rel.localizedString(for: t, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }
}

/// Tap = primary action (with impact haptic). Press & hold = grouped menu (system haptic + list).
struct HoldAction<Items: View>: View {
    let icon: String
    let title: String
    var active = false
    let primary: () -> Void
    @ViewBuilder let items: () -> Items

    init(icon: String, title: String, active: Bool = false, primary: @escaping () -> Void, @ViewBuilder items: @escaping () -> Items) {
        self.icon = icon; self.title = title; self.active = active; self.primary = primary; self.items = items
    }

    var body: some View {
        Menu {
            items()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Color.black : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.06))))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        } primaryAction: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            primary()
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Color.black : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.06))))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

struct SearchSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var places: [MKMapItem] = []
    @State private var parcels: [ParcelRecord] = []
    @State private var searching = false
    @State private var parcelSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var parcelTask: Task<Void, Never>?
    @State private var searchGeneration: Int = 0
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var contactMatches: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 2 else { return [] }
        return (s.contacts + s.militaryContacts)
            .filter { $0.callsign.uppercased().hasPrefix(q) || $0.id.uppercased().hasPrefix(q) || ($0.registration ?? "").uppercased().hasPrefix(q) }
            .prefix(8).map { $0 }
    }

    private var satMatches: [Satellite] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 2 else { return [] }
        return s.satellites.filter { $0.name.uppercased().contains(q) || $0.id == q }.prefix(6).map { $0 }
    }

    private var launchMatches: [Launch] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3 else { return [] }
        return s.launches.filter { $0.name.lowercased().contains(q) || $0.provider.lowercased().contains(q) }.prefix(5).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if !contactMatches.isEmpty {
                    Section("Contacts") {
                        ForEach(contactMatches) { c in
                            Button { pick(Entity.from(c)) } label: {
                                row(icon: c.glyph, color: c.military ? .orange : s.accent,
                                    title: c.displayName, sub: [c.type, c.registration, c.altFt.map { "\($0.formatted()) ft" }].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                }
                if !satMatches.isEmpty {
                    Section("Satellites") {
                        ForEach(satMatches) { sat in
                            Button { pick(Entity.from(sat)) } label: {
                                row(icon: "sparkle", color: sat.cls.color, title: sat.name, sub: "\(sat.cls.label) · \(Int(sat.altKm)) km")
                            }
                        }
                    }
                }
                if !launchMatches.isEmpty {
                    Section("Missions") {
                        ForEach(launchMatches) { l in
                            Button { pick(Entity.from(l)) } label: { row(icon: "flame", color: .pink, title: l.name, sub: l.provider) }
                        }
                    }
                }
                Section(searching ? "Searching…" : "Places") {
                    ForEach(places, id: \.self) { item in
                        Button { pickPlace(item) } label: {
                            row(icon: "building.2", color: .white,
                                title: item.name ?? "Unnamed",
                                sub: item.placemark.title ?? Fmt.coord(item.placemark.coordinate.latitude, item.placemark.coordinate.longitude))
                        }
                    }
                    if places.isEmpty && parcels.isEmpty && !searching && trimmedQuery.count >= 2 {
                        Text("No places yet — try an airport, city, or landmark.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !parcels.isEmpty || trimmedQuery.count >= 3 || parcelSearching {
                    Section(parcelSearching ? "Address / owner records…" : "Address / owner records") {
                        ForEach(parcels) { p in
                            Button { pickParcel(p) } label: {
                                row(icon: "building.2.crop.circle", color: .teal,
                                    title: p.title,
                                    sub: [p.owner.map { "Owner: \($0)" }, p.address].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        if parcels.isEmpty {
                            if parcelSearching {
                                Text("Looking up parcel records…").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("No address/owner records near this map area yet — try moving the map or refining the query.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Airport, city, callsign, ICAO, satellite…")
            .onChange(of: query) { _, q in schedule(q) }
        }
    }

    private func row(icon: String, color: Color, title: String, sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.primary)
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    private func schedule(_ q: String) {
        searchTask?.cancel()
        searchTask = nil
        parcelTask?.cancel()
        parcelTask = nil
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { places = []; parcels = []; searching = false; parcelSearching = false; return }
        let originCenter = s.center
        searching = true
        if trimmed.count >= 3 {
            parcelSearching = true
            parcelTask = Task {
                func finish() async {
                    await MainActor.run {
                        if searchGeneration == generation {
                            parcelSearching = false
                            parcelTask = nil
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { await finish(); return }
                let parcel: [ParcelRecord]
                do {
                    parcel = try await Feeds.shared.parcelRecords(query: trimmed, near: originCenter)
                } catch is CancellationError {
                    await finish()
                    return
                } catch {
                    parcel = []
                }
                guard !Task.isCancelled else { await finish(); return }
                let shouldApply = await MainActor.run { searchGeneration == generation }
                guard shouldApply else { await finish(); return }
                await MainActor.run {
                    parcels = Array(parcel.prefix(10))
                    parcelSearching = false
                    parcelTask = nil
                }
            }
        } else {
            parcels = []
            parcelSearching = false
            parcelTask = nil
        }
        searchTask = Task {
            func finish() async {
                await MainActor.run {
                    if searchGeneration == generation { searching = false }
                }
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { await finish(); return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = trimmed
            req.resultTypes = [.pointOfInterest, .address]
            req.region = MKCoordinateRegion(center: originCenter, span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
            var resp: MKLocalSearch.Response?
            do {
                resp = try await MKLocalSearch(request: req).start()
            } catch is CancellationError {
                await finish()
                return
            } catch {
                resp = nil
            }
            guard !Task.isCancelled else { await finish(); return }
            let shouldApply = await MainActor.run { searchGeneration == generation }
            guard shouldApply else { await finish(); return }
            await MainActor.run {
                places = Array((resp?.mapItems ?? []).prefix(12))
                searching = false
            }
        }
    }

    private func pick(_ e: Entity) {
        dismiss()
        Task { try? await Task.sleep(nanoseconds: 300_000_000); s.select(e) }
    }

    private func pickPlace(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        let name = item.name ?? "Location"
        let detail = item.placemark.title ?? ""
        let extraMeta = placeMetadata(from: item.placemark, category: item.pointOfInterestCategory)
        dismiss()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            s.select(Entity.place(lat: c.latitude,
                                  lon: c.longitude,
                                  name: name,
                                  detail: detail,
                                  distance: item.pointOfInterestCategory == .airport ? 12_000 : 6_000,
                                  summary: "Resolved place · \(Fmt.coord(c.latitude, c.longitude))",
                                  extraMeta: extraMeta))
        }
    }

    private func placeMetadata(from p: MKPlacemark, category: MKPointOfInterestCategory?) -> [MetaRow] {
        var rows: [MetaRow] = []
        if let poi = category?.rawValue, !poi.isEmpty {
            let clean = poi.replacingOccurrences(of: "MKPOICategory", with: "").replacingOccurrences(of: "_", with: " ")
            rows.append(MetaRow("Category", clean.capitalized))
        }
        let address = [p.subThoroughfare, p.thoroughfare, p.subLocality, p.locality, p.administrativeArea, p.postalCode, p.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !address.isEmpty { rows.append(MetaRow("Address", address)) }
        if let city = p.locality, !city.isEmpty { rows.append(MetaRow("City", city)) }
        if let region = p.administrativeArea, !region.isEmpty { rows.append(MetaRow("Region", region)) }
        if let country = p.country, !country.isEmpty { rows.append(MetaRow("Country", country)) }
        if let postal = p.postalCode, !postal.isEmpty { rows.append(MetaRow("Postal code", postal)) }
        if let tz = p.timeZone?.identifier, !tz.isEmpty { rows.append(MetaRow("Time zone", tz)) }
        return rows
    }

    private func pickParcel(_ p: ParcelRecord) {
        let subtitle = p.owner.map { "Owner: \($0)" } ?? "Parcel record"
        let e = Entity(
            id: "parcel-\(p.id)",
            kind: .place,
            title: p.title,
            subtitle: subtitle,
            summary: p.address,
            lat: p.lat,
            lon: p.lon,
            time: nil,
            meta: [
                MetaRow("OSM record ID", p.osmRecordID),
                MetaRow("Address", p.address),
                MetaRow("Owner", p.owner ?? "—"),
                MetaRow("Source", "OpenStreetMap Nominatim")
            ],
            url: "https://www.openstreetmap.org/?mlat=\(p.lat)&mlon=\(p.lon)#map=18/\(p.lat)/\(p.lon)",
            viewDistance: 2_500
        )
        dismiss()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            s.select(e)
        }
    }
}

// MARK: - Layers + missions

struct LayersSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Missions") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Mission.allCases) { m in
                                Button { s.run(m) } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: m.icon).font(.title3)
                                        Text(m.title).font(.system(size: 10, weight: .semibold, design: .monospaced)).lineLimit(1)
                                    }
                                    .frame(width: 96, height: 64)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section {
                    ForEach(Layer.allCases) { layer in
                        Toggle(isOn: Binding(
                            get: { s.layers.contains(layer) },
                            set: { on in if on { s.layers.insert(layer) } else { s.layers.remove(layer) } }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: layer.icon).frame(width: 22).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(layer.title).font(.system(.body, design: .monospaced).weight(.semibold))
                                    Text("\(count(layer)) · \(layer.source)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Layers")
                } footer: {
                    Text("Everything is keyless except AIS ships (free AISStream key in Settings). Data may be delayed or incomplete — not for navigation.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func count(_ l: Layer) -> String {
        switch l {
        case .flights: return "\(s.contacts.filter { !$0.military }.count) in range"
        case .military: return "\(s.militaryContacts.count) worldwide"
        case .ships: return s.aisKey.isEmpty ? "needs key" : "\(s.ships.count) · \(s.aisStatus)"
        case .satellites: return "\(s.satellites.count) propagated"
        case .quakes: return "\(s.quakes.count) events / 24h"
        case .launches: return "\(s.launches.count) missions"
        case .cctv: return "\(s.cameras.count) cams · \(s.cameras.filter(\.isLiveVideo).count) live video · \(s.cctv.watching.count) watched"
        case .traffic: return "live flow on basemap"
        case .fires: return s.firmsKey.isEmpty ? "needs key" : "\(s.fires.count) detections"
        case .bikeshare: return s.bikes.isEmpty ? "zoom into a supported city" : "\(s.bikes.count) stations"
        case .radio: return "\(s.radioStations.count) stations"
        case .infra: return s.infra.isEmpty ? "zoom in (<400 km)" : "\(s.infra.count) sites"
        case .cables: return "\(s.cables.count) cables"
        case .airport: return s.airportFeatures.isEmpty ? "zoom in (<12 km)" : "\(s.airportFeatures.count) surfaces"
        case .radar: return "\(s.radar.radarFrames.count) frames"
        case .satir: return "\(s.radar.satFrames.count) frames"
        case .wind: return "\(s.winds.count) vectors"
        case .power: return s.powerLines.isEmpty ? "zoom in (<250 km)" : "\(s.powerLines.count) lines · \(s.powerNodes.count) nodes"
        case .rail: return s.railLines.isEmpty ? "zoom in (<150 km)" : "\(s.railLines.count) tracks · \(s.railStations.count) stations"
        case .trains: return "\(s.trains.count) live"
        case .airports: return "\(s.airports.count) airports"
        case .stations: return "\(s.stations.count) obs"
        case .alerts: return "\(s.hazards.count) active"
        case .space: return "Kp \(String(format: "%.1f", s.space.kp)) · \(s.space.stormLevel)"
        case .scanner: return "\(s.scanners.count) feeds"
        case .peaks: return s.peaks.isEmpty ? "zoom in (<300 km)" : "\(s.peaks.count) peaks"
        }
    }
}

// MARK: - Modes (sensor / HUD / detection)

struct ModesSheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Sensor") {
                    ForEach(SensorMode.allCases) { m in
                        Button { s.sensor = m } label: {
                            HStack {
                                Text(m.key).font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
                                Text(m.title).font(.system(.body, design: .monospaced))
                                Spacer()
                                if s.sensor == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section("Overlays") {
                    Toggle(isOn: $s.hud) { Label("Military HUD", systemImage: "scope") }
                    Toggle(isOn: $s.detection) { Label("Detection overlay", systemImage: "viewfinder") }
                    Toggle(isOn: $s.wakes) { Label("Contact wakes", systemImage: "wind") }
                    Toggle(isOn: $s.viewsheds) { Label("Camera viewsheds (est.)", systemImage: "camera.metering.partial") }
                }
                Section("ISS passes over you (approx.)") {
                    if s.passes.isEmpty {
                        Button("Compute passes") { s.computePasses(); if s.passes.isEmpty { s.show(s.location.coordinate == nil ? "Need your location" : "No pass ≥10° in 24h") } }
                    } else {
                        ForEach(s.passes) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Fmt.time(p.start)) → \(Fmt.time(p.end))").font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text(String(format: "max %.0f° · %@", p.maxElevationDeg, Fmt.rel.localizedString(for: p.start, relativeTo: Date()))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Clear annotations") { s.clearAnnotations() }.disabled(s.annotations.isEmpty)
                    Button("Mark map center") { s.annotate("MARK \(s.annotations.count + 1)") }
                } header: { Text("Whiteboard") } footer: {
                    Text("Voice: “mark this as target alpha”, “clear the map”.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Modes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Roster

struct RosterSheet: View {
    @EnvironmentObject var s: AppState
    @State private var kind: String? = nil
    @State private var list: [Entity] = []

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("CONTACTS NEAR CENTER").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Text("\(list.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            }
            Picker("Kind", selection: $kind) {
                Text("All").tag(String?.none)
                Text("Aircraft").tag(String?.some("aircraft"))
                Text("Military").tag(String?.some("military"))
                Text("Ships").tag(String?.some("ship"))
                Text("Sats").tag(String?.some("satellite"))
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in reload() }
            HStack(spacing: 10) {
                Button { s.stepRoster(forward: false, kind: kind) } label: { Label("Prev", systemImage: "backward.fill") }
                Button { s.stepRoster(forward: true, kind: kind) } label: { Label("Next", systemImage: "forward.fill") }
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .buttonStyle(.bordered)
            List(list) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.kind.icon).foregroundStyle(e.kind.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                        Text(e.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(String(format: "%.0f km", e.coord.distance(to: s.center) / 1000))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Button { s.track(e) } label: {
                        Image(systemName: s.trackedID == e.id ? "scope" : "plus.viewfinder")
                            .foregroundStyle(s.trackedID == e.id ? Color.black : Color.primary)
                            .padding(6)
                            .background(Circle().fill(s.trackedID == e.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1))))
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture { s.select(e) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(14)
        .onAppear { reload() }
    }

    private func reload() { list = s.roster(kind: kind, limit: 60) }
}


// MARK: - Radio tuner

struct RadioTunerSheet: View {
    @EnvironmentObject var s: AppState
    var body: some View { RadioTunerBody(p: s.radio) }
}

struct RadioTunerBody: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var p: RadioPlayer
    @State private var needle: Double = 0

    private var stations: [RadioStation] { s.radioStations.sorted { $0.lon < $1.lon } }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ANALOG TUNER").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                    Text(p.current?.name ?? "— drag the needle —").font(.system(size: 15, weight: .bold, design: .monospaced)).lineLimit(1)
                    Text(p.current.map { "\($0.country) · \($0.codec ?? "")" } ?? "\(stations.count) stations, west → east").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36)) }
                    .buttonStyle(.plain).disabled(p.current == nil)
                Button { p.stop() } label: { Image(systemName: "stop.circle").font(.title2).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)).frame(height: 40)
                    ForEach(0..<40, id: \.self) { i in
                        Rectangle().fill(.white.opacity(i % 5 == 0 ? 0.5 : 0.2)).frame(width: 1, height: i % 5 == 0 ? 18 : 10)
                            .offset(x: geo.size.width * Double(i) / 39, y: 0)
                    }
                    ForEach(stations.prefix(400)) { st in
                        Circle().fill(Color.yellow.opacity(0.6)).frame(width: 3, height: 3)
                            .offset(x: geo.size.width * (st.lon + 180) / 360 - 1.5, y: 14)
                    }
                    Rectangle().fill(.red).frame(width: 2, height: 40).offset(x: geo.size.width * needle)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    needle = min(max(v.location.x / geo.size.width, 0), 1)
                }.onEnded { _ in snap() })
            }
            .frame(height: 40)
            HStack {
                Text("180°W").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Nearest to view") { if let st = s.radioStations.min(by: { $0.coord.distance(to: s.center) < $1.coord.distance(to: s.center) }) { s.tune(st); needle = (st.lon + 180) / 360 } }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).buttonStyle(.bordered)
                Spacer()
                Text("180°E").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .task { if s.radioStations.isEmpty { await s.refreshRadio() }; if !s.layers.contains(.radio) { s.layers.insert(.radio) } }
    }

    private func snap() {
        let lon = needle * 360 - 180
        guard let st = stations.min(by: { abs($0.lon - lon) < abs($1.lon - lon) }) else { return }
        needle = (st.lon + 180) / 360
        s.tune(st)
    }
}

// MARK: - Launch replay

struct ReplaySheet: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(spacing: 12) {
            if let r = s.replay {
                let st = r.state(at: s.replayT)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECONSTRUCTED ESTIMATE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.pink)
                        Text(r.launch.name).font(.system(size: 14, weight: .bold, design: .monospaced)).lineLimit(1)
                        Text("T+\(Int(s.replayT))s · \(st.phase) · \(Int(st.altKm)) km · \(Int(st.speedKmh).formatted()) km/h")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { s.replayToggle() } label: { Image(systemName: s.replayPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36)) }.buttonStyle(.plain)
                }
                Slider(value: Binding(get: { s.replayT }, set: { s.replayPause(); s.replayT = $0 }), in: 0...LaunchReplay.duration).tint(.pink)
                HStack {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { rate in
                        Button("\(rate == 0.25 ? "¼" : rate == 0.5 ? "½" : "\(Int(rate))")×") { s.replayRate = rate }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(s.replayRate == rate ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.08))))
                            .foregroundStyle(s.replayRate == rate ? Color.black : Color.primary)
                            .buttonStyle(.plain)
                    }
                    Spacer()
                    Button("End") { s.endReplay() }.font(.system(size: 11, weight: .bold, design: .monospaced)).buttonStyle(.bordered)
                }
            } else {
                Text("No launch selected").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - Scenes

struct ScenesSheet: View {
    @EnvironmentObject var s: AppState
    @State private var name = "scene"
    @State private var importing = false
    @State private var exported: URL?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("SCENE RECORDER").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Text("\(s.keyframes.count) keyframes").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { s.addKeyframe() } label: { Label("Add keyframe", systemImage: "camera.viewfinder") }
                Button { if s.scenePlaying { s.stopScene() } else { s.playScene() } } label: { Label(s.scenePlaying ? "Stop" : "Play", systemImage: s.scenePlaying ? "stop.fill" : "play.fill") }
                    .disabled(s.keyframes.isEmpty)
                Button(role: .destructive) { s.keyframes = [] } label: { Image(systemName: "trash") }.disabled(s.keyframes.isEmpty)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced)).buttonStyle(.bordered)
            HStack(spacing: 8) {
                TextField("scene name", text: $name).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                Button("Export .gev") { exported = s.exportScene(named: name); if exported != nil { s.show("Saved to Files › GodsEye › Scenes") } }
                    .disabled(s.keyframes.isEmpty)
                Button("Import") { importing = true }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced)).buttonStyle(.bordered)
            if let u = exported {
                ShareLink(item: u) { Label("Share \(u.lastPathComponent)", systemImage: "square.and.arrow.up").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                    .buttonStyle(.bordered)
            }
            List {
                ForEach(Array(s.keyframes.enumerated()), id: \.element.id) { i, k in
                    HStack {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .monospaced)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.coord(k.lat, k.lon)).font(.system(size: 11, design: .monospaced))
                            Text(String(format: "%.0f km · hdg %.0f° · pitch %.0f° · hold %.0fs", k.distance / 1000, k.heading, k.pitch, k.hold)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { s.fly(to: k.coord, distance: k.distance, pitch: k.pitch, heading: k.heading) } label: { Image(systemName: "arrow.right.circle") }.buttonStyle(.plain)
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { s.keyframes.remove(atOffsets: $0) }
                .onMove { s.keyframes.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .padding(16)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { res in
            if case .success(let url) = res { s.importScene(url) }
        }
    }
}

// MARK: - QR share

struct QRSheet: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(spacing: 14) {
            Text("SHARE THIS VIEW").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            if let img = QR.image(s.deepLink) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                    .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(s.deepLink).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            ShareLink(item: s.deepLink) { Label("Share link", systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .semibold, design: .monospaced)) }.buttonStyle(.bordered)
            Text("Scan on another phone with GodsEye installed — camera, layers, sensor and target restore.").font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(20)
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let r, g, b: Double
        if h.count == 6 { r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255; b = Double(v & 0xff) / 255 }
        else { r = 0.5; g = 0.5; b = 1.0 }
        self.init(red: r, green: g, blue: b)
    }
}


struct RadarOverlays: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var r: RadarEngine
    let proxy: MapProxy
    var body: some View {
        ZStack {
            if let c = r.satComposite, s.layers.contains(.satir) {
                RadarOverlayView(composite: c, proxy: proxy, opacity: s.radarOpacity * 0.6, heading: s.heading, pitch: s.pitch)
            }
            if let c = r.composite, s.layers.contains(.radar) {
                RadarOverlayView(composite: c, proxy: proxy, opacity: s.radarOpacity, heading: s.heading, pitch: s.pitch)
            }
        }
    }
}
