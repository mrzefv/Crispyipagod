import Foundation
import CoreLocation

// MARK: - Parcel polygon (drawn on the map as property lines)

struct ParcelPolygon: Identifiable, Equatable {
    enum Kind: Equatable { case parcel, building }
    let id: String
    let kind: Kind
    let rings: [[CLLocationCoordinate2D]]   // outer ring first
    let attributes: [String: String]
    let isTarget: Bool

    static func == (a: ParcelPolygon, b: ParcelPolygon) -> Bool { a.id == b.id && a.isTarget == b.isTarget }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        guard let ring = rings.first, ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > c.latitude) != (b.latitude > c.latitude) {
                let x = (b.longitude - a.longitude) * (c.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if c.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

struct ParcelResult {
    var section: IntelSection?
    var polygons: [ParcelPolygon] = []
    var serviceName: String?
}

// MARK: - Lookup

extension Feeds {

    /// Field-name heuristics for county GIS schemas (they're all different).
    private static let ownerKeys   = ["owner", "ownnam", "own_name", "ownername", "owner1", "owner_1", "deeded", "taxpayer", "ownernme", "own1", "name1", "primary_owner", "owner_name"]
    private static let owner2Keys  = ["owner2", "owner_2", "ownnam2", "own2", "name2", "secondary_owner"]
    private static let idKeys      = ["parcelid", "parcel_id", "parcel", "pin", "apn", "parid", "prop_id", "propid", "parcelno", "parcel_no", "parcelnum", "parcel_num", "gispin", "pidn", "account", "acct"]
    private static let situsKeys   = ["situs", "site_addr", "siteaddr", "prop_addr", "propaddr", "property_address", "address", "addr", "location", "full_addr", "st_address"]
    private static let mailKeys    = ["mail", "mailing", "owner_addr", "own_addr", "mailaddr"]
    private static let acreKeys    = ["acre", "acres", "gis_acres", "calc_acre", "deed_acre", "land_acre", "lot_size", "sqft", "sq_ft", "area"]
    private static let useKeys     = ["landuse", "land_use", "use_code", "usecode", "usedesc", "use_desc", "class", "propclass", "prop_class", "zoning", "zone", "luc"]
    private static let valueKeys   = ["totalvalue", "total_val", "tot_val", "totval", "assessed", "assess", "apprais", "appr", "market", "mkt", "value", "val"]
    private static let saleKeys    = ["saledate", "sale_date", "sale_dt", "lastsale", "deed_date", "transfer", "salep", "sale_price", "saleprice", "sale_amt"]
    private static let yearKeys    = ["yearbuilt", "year_built", "yr_built", "yrblt", "built", "eff_year"]
    private static let legalKeys   = ["legal", "legaldesc", "legal_desc", "subdiv", "subdivision", "lot", "block", "section", "township", "range"]

    private static func pick(_ attrs: [String: String], _ keys: [String], exact: Bool = false) -> (String, String)? {
        let lower = attrs.map { ($0.key.lowercased(), $0.key, $0.value) }
        for k in keys {
            if let hit = lower.first(where: { exact ? $0.0 == k : $0.0.contains(k) }), !hit.2.isEmpty, hit.2 != "0", hit.2.lowercased() != "null" { return (hit.1, hit.2) }
        }
        return nil
    }

    private static func fmtMoney(_ s: String) -> String {
        if let d = Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")), d >= 1000 {
            let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: d)) ?? s
        }
        return s
    }

    private struct Candidate { let title: String; let url: String; let score: Int }

    /// Discover parcel feature services covering the point via the public ArcGIS Online item search (keyless).
    private func discoverParcelServices(_ c: CLLocationCoordinate2D) async -> [Candidate] {
        let posix = Locale(identifier: "en_US_POSIX")
        let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", locale: posix, c.longitude - 0.02, c.latitude - 0.02, c.longitude + 0.02, c.latitude + 0.02)
        var comps = URLComponents(string: "https://www.arcgis.com/sharing/rest/search")
        comps?.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "num", value: "40"),
            URLQueryItem(name: "q", value: "(parcels OR parcel OR \"tax parcels\" OR property) (type:\"Feature Service\" OR type:\"Map Service\")"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "sortField", value: "numviews"),
            URLQueryItem(name: "sortOrder", value: "desc")
        ]
        guard let url = comps?.url?.absoluteString else { return [] }
        guard let d = try? await intelGET(url, cache: "parcel-disc-\(Feeds.key(c)).json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let results = j["results"] as? [[String: Any]] else { return [] }
        var out: [Candidate] = []
        for r in results {
            guard let u = r["url"] as? String, u.hasPrefix("http"), let title = r["title"] as? String else { continue }
            let access = (r["access"] as? String) ?? "public"
            if access != "public" { continue }
            // extent = [[xmin,ymin],[xmax,ymax]] — make sure the point is really inside, not just the search bbox.
            if let ext = r["extent"] as? [[Double]], ext.count == 2, ext[0].count == 2, ext[1].count == 2 {
                let inside = c.longitude >= ext[0][0] && c.longitude <= ext[1][0] && c.latitude >= ext[0][1] && c.latitude <= ext[1][1]
                if !inside { continue }
                // Prefer tight (county-sized) extents over statewide/national ones.
                let span = (ext[1][0] - ext[0][0]) * (ext[1][1] - ext[0][1])
                var score = span < 2 ? 3 : span < 20 ? 2 : 1
                let t = title.lowercased()
                if t.contains("parcel") { score += 3 }
                if t.contains("owner") || t.contains("tax") { score += 1 }
                if t.contains("historic") || t.contains("archive") || t.contains("test") || t.contains("old") { score -= 3 }
                out.append(Candidate(title: title, url: u, score: score))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.url).inserted }.sorted { $0.score > $1.score }
    }

    /// Resolve a service root or layer URL to a polygon layer URL (…/FeatureServer/N).
    private func polygonLayerURL(_ serviceURL: String, cache: String) async -> String? {
        let clean = serviceURL.hasSuffix("/") ? String(serviceURL.dropLast()) : serviceURL
        // Already a layer URL?
        if let last = clean.split(separator: "/").last, Int(last) != nil { return clean }
        guard let d = try? await intelGET(clean + "?f=json", cache: cache),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let layers = (j["layers"] as? [[String: Any]]) ?? []
        // Prefer a polygon layer named like a parcel; otherwise first polygon layer; otherwise layer 0.
        let poly = layers.filter { ($0["geometryType"] as? String) == "esriGeometryPolygon" || $0["geometryType"] == nil }
        let named = poly.first { (($0["name"] as? String) ?? "").lowercased().contains("parcel") } ?? poly.first ?? layers.first
        guard let id = named?["id"] as? Int else { return layers.isEmpty ? nil : clean + "/0" }
        return clean + "/\(id)"
    }

    private func queryParcels(layer: String, at c: CLLocationCoordinate2D, cache: String) async -> [ParcelPolygon] {
        let posix = Locale(identifier: "en_US_POSIX")
        var comps = URLComponents(string: layer + "/query")
        comps?.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "geometry", value: String(format: "%.6f,%.6f", locale: posix, c.longitude, c.latitude)),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "distance", value: "150"),
            URLQueryItem(name: "units", value: "esriSRUnit_Meter"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "geometryPrecision", value: "6"),
            URLQueryItem(name: "resultRecordCount", value: "60")
        ]
        guard let url = comps?.url?.absoluteString,
              let d = try? await intelGET(url, cache: cache),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["error"] == nil,
              let feats = j["features"] as? [[String: Any]] else { return [] }
        var polys: [ParcelPolygon] = []
        for (i, f) in feats.enumerated() {
            guard let geom = f["geometry"] as? [String: Any], let rings = geom["rings"] as? [[[Double]]] else { continue }
            let coords: [[CLLocationCoordinate2D]] = rings.map { $0.compactMap { p in p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil } }.filter { $0.count > 2 }
            guard !coords.isEmpty else { continue }
            var attrs: [String: String] = [:]
            for (k, v) in (f["attributes"] as? [String: Any]) ?? [:] {
                if v is NSNull { continue }
                if let s = v as? String { let t = s.trimmingCharacters(in: .whitespaces); if !t.isEmpty { attrs[k] = t } }
                else if let n = v as? NSNumber {
                    // Epoch-ms dates are common in ArcGIS attributes.
                    let dv = n.doubleValue
                    if k.lowercased().contains("date") || k.lowercased().hasSuffix("_dt"), dv > 1_000_000_000_000 {
                        attrs[k] = Date(timeIntervalSince1970: dv / 1000).formatted(date: .abbreviated, time: .omitted)
                    } else if dv == dv.rounded() { attrs[k] = String(Int64(dv)) }
                    else { attrs[k] = String(format: "%.3f", dv) }
                } else { attrs[k] = String(describing: v) }
            }
            let pid = Feeds.pick(attrs, Feeds.idKeys)?.1 ?? "\(i)"
            let poly = ParcelPolygon(id: "parcel-\(layer.hashValue)-\(pid)-\(i)", kind: .parcel, rings: coords, attributes: attrs, isTarget: false)
            polys.append(ParcelPolygon(id: poly.id, kind: .parcel, rings: coords, attributes: attrs, isTarget: poly.contains(c)))
        }
        return polys
    }

    /// Parcel under the point (+ neighbours within 150 m) from the best local county GIS service.
    func parcelLookup(at c: CLLocationCoordinate2D) async -> ParcelResult {
        let cands = Array(await discoverParcelServices(c).prefix(6))
        guard !cands.isEmpty else { return ParcelResult() }
        let key = Feeds.key(c)

        // Query candidates concurrently; keep the first that has a polygon containing the point (best score wins ties).
        let hits: [(Candidate, [ParcelPolygon])] = await withTaskGroup(of: (Candidate, [ParcelPolygon])?.self) { group in
            for (n, cand) in cands.enumerated() {
                group.addTask {
                    let h = String(cand.url.hashValue, radix: 36)
                    guard let layer = await self.polygonLayerURL(cand.url, cache: "parcel-svc-\(h).json") else { return nil }
                    let polys = await self.queryParcels(layer: layer, at: c, cache: "parcel-q-\(key)-\(n)-\(h).json")
                    return polys.isEmpty ? nil : (cand, polys)
                }
            }
            var out: [(Candidate, [ParcelPolygon])] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        // Prefer services with a target polygon AND an owner-ish field, then score.
        func rank(_ h: (Candidate, [ParcelPolygon])) -> Int {
            let t = h.1.first { $0.isTarget }
            var r = h.0.score
            if t != nil { r += 10 }
            if let t, Feeds.pick(t.attributes, Feeds.ownerKeys) != nil { r += 10 }
            if let t, Feeds.pick(t.attributes, Feeds.idKeys) != nil { r += 3 }
            return r
        }
        guard let best = hits.max(by: { rank($0) < rank($1) }) else { return ParcelResult() }
        let polys = best.1
        var result = ParcelResult(section: nil, polygons: polys, serviceName: best.0.title)
        guard let target = polys.first(where: { $0.isTarget }) else {
            result.section = IntelSection(title: "PARCEL", source: best.0.title, rows: [MetaRow("Status", "No parcel polygon under this exact point — \(polys.count) nearby parcels drawn")])
            return result
        }

        let a = target.attributes
        var rows: [MetaRow] = []
        var used = Set<String>()
        func add(_ label: String, _ keys: [String], money: Bool = false) {
            if let hit = Feeds.pick(a, keys), !used.contains(hit.0) { used.insert(hit.0); rows.append(MetaRow(label, money ? Feeds.fmtMoney(hit.1) : hit.1)) }
        }
        add("Owner", Feeds.ownerKeys)
        add("Owner 2", Feeds.owner2Keys)
        add("Parcel ID", Feeds.idKeys)
        add("Situs address", Feeds.situsKeys)
        add("Mailing address", Feeds.mailKeys)
        add("Land use / class", Feeds.useKeys)
        add("Acreage / area", Feeds.acreKeys)
        add("Assessed / market value", Feeds.valueKeys, money: true)
        add("Last sale", Feeds.saleKeys, money: true)
        add("Year built", Feeds.yearKeys)
        add("Legal", Feeds.legalKeys)
        // Then everything else the county publishes, minus GIS plumbing.
        let junk = ["objectid", "shape", "globalid", "fid", "st_area", "st_length", "shape_area", "shape_len", "shape_leng", "shape__area", "shape__length"]
        let rest = a.filter { !used.contains($0.key) && !junk.contains($0.key.lowercased()) && !$0.key.lowercased().hasPrefix("shape") }
            .sorted { $0.key < $1.key }.prefix(40)
        for (k, v) in rest { rows.append(MetaRow(k.replacingOccurrences(of: "_", with: " "), v)) }
        rows.append(MetaRow("Property lines", "\(polys.count) parcels drawn · \(target.rings.first?.count ?? 0) vertices"))
        result.section = IntelSection(title: "PARCEL", source: best.0.title, rows: rows)
        return result
    }
}
