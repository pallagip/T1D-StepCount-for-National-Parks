import Foundation
import Combine
import CoreML

/// Population backbone inference (pop-GBR trio) + personal adapter.
/// Mirrors popbg train_pop/adapt_personal featurization EXACTLY.
@MainActor
final class Predictor: ObservableObject {
    static let shared = Predictor()

    struct Config: Decodable {
        var features: [String]
        var medians: [String: Double]
        var safety_margin: Double
    }
    struct Adapter: Decodable {
        var alpha: Double
        var beta: Double
        var steps_per_mile: Double
        var personal_margin: Double
    }

    /// How stepsTo10 was resolved. Only meaningful when stepsTo10 is finite.
    /// .atLeast and .bestCase are lower bounds ("N+ steps"), not central estimates.
    enum StepsTo10Kind {
        case exact         // median curve crosses -10 within 0...10k
        case extrapolated  // positive tail gain extrapolated past 10k (capped at 30k)
        case atLeast       // steep rise: timing at typical trend; the rise adds more steps
        case bestCase      // upper curve's own crossing; earliest plausible -10
    }

    struct Result {
        var stepsTo10: Double  // NaN when walking shows no gain at all
        var milesTo10: Double
        var stepsTo70: Double  // conservative bound; NaN if beyond 10k
        var milesTo70: Double
        var bg0: Double
        var stepsTo10Kind: StepsTo10Kind = .exact
        var bestDropInRange: Double = .nan  // max median drop over 0...10k
    }

    private var q10: MLModel?
    private var q50: MLModel?
    private var q90: MLModel?
    private var config: Config?
    private var adapter: Adapter?
    @Published var ready = false
    @Published var loadError: String?

    private func modelURL(_ n: String) throws -> URL {
        // Xcode compiles .mlmodel -> .mlmodelc at build time; prefer compiled.
        if let u = Bundle.main.url(forResource: n, withExtension: "mlmodelc") { return u }
        if let u = Bundle.main.url(forResource: n, withExtension: "mlmodel") { return u }
        throw NSError(domain: "bundle", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "missing model \(n)"])
    }

    func load() {
        do {
            func url(_ n: String, _ e: String) throws -> URL {
                guard let u = Bundle.main.url(forResource: n, withExtension: e) else {
                    throw NSError(domain: "bundle", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "missing \(n).\(e)"])
                }
                return u
            }
            q10 = try MLModel(contentsOf: modelURL("pop_gbr_q10"))
            q50 = try MLModel(contentsOf: modelURL("pop_gbr_q50"))
            q90 = try MLModel(contentsOf: modelURL("pop_gbr_q90"))
            config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url("pop_gbr_features", "json")))
            adapter = try JSONDecoder().decode(Adapter.self, from: Data(contentsOf: url("adapter", "json")))
            ready = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func predict(_ m: MLModel, _ feats: [String: Double]) -> Double? {
        var dict: [String: MLFeatureValue] = [:]
        for (k, v) in feats { dict[k] = MLFeatureValue(double: v) }
        guard let out = try? m.prediction(from: MLDictionaryFeatureProvider(dictionary: dict)),
              let fv = out.featureValue(for: "drop") else { return nil }
        // pop-GBR outputs a Double "drop" (see generated pop_gbr_q*Output.drop).
        // Handle int64/multiArray too so a model re-export can't silently break us.
        switch fv.type {
        case .double:
            return fv.doubleValue
        case .int64:
            return Double(fv.int64Value)
        case .multiArray:
            guard let mv = fv.multiArrayValue else { return nil }
            return mv[0].doubleValue
        default:
            return nil
        }
    }

    /// bg0 from CareLink; hr* from HealthKit (nil = missing, imputed like training);
    /// cadence = recent or planned; planMin = planned walk length.
    ///
    /// stepsTo10 resolution: direct median crossing when it exists; on a steep
    /// rise with no crossing, a re-query at the typical trend gives a
    /// model-grounded lower bound; otherwise a positive tail slope is
    /// extrapolated past 10k; last, the upper curve's own crossing gives the
    /// earliest plausible -10 (best case). NaN only when not even the
    /// optimistic curve reaches -10 in range.
    func predict(bg0: Double, hour: Double, dow: Int,
                 hrRest: Double?, hrWalk: Double?, hrCov: Double?,
                 preTrend15: Double?, cadence: Double, planMin: Double) -> Result? {
        guard let adapter else { return nil }
        let hrRise: Double? = (hrWalk != nil && hrRest != nil) ? hrWalk! - hrRest! : nil
        guard let (mmd, mhi) = curves(bg0: bg0, hour: hour, dow: dow,
                                      hrRise: hrRise, hrRest: hrRest, hrWalk: hrWalk, hrCov: hrCov,
                                      preTrend15: preTrend15, cadence: cadence, planMin: planMin) else {
            return nil
        }
        let grid = stride(from: 0.0, through: 10000.0, by: 100.0).map { $0 }
        let best = mmd.max() ?? .nan
        var s10 = Self.hitting(grid: grid, drops: mmd, level: 10.0)
        var kind = StepsTo10Kind.exact
        if s10.isNaN {
            if (preTrend15 ?? 0) > 5 {
                // Steep rise (+5/15min ~= +20/hr): the personalized curve expects
                // continued rise, so it can't time -10. Timing at the typical
                // trend is a lower bound — the actual rise only adds more steps.
                if let typical = config?.medians["pre_trend15"],
                   let (nmd, _) = curves(bg0: bg0, hour: hour, dow: dow,
                                         hrRise: hrRise, hrRest: hrRest, hrWalk: hrWalk, hrCov: hrCov,
                                         preTrend15: typical, cadence: cadence, planMin: planMin) {
                    let n10 = Self.hitting(grid: grid, drops: nmd, level: 10.0)
                    if n10.isFinite, n10 > 0 {
                        s10 = n10
                        kind = .atLeast
                    }
                }
            } else if let x = Self.extrapolate(grid: grid, drops: mmd, level: 10.0), x <= 30000 {
                // Slow-but-positive gain that runs out of range: extend the tail.
                s10 = x
                kind = .extrapolated
            }
            if s10.isNaN {
                // Last resort: the upper (optimistic) curve's own crossing — the
                // earliest plausible -10. Honest only as a lower bound: the
                // median itself expects longer (or continued rise).
                let h10 = Self.hitting(grid: grid, drops: mhi, level: 10.0)
                if h10.isFinite, h10 > 0 {
                    s10 = h10
                    kind = .bestCase
                }
            }
        }
        let s70 = Self.hitting(grid: grid, drops: mhi.map { $0 + adapter.personal_margin },
                          level: bg0 - 70.0)
        let spm = adapter.steps_per_mile
        return Result(stepsTo10: s10, milesTo10: s10 / spm,
                      stepsTo70: s70, milesTo70: s70 / spm, bg0: bg0,
                      stepsTo10Kind: kind, bestDropInRange: best)
    }

    /// Median + upper adapted drop curves over 0...10k steps. Nil on model error.
    private func curves(bg0: Double, hour: Double, dow: Int,
                        hrRise: Double?, hrRest: Double?, hrWalk: Double?, hrCov: Double?,
                        preTrend15: Double?, cadence: Double, planMin: Double) -> (mmd: [Double], mhi: [Double])? {
        guard let q10, let q50, let q90, let config, let adapter else { return nil }
        let med = config.medians
        let nanCols = ["hr_rise", "hr_rest", "hr_walk", "hr_cov", "pre_trend15"]
        let total = cadence * planMin
        let weekend = (dow >= 5) ? 1.0 : 0.0
        var lo: [Double] = [], md: [Double] = [], hi: [Double] = []
        var h = 0.0
        while h <= 10000 {
            var f: [String: Double] = [
                "h": h, "seff": max(0, h - 500) / 1000.0, "bg0": bg0, "hour": hour,
                "sin_h": sin(2 * .pi * hour / 24), "cos_h": cos(2 * .pi * hour / 24),
                "dow": Double(dow), "weekend": weekend,
                "mean_cadence": cadence, "duration_min": planMin, "total_steps": total,
            ]
            let raw: [String: Double?] = ["hr_rise": hrRise, "hr_rest": hrRest,
                                          "hr_walk": hrWalk, "hr_cov": hrCov,
                                          "pre_trend15": preTrend15]
            for c in nanCols {
                if let o = raw[c], let v = o {
                    f[c] = v; f[c + "_miss"] = 0
                } else {
                    f[c] = med[c] ?? 0; f[c + "_miss"] = 1
                }
            }
            guard let a = predict(q10, f), let b = predict(q50, f), let c = predict(q90, f) else {
                return nil
            }
            let s = [a, b, c].sorted()
            lo.append(s[0]); md.append(s[1]); hi.append(s[2])
            h += 100
        }
        // adapter: alpha*curve + beta, re-sorted
        func adapt(_ xs: [Double]) -> [Double] { xs.map { adapter.alpha * $0 + adapter.beta } }
        let A = adapt(lo), B = adapt(md), C = adapt(hi)
        var mmd: [Double] = [], mhi: [Double] = []
        for i in 0..<A.count {
            let s = [A[i], B[i], C[i]].sorted()
            mmd.append(s[1]); mhi.append(s[2])
        }
        return (mmd, mhi)
    }

    static func hitting(grid: [Double], drops: [Double], level: Double) -> Double {
        var idx: [Int] = []
        for i in 0..<drops.count where !drops[i].isNaN { idx.append(i) }
        guard idx.count >= 2 else { return .nan }
        if drops[idx[0]] >= level { return grid[idx[0]] }
        for k in 0..<(idx.count - 1) {
            let a = idx[k], b = idx[k + 1]
            if drops[a] < level && level <= drops[b] {
                let f = (level - drops[a]) / (drops[b] - drops[a] + 1e-9)
                return grid[a] + f * (grid[b] - grid[a])
            }
        }
        return .nan
    }

    /// Linear tail extrapolation past the 10k grid end. Returns nil when the
    /// curve is flat or falling at the range end (walking isn't gaining).
    static func extrapolate(grid: [Double], drops: [Double], level: Double) -> Double? {
        let span = 21  // last 2000 steps
        guard drops.count >= span, grid.count == drops.count else { return nil }
        let tail = Array(drops.suffix(span))
        guard tail.allSatisfy({ $0.isFinite }) else { return nil }
        // Least-squares slope over the tail (uniform 100-step grid).
        let m = Double(span)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (i, y) in tail.enumerated() {
            let x = Double(i) * 100.0
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let denom = m * sxx - sx * sx
        guard denom > 0 else { return nil }
        let slope = (m * sxy - sx * sy) / denom  // per step
        guard slope > 0 else { return nil }
        let last = tail.last!
        let shortfall = level - last
        guard shortfall > 0 else { return nil }
        return grid.last! + shortfall / slope
    }
}
