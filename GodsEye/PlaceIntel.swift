import Foundation
import CoreLocation
import SwiftUI

// MARK: - Model

struct IntelSection: Identifiable, Equatable {
    let title: String
    let source: String
    let rows: [MetaRow]
    var link: String? = nil
    var id: String { title }
}

struct PlaceIntel: Equatable {
    var sections: [IntelSection] = []
    var owner: String? = nil          // best-effort owner / operator for the parcel or building
    var polygons: [ParcelPolygon] = []   // parcel property lines (+ OSM building footprint) for the map
    var parcelService: String? = nil
    var fetchedAt = Date()
    var errors: [String] = []
    var isEmpty: Bool { sections.isEmpty }
}

// MARK: - Lookups (all keyless public APIs)

extension Feeds {

    private static let intelSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func intelGET(_ url: String, cache: String) async throws -> Data {
        if offline, let d = FeedCache.load(cache) { return d }
        guard let u = URL(string: url) else { throw FeedError.badResponse }
        var req = URLRequest(url: u)
        req.setValue("GodsEye-iOS/1.4 (MRzefv)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await Feeds.intelSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw FeedError.badResponse }
            FeedCache.save(cache, data)
            return data
        } catch {
            if let d = FeedCache.load(cache) { return d }
            throw error
        }
    }

    func intelPOST(_ url: String, body: String, cache: String) async throws -> Data {
        if offline, let d = FeedCache.load(cache) { return d }
        guard let u = URL(string: url) else { throw FeedError.badResponse }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("GodsEye-iOS/1.4 (MRzefv)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        do {
            let (data, resp) = try await Feeds.intelSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw FeedError.badResponse }
            FeedCache.save(cache, data)
            return data
        } catch {
            if let d = FeedCache.load(cache) { return d }
            throw error
        }
    }

    static func key(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f_%.5f", locale: Locale(identifier: "en_US_POSIX"), c.latitude, c.longitude)
    }

    /// Everything public we can find about a point, fetched concurrently.
    func placeIntel(at c: CLLocationCoordinate2D) async -> PlaceIntel {
        async let parcel = parcelLookup(at: c)
        async let nominatim = nominatimReverse(c)
        async let overpass = overpassAround(c)
        async let census = censusGeographies(c)
        async let wiki = wikipediaNearby(c)
        async let footprint = osmFootprint(c)

        var out = PlaceIntel()
        let pr = await parcel
        if let sec = pr.section { out.sections.append(sec) }
        out.polygons = pr.polygons
        out.parcelService = pr.serviceName
        let results: [(String, Result<[IntelSection], Error>)] = [
            ("OSM", await nominatim), ("Overpass", await overpass), ("Census", await census), ("Wikipedia", await wiki)
        ]
        if let fp = await footprint { out.polygons.append(fp) }
        for (name, r) in results {
            switch r {
            case .success(let secs): out.sections += secs
            case .failure(let e): out.errors.append("\(name): \(e.localizedDescription)")
            }
        }
        out.owner = out.sections.flatMap(\.rows).first { ["Owner", "Operator"].contains($0.key) }?.value
        return out
    }

    // MARK: OSM building footprint under the point (drawn alongside parcel lines)

    private func osmFootprint(_ c: CLLocationCoordinate2D) async -> ParcelPolygon? {
        let posix = Locale(identifier: "en_US_POSIX")
        let url = String(format: "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=%.6f&lon=%.6f&zoom=18&polygon_geojson=1", locale: posix, c.latitude, c.longitude)
        guard let d = try? await intelGET(url, cache: "intel-fp-\(Feeds.key(c)).json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let g = j["geojson"] as? [String: Any], let type = g["type"] as? String else { return nil }
        var rings: [[CLLocationCoordinate2D]] = []
        func ring(_ r: [[Double]]) -> [CLLocationCoordinate2D] { r.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil } }
        if type == "Polygon", let cs = g["coordinates"] as? [[[Double]]] { rings = cs.map(ring) }
        else if type == "MultiPolygon", let cs = g["coordinates"] as? [[[[Double]]]] { rings = cs.flatMap { $0.map(ring) } }
        guard let outer = rings.first, outer.count > 2 else { return nil }
        let id = "fp-\(j["osm_type"] as? String ?? "")\(String(describing: j["osm_id"] ?? ""))"
        return ParcelPolygon(id: id, kind: .building, rings: rings, attributes: [:], isTarget: true)
    }

    // MARK: Nominatim reverse (address + extratags: owner/operator/building/etc.)

    private func nominatimReverse(_ c: CLLocationCoordinate2D) async -> Result<[IntelSection], Error> {
        let posix = Locale(identifier: "en_US_POSIX")
        let url = String(format: "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=%.6f&lon=%.6f&zoom=18&addressdetails=1&extratags=1&namedetails=1", locale: posix, c.latitude, c.longitude)
        do {
            let d = try await intelGET(url, cache: "intel-nom-\(Feeds.key(c)).json")
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .success([]) }
            if j["error"] != nil { return .success([]) }
            var rows: [MetaRow] = []
            let addr = j["address"] as? [String: Any] ?? [:]
            let ext = j["extratags"] as? [String: Any] ?? [:]
            let names = j["namedetails"] as? [String: Any] ?? [:]
            func a(_ k: String) -> String? { (addr[k] as? String)?.trimmingCharacters(in: .whitespaces) }
            func e(_ k: String) -> String? { (ext[k] as? String)?.trimmingCharacters(in: .whitespaces) }

            let osmType = (j["osm_type"] as? String ?? "").uppercased()
            let osmID = (j["osm_id"] as? Int).map(String.init) ?? String(describing: j["osm_id"] ?? "")
            if let n = (names["name"] as? String) ?? (j["name"] as? String), !n.isEmpty { rows.append(MetaRow("Name", n)) }
            let cat = [(j["category"] as? String), (j["type"] as? String)].compactMap { $0 }.joined(separator: " /")
            if !cat.isEmpty { rows.append(MetaRow("Feature", cat.replacingOccurrences(of: "_", with: " "))) }
            if let o = e("owner") ?? e("contact:owner") { rows.append(MetaRow("Owner", o)) }
            if let o = e("operator") { rows.append(MetaRow("Operator", o)) }
            if let o = e("brand") { rows.append(MetaRow("Brand", o)) }
            if let o = e("building") { rows.append(MetaRow("Building", o.replacingOccurrences(of: "_", with: " "))) }
            if let o = e("building:levels") { rows.append(MetaRow("Levels", o)) }
            if let o = e("height") { rows.append(MetaRow("Height", o + (o.contains(" ") ? "" : " m"))) }
            if let o = e("start_date") ?? e("year_built") ?? e("construction_date") { rows.append(MetaRow("Built", o)) }
            if let o = e("building:material") { rows.append(MetaRow("Material", o)) }
            if let o = e("roof:shape") { rows.append(MetaRow("Roof", o)) }
            if let o = e("amenity") ?? e("shop") ?? e("office") ?? e("landuse") { rows.append(MetaRow("Use", o.replacingOccurrences(of: "_", with: " "))) }
            if let o = e("opening_hours") { rows.append(MetaRow("Hours", o)) }
            if let o = e("phone") ?? e("contact:phone") { rows.append(MetaRow("Phone", o)) }
            if let o = e("website") ?? e("contact:website") { rows.append(MetaRow("Website", o)) }
            if let o = e("description") { rows.append(MetaRow("Description", o)) }
            if let o = e("wikidata") { rows.append(MetaRow("Wikidata", o)) }
            if let hn = a("house_number") { rows.append(MetaRow("House no.", hn)) }
            if let r = a("road") ?? a("pedestrian") ?? a("footway") { rows.append(MetaRow("Street", r)) }
            if let n = a("neighbourhood") ?? a("suburb") ?? a("quarter") { rows.append(MetaRow("Neighbourhood", n)) }
            if let ci = a("city") ?? a("town") ?? a("village") ?? a("hamlet") ?? a("municipality") { rows.append(MetaRow("City", ci)) }
            if let co = a("county") { rows.append(MetaRow("County", co)) }
            if let st = a("state") { rows.append(MetaRow("State", st)) }
            if let pc = a("postcode") { rows.append(MetaRow("Postcode", pc)) }
            if let cc = a("country_code") { rows.append(MetaRow("Country", cc.uppercased())) }
            if !osmType.isEmpty && !osmID.isEmpty { rows.append(MetaRow("OSM", "\(osmType.prefix(1))\(osmID)")) }
            if let dn = j["display_name"] as? String { rows.append(MetaRow("Full address", dn)) }
            guard !rows.isEmpty else { return .success([]) }
            let link = (!osmType.isEmpty && !osmID.isEmpty) ? "https://www.openstreetmap.org/\(osmType.lowercased())/\(osmID)" : nil
            return .success([IntelSection(title: "PROPERTY RECORD", source: "OpenStreetMap · Nominatim", rows: rows, link: link)])
        } catch { return .failure(error) }
    }

    // MARK: Overpass — building under the point + named neighbours

    private func overpassAround(_ c: CLLocationCoordinate2D) async -> Result<[IntelSection], Error> {
        let posix = Locale(identifier: "en_US_POSIX")
        let la = String(format: "%.6f", locale: posix, c.latitude)
        let lo = String(format: "%.6f", locale: posix, c.longitude)
        let q = """
        [out:json][timeout:20];
        (
          way(around:30,\(la),\(lo))["building"];
          relation(around:30,\(la),\(lo))["building"];
          nwr(around:120,\(la),\(lo))["name"];
          nwr(around:60,\(la),\(lo))["addr:housenumber"];
        );
        out tags center 40;
        """
        let body = "data=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)
        do {
            let d = try await intelPOST("https://overpass-api.de/api/interpreter", body: body, cache: "intel-ovp-\(Feeds.key(c)).json")
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let els = j["elements"] as? [[String: Any]] else { return .success([]) }
            struct El { let type: String; let id: Int; let tags: [String: String]; let dist: Double }
            let items: [El] = els.compactMap { el in
                guard let tags = el["tags"] as? [String: String], let type = el["type"] as? String, let id = el["id"] as? Int else { return nil }
                var lat = el["lat"] as? Double, lon = el["lon"] as? Double
                if let ctr = el["center"] as? [String: Any] { lat = ctr["lat"] as? Double; lon = ctr["lon"] as? Double }
                guard let lat, let lon else { return nil }
                return El(type: type, id: id, tags: tags, dist: CLLocationCoordinate2D(latitude: lat, longitude: lon).distance(to: c))
            }.sorted { $0.dist < $1.dist }

            var sections: [IntelSection] = []

            if let b = items.first(where: { $0.tags["building"] != nil }) {
                var rows: [MetaRow] = []
                let t = b.tags
                func add(_ label: String, _ keys: String...) { for k in keys { if let v = t[k], !v.isEmpty { rows.append(MetaRow(label, v.replacingOccurrences(of: "_", with: " "))); return } } }
                add("Name", "name", "official_name", "brand")
                add("Owner", "owner", "contact:owner")
                add("Operator", "operator")
                add("Type", "building")
                add("Use", "amenity", "shop", "office", "leisure", "tourism", "craft", "industrial", "building:use")
                add("Levels", "building:levels")
                add("Height", "height", "est_height")
                add("Built", "start_date", "year_built", "construction_date")
                add("Material", "building:material")
                add("Roof", "roof:shape")
                add("Units", "building:flats")
                let addr = [t["addr:housenumber"], t["addr:street"], t["addr:city"], t["addr:state"], t["addr:postcode"]].compactMap { $0 }.joined(separator: " ")
                if !addr.isEmpty { rows.append(MetaRow("Address", addr)) }
                add("Website", "website", "contact:website")
                add("Phone", "phone", "contact:phone")
                add("Wikidata", "wikidata")
                rows.append(MetaRow("Footprint", String(format: "%.0f m from tap · %@%d", b.dist, b.type == "way" ? "W" : "R", b.id)))
                sections.append(IntelSection(title: "BUILDING", source: "OpenStreetMap · Overpass", rows: rows,
                                             link: "https://www.openstreetmap.org/\(b.type)/\(b.id)"))
            }

            let named = items.filter { $0.tags["name"] != nil }.prefix(10)
            if !named.isEmpty {
                let rows = named.map { el -> MetaRow in
                    let t = el.tags
                    let kind = t["amenity"] ?? t["shop"] ?? t["office"] ?? t["building"] ?? t["leisure"] ?? t["tourism"] ?? t["highway"] ?? t["landuse"] ?? t["man_made"] ?? "feature"
                    let op = t["operator"].map { " · \($0)" } ?? ""
                    return MetaRow("\(t["name"] ?? "?")", "\(kind.replacingOccurrences(of: "_", with: " "))\(op) · \(Int(el.dist)) m")
                }
                sections.append(IntelSection(title: "NEARBY (120 m)", source: "OpenStreetMap · Overpass", rows: rows))
            }
            return .success(sections)
        } catch { return .failure(error) }
    }

    // MARK: US Census geographies (US only; silently empty elsewhere)

    private func censusGeographies(_ c: CLLocationCoordinate2D) async -> Result<[IntelSection], Error> {
        guard (24.3...49.5).contains(c.latitude) && (-125.5 ... -66.5).contains(c.longitude)
            || (51...72).contains(c.latitude) && (-180 ... -129).contains(c.longitude)
            || (18.5...22.5).contains(c.latitude) && (-161 ... -154).contains(c.longitude) else { return .success([]) }
        let posix = Locale(identifier: "en_US_POSIX")
        let url = String(format: "https://geocoding.geo.census.gov/geocoder/geographies/coordinates?x=%.6f&y=%.6f&benchmark=Public_AR_Current&vintage=Current_Current&format=json", locale: posix, c.longitude, c.latitude)
        do {
            let d = try await intelGET(url, cache: "intel-census-\(Feeds.key(c)).json")
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let res = j["result"] as? [String: Any],
                  let geo = res["geographies"] as? [String: Any] else { return .success([]) }
            func first(_ key: String) -> [String: Any]? { (geo[key] as? [[String: Any]])?.first }
            func v(_ d: [String: Any]?, _ k: String) -> String {
                guard let d, let x = d[k] else { return "" }
                if let s = x as? String { return s }
                return String(describing: x)
            }
            var rows: [MetaRow] = []
            if let s = first("States") { rows.append(MetaRow("State", "\(v(s, "NAME")) (FIPS \(v(s, "STATE")))")) }
            if let co = first("Counties") { rows.append(MetaRow("County", "\(v(co, "NAME")) (FIPS \(v(co, "GEOID")))")) }
            if let p = first("Incorporated Places") ?? first("Census Designated Places") { rows.append(MetaRow("Place", v(p, "NAME"))) }
            if let cs = first("County Subdivisions") { rows.append(MetaRow("Township", v(cs, "NAME"))) }
            if let t = first("Census Tracts") { rows.append(MetaRow("Tract", "\(v(t, "TRACT")) · GEOID \(v(t, "GEOID"))")) }
            if let bg = first("Census Block Groups") { rows.append(MetaRow("Block group", v(bg, "BLKGRP"))) }
            if let b = first("2020 Census Blocks") ?? first("Census Blocks") { rows.append(MetaRow("Block", "\(v(b, "BLOCK")) · GEOID \(v(b, "GEOID"))")) }
            if let cdKey = geo.keys.first(where: { $0.hasSuffix("Congressional Districts") }), let cd = first(cdKey) {
                let num = v(cd, "BASENAME").ifEmpty(v(cd, "NAME"))
                if !num.isEmpty { rows.append(MetaRow("Congressional", "District \(num)")) }
            }
            if let zKey = geo.keys.first(where: { $0.contains("Zip Code Tabulation") }), let z = first(zKey) {
                let zc = v(z, "ZCTA5").ifEmpty(v(z, "BASENAME"))
                if !zc.isEmpty { rows.append(MetaRow("ZCTA", zc)) }
            }
            guard !rows.isEmpty else { return .success([]) }
            return .success([IntelSection(title: "CENSUS GEOGRAPHY", source: "US Census Bureau geocoder", rows: rows)])
        } catch { return .failure(error) }
    }

    // MARK: Wikipedia nearby

    private func wikipediaNearby(_ c: CLLocationCoordinate2D) async -> Result<[IntelSection], Error> {
        let posix = Locale(identifier: "en_US_POSIX")
        let url = String(format: "https://en.wikipedia.org/w/api.php?action=query&list=geosearch&gscoord=%.6f%%7C%.6f&gsradius=1500&gslimit=6&format=json", locale: posix, c.latitude, c.longitude)
        do {
            let d = try await intelGET(url, cache: "intel-wiki-\(Feeds.key(c)).json")
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let q = j["query"] as? [String: Any],
                  let gs = q["geosearch"] as? [[String: Any]], !gs.isEmpty else { return .success([]) }
            let rows = gs.compactMap { g -> MetaRow? in
                guard let t = g["title"] as? String else { return nil }
                let dist = (g["dist"] as? Double) ?? 0
                return MetaRow(t, dist >= 1000 ? String(format: "%.1f km", dist / 1000) : "\(Int(dist)) m")
            }
            let firstTitle = (gs.first?["title"] as? String)?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            return .success([IntelSection(title: "WIKIPEDIA NEARBY", source: "Wikipedia geosearch", rows: rows,
                                          link: firstTitle.map { "https://en.wikipedia.org/wiki/\($0)" })])
        } catch { return .failure(error) }
    }
}

// MARK: - View

struct PlaceRecordsView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.openURL) private var openURL
    let entity: Entity

    private var intel: PlaceIntel? { s.intel[entity.id] }
    private var loading: Bool { s.intelLoading.contains(entity.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECORDS").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button { s.lookupIntel(for: entity, force: true) } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                    .disabled(loading)
            }
            if let intel {
                if let owner = intel.owner {
                    HStack(spacing: 8) {
                        Image(systemName: "person.text.rectangle").foregroundStyle(entity.kind.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("OWNER / OPERATOR").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
                            Text(owner).font(.system(size: 14, weight: .bold, design: .monospaced)).textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(entity.kind.color.opacity(0.12)))
                }
                if intel.isEmpty {
                    Text(loading ? "Querying public records…" : "No public record tags at this exact spot. Zoom in and tap directly on a building footprint, or search the address in Search → […]")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(intel.sections) { sec in section(sec) }
                if !intel.errors.isEmpty {
                    Text(intel.errors.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Text("Owner/operator fields are OpenStreetMap tags contributed by the public — often blank, sometimes stale. This is not a title or deed search.")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            } else if loading {
                Text("Querying OSM · Overpass · Census · Wikipedia…").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .onAppear { s.lookupIntel(for: entity) }
    }

    private func section(_ sec: IntelSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sec.title).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(entity.kind.color)
                Spacer()
                Text(sec.source).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                if let l = sec.link, let u = URL(string: l) {
                    Button { openURL(u) } label: { Image(systemName: "arrow.up.right.square").font(.caption) }
                }
            }
            VStack(spacing: 0) {
                ForEach(sec.rows) { row in
                    HStack(alignment: .top) {
                        Text(row.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.value).font(.system(size: 12, weight: ["Owner", "Operator"].contains(row.key) ? .bold : .semibold, design: .monospaced))
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
