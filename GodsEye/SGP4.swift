import Foundation
import CoreLocation

// Near-Earth SGP4 (Spacetrack Report #3). Deep-space objects (period >= 225 min) are rejected.

struct GPElement: Decodable {
    let OBJECT_NAME: String
    let NORAD_CAT_ID: Int
    let EPOCH: String
    let MEAN_MOTION: Double
    let ECCENTRICITY: Double
    let INCLINATION: Double
    let RA_OF_ASC_NODE: Double
    let ARG_OF_PERICENTER: Double
    let MEAN_ANOMALY: Double
    let BSTAR: Double
}

final class SGP4 {
    // Constants (WGS-72, STR#3)
    private static let ck2 = 5.413080e-4
    private static let ck4 = 0.62098875e-6
    private static let e6a = 1.0e-6
    private static let qoms2t = 1.88027916e-9
    private static let sConst = 1.01222928
    private static let xj3 = -0.253881e-5
    private static let xke = 0.743669161e-1
    static let xkmper = 6378.135
    private static let ae = 1.0
    private static let tothrd = 2.0 / 3.0
    private static let twoPi = Double.pi * 2

    let name: String
    let noradID: Int
    let epoch: Date
    let periodMinutes: Double

    // init-time variables
    private let xmo, xnodeo, omegao, eo, xincl, bstar: Double
    private var cosio = 0.0, sinio = 0.0, x3thm1 = 0.0, x1mth2 = 0.0, x7thm1 = 0.0
    private var aodp = 0.0, xnodp = 0.0, c1 = 0.0, c4 = 0.0, c5 = 0.0
    private var xmdot = 0.0, omgdot = 0.0, xnodot = 0.0, xnodcf = 0.0, t2cof = 0.0
    private var omgcof = 0.0, xmcof = 0.0, eta = 0.0, delmo = 0.0, sinmo = 0.0
    private var xlcof = 0.0, aycof = 0.0
    private var d2 = 0.0, d3 = 0.0, d4 = 0.0, t3cof = 0.0, t4cof = 0.0, t5cof = 0.0
    private var isimp = false

    init?(_ g: GPElement) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        guard let d = iso.date(from: g.EPOCH + "Z") ?? iso2.date(from: g.EPOCH + "Z") ?? iso.date(from: g.EPOCH) ?? iso2.date(from: g.EPOCH) else { return nil }
        let de2ra = Double.pi / 180
        let xno = g.MEAN_MOTION * SGP4.twoPi / 1440.0
        guard xno > 0 else { return nil }
        let period = SGP4.twoPi / xno
        guard period < 225 else { return nil }          // deep space: not supported
        guard g.ECCENTRICITY < 0.9 else { return nil }
        name = g.OBJECT_NAME
        noradID = g.NORAD_CAT_ID
        epoch = d
        periodMinutes = period
        xmo = g.MEAN_ANOMALY * de2ra
        xnodeo = g.RA_OF_ASC_NODE * de2ra
        omegao = g.ARG_OF_PERICENTER * de2ra
        eo = g.ECCENTRICITY
        xincl = g.INCLINATION * de2ra
        bstar = g.BSTAR
        initialize(xno: xno)
    }

    private func initialize(xno: Double) {
        let ck2 = SGP4.ck2, ck4 = SGP4.ck4, ae = SGP4.ae, tothrd = SGP4.tothrd
        let a1 = pow(SGP4.xke / xno, tothrd)
        cosio = cos(xincl)
        let theta2 = cosio * cosio
        x3thm1 = 3 * theta2 - 1
        let eosq = eo * eo
        let betao2 = 1 - eosq
        let betao = sqrt(betao2)
        let del1 = 1.5 * ck2 * x3thm1 / (a1 * a1 * betao * betao2)
        let ao = a1 * (1 - del1 * (0.5 * tothrd + del1 * (1 + 134.0 / 81.0 * del1)))
        let delo = 1.5 * ck2 * x3thm1 / (ao * ao * betao * betao2)
        xnodp = xno / (1 + delo)
        aodp = ao / (1 - delo)
        isimp = (aodp * (1 - eo) / ae) < (220.0 / SGP4.xkmper + ae)
        var s4 = SGP4.sConst
        var qoms24 = SGP4.qoms2t
        let perige = (aodp * (1 - eo) - ae) * SGP4.xkmper
        if perige < 156 {
            s4 = perige - 78
            if perige <= 98 { s4 = 20 }
            qoms24 = pow((120 - s4) * ae / SGP4.xkmper, 4)
            s4 = s4 / SGP4.xkmper + ae
        }
        let pinvsq = 1 / (aodp * aodp * betao2 * betao2)
        let tsi = 1 / (aodp - s4)
        eta = aodp * eo * tsi
        let etasq = eta * eta
        let eeta = eo * eta
        let psisq = abs(1 - etasq)
        let coef = qoms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let c2 = coef1 * xnodp * (aodp * (1 + 1.5 * etasq + eeta * (4 + etasq)) + 0.75 * ck2 * tsi / psisq * x3thm1 * (8 + 3 * etasq * (8 + etasq)))
        c1 = bstar * c2
        sinio = sin(xincl)
        let a3ovk2 = -SGP4.xj3 / ck2 * pow(ae, 3)
        let c3 = eo > 1e-4 ? coef * tsi * a3ovk2 * xnodp * ae * sinio / eo : 0
        x1mth2 = 1 - theta2
        c4 = 2 * xnodp * coef1 * aodp * betao2 * (eta * (2 + 0.5 * etasq) + eo * (0.5 + 2 * etasq) - 2 * ck2 * tsi / (aodp * psisq) * (-3 * x3thm1 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta)) + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * omegao)))
        c5 = 2 * coef1 * aodp * betao2 * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let theta4 = theta2 * theta2
        let temp1 = 3 * ck2 * pinvsq * xnodp
        let temp2 = temp1 * ck2 * pinvsq
        let temp3 = 1.25 * ck4 * pinvsq * pinvsq * xnodp
        xmdot = xnodp + 0.5 * temp1 * betao * x3thm1 + 0.0625 * temp2 * betao * (13 - 78 * theta2 + 137 * theta4)
        let x1m5th = 1 - 5 * theta2
        omgdot = -0.5 * temp1 * x1m5th + 0.0625 * temp2 * (7 - 114 * theta2 + 395 * theta4) + temp3 * (3 - 36 * theta2 + 49 * theta4)
        let xhdot1 = -temp1 * cosio
        xnodot = xhdot1 + (0.5 * temp2 * (4 - 19 * theta2) + 2 * temp3 * (3 - 7 * theta2)) * cosio
        omgcof = bstar * c3 * cos(omegao)
        xmcof = eeta != 0 ? -tothrd * coef * bstar * ae / eeta : 0
        xnodcf = 3.5 * betao2 * xhdot1 * c1
        t2cof = 1.5 * c1
        xlcof = 0.125 * a3ovk2 * sinio * (3 + 5 * cosio) / (1 + cosio)
        aycof = 0.25 * a3ovk2 * sinio
        delmo = pow(1 + eta * cos(xmo), 3)
        sinmo = sin(xmo)
        x7thm1 = 7 * theta2 - 1
        if !isimp {
            let c1sq = c1 * c1
            d2 = 4 * aodp * tsi * c1sq
            let temp = d2 * tsi * c1 / 3
            d3 = (17 * aodp + s4) * temp
            d4 = 0.5 * temp * aodp * tsi * (221 * aodp + 31 * s4) * c1
            t3cof = d2 + 2 * c1sq
            t4cof = 0.25 * (3 * d3 + c1 * (12 * d2 + 10 * c1sq))
            t5cof = 0.2 * (3 * d4 + 12 * c1 * d3 + 6 * d2 * d2 + 15 * c1sq * (2 * d2 + c1sq))
        }
    }

    /// ECI position (km) at the given time, or nil on decay/failure.
    func eci(at date: Date) -> (x: Double, y: Double, z: Double)? {
        let tsince = date.timeIntervalSince(epoch) / 60.0
        let ck2 = SGP4.ck2, xke = SGP4.xke
        let xmdf = xmo + xmdot * tsince
        let omgadf = omegao + omgdot * tsince
        let xnoddf = xnodeo + xnodot * tsince
        var omega = omgadf
        var xmp = xmdf
        let tsq = tsince * tsince
        let xnode = xnoddf + xnodcf * tsq
        var tempa = 1 - c1 * tsince
        var tempe = bstar * c4 * tsince
        var templ = t2cof * tsq
        if !isimp {
            let delomg = omgcof * tsince
            let delm = xmcof * (pow(1 + eta * cos(xmdf), 3) - delmo)
            let temp = delomg + delm
            xmp = xmdf + temp
            omega = omgadf - temp
            let tcube = tsq * tsince
            let tfour = tsince * tcube
            tempa = tempa - d2 * tsq - d3 * tcube - d4 * tfour
            tempe = tempe + bstar * c5 * (sin(xmp) - sinmo)
            templ = templ + t3cof * tcube + tfour * (t4cof + tsince * t5cof)
        }
        let a = aodp * tempa * tempa
        let e = eo - tempe
        guard a > 0.95, e >= -0.001, e < 1 else { return nil }
        let ec = max(e, 1e-6)
        let xl = xmp + omega + xnode + xnodp * templ
        let beta = sqrt(1 - ec * ec)
        let axn = ec * cos(omega)
        var temp = 1 / (a * beta * beta)
        let xll = temp * xlcof * axn
        let aynl = temp * aycof
        let xlt = xl + xll
        let ayn = ec * sin(omega) + aynl
        let capu = fmod2p(xlt - xnode)
        var temp2 = capu
        var sinepw = 0.0, cosepw = 0.0, temp3 = 0.0, temp4 = 0.0, temp5 = 0.0, temp6 = 0.0
        for _ in 0..<10 {
            sinepw = sin(temp2)
            cosepw = cos(temp2)
            temp3 = axn * sinepw
            temp4 = ayn * cosepw
            temp5 = axn * cosepw
            temp6 = ayn * sinepw
            let epw = (capu - temp4 + temp3 - temp2) / (1 - temp5 - temp6) + temp2
            if abs(epw - temp2) <= SGP4.e6a { break }
            temp2 = epw
        }
        let ecose = temp5 + temp6
        let esine = temp3 - temp4
        let elsq = axn * axn + ayn * ayn
        temp = 1 - elsq
        let pl = a * temp
        let r = a * (1 - ecose)
        let temp1 = 1 / r
        temp2 = a * temp1
        let betal = sqrt(temp)
        temp3 = 1 / (1 + betal)
        let cosu = temp2 * (cosepw - axn + ayn * esine * temp3)
        let sinu = temp2 * (sinepw - ayn - axn * esine * temp3)
        let u = atan2(sinu, cosu)
        let sin2u = 2 * sinu * cosu
        let cos2u = 2 * cosu * cosu - 1
        temp = 1 / pl
        let t1 = ck2 * temp
        let t2 = t1 * temp
        let rk = r * (1 - 1.5 * t2 * betal * x3thm1) + 0.5 * t1 * x1mth2 * cos2u
        let uk = u - 0.25 * t2 * x7thm1 * sin2u
        let xnodek = xnode + 1.5 * t2 * cosio * sin2u
        let xinck = xincl + 1.5 * t2 * cosio * sinio * cos2u
        let sinuk = sin(uk), cosuk = cos(uk)
        let sinik = sin(xinck), cosik = cos(xinck)
        let sinnok = sin(xnodek), cosnok = cos(xnodek)
        let xmx = -sinnok * cosik
        let xmy = cosnok * cosik
        let ux = xmx * sinuk + cosnok * cosuk
        let uy = xmy * sinuk + sinnok * cosuk
        let uz = sinik * sinuk
        let k = rk * SGP4.xkmper
        _ = xke
        guard rk > 1 else { return nil }
        return (k * ux, k * uy, k * uz)
    }

    private func fmod2p(_ x: Double) -> Double {
        var v = x.truncatingRemainder(dividingBy: SGP4.twoPi)
        if v < 0 { v += SGP4.twoPi }
        return v
    }

    /// Geodetic position at time.
    func geodetic(at date: Date) -> (lat: Double, lon: Double, altKm: Double, speedKmh: Double)? {
        guard let p = eci(at: date), let p2 = eci(at: date.addingTimeInterval(1)) else { return nil }
        let gmst = SGP4.gmst(date)
        var lon = atan2(p.y, p.x) - gmst
        lon = lon.truncatingRemainder(dividingBy: SGP4.twoPi)
        if lon > .pi { lon -= SGP4.twoPi }
        if lon < -.pi { lon += SGP4.twoPi }
        let a = 6378.137
        let f = 1 / 298.257223563
        let e2 = 2 * f - f * f
        let rxy = sqrt(p.x * p.x + p.y * p.y)
        var lat = atan2(p.z, rxy)
        var c = 1.0
        for _ in 0..<6 {
            let sl = sin(lat)
            c = 1 / sqrt(1 - e2 * sl * sl)
            lat = atan2(p.z + a * c * e2 * sl, rxy)
        }
        let alt = rxy / cos(lat) - a * c
        let dx = p2.x - p.x, dy = p2.y - p.y, dz = p2.z - p.z
        let speed = sqrt(dx * dx + dy * dy + dz * dz) * 3600
        return (lat * 180 / .pi, lon * 180 / .pi, alt, speed)
    }

    /// Ground-track points for the next `minutes`.
    func groundTrack(from date: Date, minutes: Double, step: Double = 1.0) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        var t = 0.0
        var lastLon = Double.nan
        while t <= minutes {
            if let g = geodetic(at: date.addingTimeInterval(t * 60)) {
                if !lastLon.isNaN, abs(g.lon - lastLon) > 180 { break }   // stop at dateline wrap
                lastLon = g.lon
                out.append(CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon))
            }
            t += step
        }
        return out
    }

    static func gmst(_ date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let t = (jd - 2451545.0) / 36525.0
        var sec = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        sec = sec.truncatingRemainder(dividingBy: 86400)
        if sec < 0 { sec += 86400 }
        return sec / 240.0 * .pi / 180.0
    }
}
