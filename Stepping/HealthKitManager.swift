import Foundation
import Combine

#if canImport(HealthKit)
import HealthKit

/// HealthKit: steps + heart rate. Time comes from the clock.
/// BG is NEVER read here — only Guardian CareLink provides glucose.
@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    struct Snapshot {
        var cadence5: Double?      // steps/min over last 5 min
        var stepsLastHour: Double
        var hrRest: Double?        // median HR, last 60 min
        var hrRecent: Double?      // median HR, last 15 min
        var hrCov: Double          // fraction of last 15 min with HR samples
        var hasData: Bool
    }

    @Published var authorized = false
    private let store = HKHealthStore()

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let hr = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        do {
            try await store.requestAuthorization(toShare: [], read: [steps, hr])
            authorized = true
        } catch {
            authorized = false
        }
    }

    func snapshot() async -> Snapshot {
        let now = Date()
        let cal = Calendar.current
        // steps per minute, last 60 min
        var perMin: [Date: Double] = [:]
        let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let start60 = cal.date(byAdding: .minute, value: -60, to: now)!
        let q = HKStatisticsCollectionQuery(
            quantityType: steps,
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start60, end: now),
            options: .cumulativeSum,
            anchorDate: cal.startOfDay(for: now),
            intervalComponents: DateComponents(minute: 1))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.initialResultsHandler = { _, res, _ in
                res?.enumerateStatistics(from: start60, to: now) { s, _ in
                    if let v = s.sumQuantity()?.doubleValue(for: .count()) {
                        perMin[s.startDate] = v
                    }
                }
                c.resume()
            }
            store.execute(q)
        }
        let mins = perMin.keys.sorted()
        let last5 = mins.filter { $0 >= now.addingTimeInterval(-5 * 60) }
        let cadence5: Double? = last5.isEmpty ? nil :
            last5.reduce(0.0) { $0 + (perMin[$1] ?? 0) } / 5.0
        let stepsHour = perMin.values.reduce(0.0, +)
        // HR samples, last 60 min
        var samples: [(Date, Double)] = []
        let hr = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let pred = HKQuery.predicateForSamples(
            withStart: now.addingTimeInterval(-3600), end: now)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let q = HKSampleQuery(sampleType: hr, predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, res, _ in
                for s in (res as? [HKQuantitySample]) ?? [] {
                    samples.append((s.startDate,
                                    s.quantity.doubleValue(for: .count().unitDivided(by: .minute()))))
                }
                c.resume()
            }
            store.execute(q)
        }
        func median(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let hrRest = median(samples.map(\.1))
        let recent = samples.filter { $0.0 >= now.addingTimeInterval(-15 * 60) }
        let hrRecent = median(recent.map(\.1))
        let covered = Set(recent.map { Int($0.0.timeIntervalSince1970 / 60) }).count
        let hrCov = min(1.0, Double(covered) / 15.0)
        return Snapshot(cadence5: cadence5, stepsLastHour: stepsHour, hrRest: hrRest,
                        hrRecent: hrRecent, hrCov: hrCov,
                        hasData: !perMin.isEmpty || !samples.isEmpty)
    }
}

#else

/// Non-HealthKit platforms (macOS build target): stub with no data.
@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
    struct Snapshot {
        var cadence5: Double? = nil
        var stepsLastHour = 0.0
        var hrRest: Double? = nil
        var hrRecent: Double? = nil
        var hrCov = 0.0
        var hasData = false
    }
    @Published var authorized = false
    func requestAccess() async {}
    func snapshot() async -> Snapshot { Snapshot() }
}

#endif
