import SwiftUI
import MapKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import CoreLocation

// MARK: - Street view (Apple Look Around) + Structure 3D

struct StructureView: View {
    @EnvironmentObject var s: AppState
    let entity: Entity
    @State private var lookAround: MKLookAroundScene?
    @State private var lookAroundTried = false
    @State private var showLookAround = false
    @State private var show3D = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STREET & STRUCTURE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            if let lookAround {
                LookAroundPreview(initialScene: lookAround, allowsNavigation: true, showsRoadLabels: true, pointsOfInterest: .all, badgePosition: .bottomTrailing)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { showLookAround = true }
                    .lookAroundViewer(isPresented: $showLookAround, scene: $lookAround, allowsNavigation: true, showsRoadLabels: true, pointsOfInterest: .all)
            } else if lookAroundTried {
                HStack(spacing: 8) {
                    Image(systemName: "binoculars").foregroundStyle(.secondary)
                    Text("No street-level imagery here").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for street view…").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
            }
            Button { show3D = true } label: {
                HStack {
                    Image(systemName: "cube.fill")
                    Text("Structure 3D").font(.system(size: 13, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("lidar + aerial texture").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(entity.kind.color.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .task {
            guard lookAround == nil, !lookAroundTried else { return }
            let req = MKLookAroundSceneRequest(coordinate: entity.coord)
            lookAround = try? await req.scene
            lookAroundTried = true
        }
        .fullScreenCover(isPresented: $show3D) { StructureSceneView(entity: entity).environmentObject(s) }
    }
}

// MARK: - Native 3D structure viewer

struct StructureSceneView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    let entity: Entity
    @State private var scene: SCNScene?
    @State private var status = "Loading structure…"
    @State private var source = ""
    @State private var wire = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let scene {
                StructureSCNView(scene: scene, wire: wire).ignoresSafeArea()
            } else {
                VStack(spacing: 10) { ProgressView().tint(.yellow); Text(status).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36).background(Circle().fill(.ultraThinMaterial))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.title.uppercased()).font(.system(size: 12, weight: .bold, design: .monospaced)).lineLimit(1)
                    Text(source.isEmpty ? status : source).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { wire.toggle() } label: {
                    Image(systemName: wire ? "square.grid.3x3" : "square.grid.3x3.fill").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36).background(Circle().fill(.ultraThinMaterial))
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .task { await build() }
    }

    // Pick the hand-rolled mesh tile under the point if the catalog has one; else extrude the OSM footprint / parcel.
    private func build() async {
        let c = entity.coord
        if let cat = await TilesCatalog.load(s.tilesCatalogURL),
           let mesh = cat.tilesets.first(where: { $0.kind == "mesh" && $0.bbox.count == 4 && c.longitude >= $0.bbox[0] && c.longitude <= $0.bbox[2] && c.latitude >= $0.bbox[1] && c.latitude <= $0.bbox[3] }),
           let sc = await loadMeshTile(mesh, at: c) {
            scene = sc; source = "\(mesh.name) · USGS 3DEP + NAIP"
            return
        }
        scene = extrudedFallback(at: c)
        source = "OSM footprint extrusion · run the mesh job for lidar detail"
    }

    private func loadMeshTile(_ ts: TilesCatalog.Tileset, at c: CLLocationCoordinate2D) async -> SCNScene? {
        status = "Fetching lidar mesh…"
        guard let base = URL(string: ts.url)?.deletingLastPathComponent(),
              let metaData = try? await URLSession.shared.data(from: base.appendingPathComponent("meta.json")).0,
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let center = meta["center"] as? [Double], center.count == 2,
              let tileM = meta["tileM"] as? Double, let half = meta["half"] as? Double else { return nil }
        let kx = 111320.0 * cos(center[0] * .pi / 180), ky = 110540.0
        let x = (c.longitude - center[1]) * kx, y = (c.latitude - center[0]) * ky
        guard abs(x) <= half, abs(y) <= half else { return nil }
        let i = Int(floor((x + half) / tileM)), j = Int(floor((half - y) / tileM))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mesh_\(ts.id.replacingOccurrences(of: "/", with: "_"))_\(i)_\(j)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["m_\(i)_\(j).obj", "m_\(i)_\(j).mtl", "m_\(i)_\(j).jpg"] {
            let dst = tmp.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) { continue }
            guard let d = try? await URLSession.shared.data(from: base.appendingPathComponent(name)).0 else { return nil }
            try? d.write(to: dst)
        }
        let asset = MDLAsset(url: tmp.appendingPathComponent("m_\(i)_\(j).obj"))
        asset.loadTextures()
        let sc = SCNScene(mdlAsset: asset)
        // OBJ is exported y-up ENU-local to the tile; centre the camera on the tapped point.
        let lx = Float(x - (Double(i) * tileM - half) - tileM / 2), lz = Float(-(y - (half - Double(j) * tileM) + tileM / 2))
        stage(sc, focus: SCNVector3(lx, 0, lz), radius: 90)
        return sc
    }

    private func extrudedFallback(at c: CLLocationCoordinate2D) -> SCNScene {
        let sc = SCNScene()
        let kx = 111320.0 * cos(c.latitude * .pi / 180), ky = 110540.0
        var focus = SCNVector3(0, 0, 0)
        // ground
        let ground = SCNNode(geometry: SCNPlane(width: 400, height: 400))
        ground.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.18, green: 0.24, blue: 0.15, alpha: 1)
        ground.eulerAngles.x = -.pi / 2; sc.rootNode.addChildNode(ground)
        let polys = s.propertyLines.isEmpty ? [] : s.propertyLines
        for p in polys {
            guard let ring = p.rings.first, ring.count > 3 else { continue }
            let path = UIBezierPath()
            for (k, pt) in ring.enumerated() {
                let x = CGFloat((pt.longitude - c.longitude) * kx), z = CGFloat(-(pt.latitude - c.latitude) * ky)
                if k == 0 { path.move(to: CGPoint(x: x, y: z)) } else { path.addLine(to: CGPoint(x: x, y: z)) }
            }
            path.close()
            if p.kind == .building {
                let h = CGFloat(entity.meta.first { $0.key.hasPrefix("Structure height") }.flatMap { Double($0.value.split(separator: " ").first ?? "") } ?? 7.0)
                let shape = SCNShape(path: path, extrusionDepth: h)
                let m = SCNMaterial(); m.diffuse.contents = UIColor(white: 0.85, alpha: 1); m.roughness.contents = 0.8
                let roof = SCNMaterial(); roof.diffuse.contents = UIColor(red: 0.35, green: 0.32, blue: 0.3, alpha: 1)
                shape.materials = [roof, roof, m]
                let node = SCNNode(geometry: shape); node.eulerAngles.x = -.pi / 2; node.position.y = Float(h / 2)
                sc.rootNode.addChildNode(node)
                if p.isTarget { focus = SCNVector3(0, Float(h / 2), 0) }
            } else {
                let outline = SCNShape(path: path, extrusionDepth: 0.05)
                outline.firstMaterial?.diffuse.contents = UIColor.yellow.withAlphaComponent(p.isTarget ? 0.25 : 0.08)
                outline.firstMaterial?.emission.contents = UIColor.yellow.withAlphaComponent(p.isTarget ? 0.6 : 0.2)
                let node = SCNNode(geometry: outline); node.eulerAngles.x = -.pi / 2; node.position.y = 0.06
                sc.rootNode.addChildNode(node)
            }
        }
        if polys.isEmpty {
            let box = SCNNode(geometry: SCNBox(width: 12, height: 7, length: 9, chamferRadius: 0)); box.position.y = 3.5
            box.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.8, alpha: 1); sc.rootNode.addChildNode(box)
        }
        stage(sc, focus: focus, radius: 45)
        return sc
    }

    private func stage(_ sc: SCNScene, focus: SCNVector3, radius: Float) {
        sc.background.contents = UIColor.black
        sc.lightingEnvironment.contents = UIColor(white: 0.9, alpha: 1); sc.lightingEnvironment.intensity = 1.2
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.castsShadow = true; sun.light?.shadowMode = .deferred
        sun.light?.shadowRadius = 6; sun.light?.shadowColor = UIColor(white: 0, alpha: 0.55); sun.light?.intensity = 1400
        sun.eulerAngles = SCNVector3(-0.9, 0.7, 0); sc.rootNode.addChildNode(sun)
        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 350; sc.rootNode.addChildNode(amb)
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.zFar = 5000; cam.camera?.fieldOfView = 55
        cam.camera?.wantsHDR = true; cam.camera?.bloomIntensity = 0.25; cam.camera?.screenSpaceAmbientOcclusionIntensity = 1.1
        cam.position = SCNVector3(focus.x + radius * 0.75, focus.y + radius * 0.6, focus.z + radius * 0.75)
        cam.look(at: focus); cam.name = "cam"
        sc.rootNode.addChildNode(cam)
        let pivot = SCNNode(); pivot.position = focus; pivot.name = "focus"; sc.rootNode.addChildNode(pivot)
    }
}

struct StructureSCNView: UIViewRepresentable {
    let scene: SCNScene
    let wire: Bool
    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = scene
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        if let f = scene.rootNode.childNode(withName: "focus", recursively: false) { v.defaultCameraController.target = f.position }
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .black
        v.pointOfView = scene.rootNode.childNode(withName: "cam", recursively: false)
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) {
        v.debugOptions = wire ? [.renderAsWireframe] : []
    }
}
