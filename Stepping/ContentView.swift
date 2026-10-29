import SwiftUI

// MARK: - Front-view style (mockup)

/// Block colors. Each front-view rectangle is a `BlockBackground`: blurred
/// mountain photo with a translucent tint of its color so text pops.
private let blockRed = Color(red: 0.878, green: 0.251, blue: 0.157)
private let barBlue = Color(red: 0.227, green: 0.623, blue: 1.0)

private func helv(_ size: CGFloat) -> Font {
    .custom("Helvetica-Bold", size: size)
}

/// Layout rules for this file:
/// - Every display line is centered and width-bounded
///   (`.frame(maxWidth: .infinity)` + horizontal padding) so
///   `minimumScaleFactor` can shrink it to fit instead of clipping past
///   the screen edge.
/// - The root view ignores only the vertical safe area: backgrounds bleed
///   top to bottom while content respects the horizontal safe area, so
///   nothing clips on any iPhone.
/// - No fixed text widths, no GeometryReader. Everything is centered —
///   except the settings button pinned to the bottom-left corner.
private struct BlockBackground: View {
    var color: Color
    var imageName: String? = nil
    var tint: Double = 0.45
    /// Soft top/bottom darkening instead of a flat tint, for bright photos.
    var scrim: Bool = false
    var body: some View {
        ZStack {
            Rectangle().fill(color)
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                if scrim {
                    LinearGradient(
                        colors: [color.opacity(0.7), color.opacity(0.2),
                                 color.opacity(0.2), color.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle().fill(color.opacity(tint))
                }
            }
        }
        .clipped()
    }
}

/// A centered, full-width display line that always shrinks to fit the screen
/// instead of overflowing past the edge.
private struct DisplayText: View {
    var text: String
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(helv(size))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .shadow(color: .black.opacity(0.25), radius: 6)
    }
}

struct ContentView: View {
    @ObservedObject var carelink = CareLinkClient.shared
    @ObservedObject var health = HealthKitManager.shared
    @ObservedObject var predictor = Predictor.shared

    @State private var bg: Double?
    @State private var bgAgeMin: Double?
    @State private var trendArrow = ""
    @State private var trend15: Double?
    @State private var last10: [CareLinkClient.GlucosePoint] = []
    @State private var result: Predictor.Result?
    @State private var status = "Starting…"
    @State private var busy = false
    @State private var showSettings = false
    @State private var planMin = 30.0
    @State private var demo = false
    @State private var lastUpdate: Date?
    @State private var snapshotText = "—"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                topBlock
                middleBlock
                bottomBlock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Settings button: white circle, bottom-left corner
            Button { showSettings = true } label: {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(blockRed)
                }
                .frame(width: 60, height: 60)
                .shadow(radius: 4)
            }
            .padding(.leading, 20)
            .padding(.bottom, 24)
            .accessibilityLabel("Settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .ignoresSafeArea(edges: .vertical)
        .sheet(isPresented: $showSettings) {
            SettingsView(planMin: $planMin, demo: $demo,
                         busy: busy, status: status,
                         bg: bg, bgAgeMin: bgAgeMin,
                         trend15: trend15, trendArrow: trendArrow,
                         last10: last10, result: result,
                         lastUpdate: lastUpdate, snapshotText: snapshotText,
                         onRefresh: { Task { await refresh() } })
        }
        .task {
            predictor.load()
            await health.requestAccess()
            await refresh()
        }
        .onChange(of: demo) { Task { await refresh() } }
        .onChange(of: planMin) { Task { await refresh() } }
    }

    // MARK: - Top block (red): current BG

    private var topBlock: some View {
        ZStack {
            BlockBackground(color: blockRed, imageName: "BlockTop")
            VStack(spacing: 0) {
                // Connection status, centered
                HStack(spacing: 32) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(carelink.isLoggedIn ? .green : .black)
                            .frame(width: 14, height: 14)
                        Text("Carelink")
                            .font(helv(14))
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(health.authorized ? .green : .black)
                            .frame(width: 14, height: 14)
                        Text("Health")
                            .font(helv(14))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)

                Spacer(minLength: 4)

                if let bg {
                    DisplayText(text: "\(Int(bg.rounded()))", size: 120)
                    DisplayText(text: "mg/dl", size: 80)
                } else {
                    DisplayText(text: "--", size: 120, color: .white.opacity(0.6))
                    DisplayText(text: "mg/dl", size: 80, color: .white.opacity(0.6))
                }

                Text(bgAgeText())
                    .font(helv(14))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { Task { await refresh() } }
    }

    // MARK: - Middle block (black): steps/miles to −10

    private var middleBlock: some View {
        ZStack {
            BlockBackground(color: .black, imageName: "BlockMiddle", scrim: true)
            VStack(spacing: 0) {
                if let bg, bg <= 80 {
                    Text("LOW — treat first, walking can push you lower")
                        .font(helv(15))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.white)
                }

                Spacer(minLength: 8)

                DisplayText(text: milesTo10Text(), size: 62)

                // Blue steps bar, full-bleed with centered text
                ZStack {
                    BlockBackground(color: barBlue)
                        .opacity(0.4)
                    DisplayText(text: stepsText(), size: 72)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity)

                DisplayText(text: "for a 10 mg/dl drop", size: 44)
                    .padding(.top, 4)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom block (red): miles until 70

    private var bottomBlock: some View {
        ZStack {
            BlockBackground(color: blockRed, imageName: "BlockBottom")
            VStack(spacing: 0) {
                Spacer(minLength: 4)
                if let r = result, r.milesTo70.isFinite {
                    DisplayText(text: String(format: "%.2f", r.milesTo70), size: 100)
                    DisplayText(text: "miles", size: 80)
                } else {
                    DisplayText(text: "10k+", size: 100)
                    DisplayText(text: "steps", size: 80)
                }
                // Centered caption; the spacer below clears the settings button.
                DisplayText(text: "until 70 mg/dl", size: 36)
                    .padding(.top, 2)
                Spacer()
                    .frame(height: 80) // room for the settings button row
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Front-view text helpers (detail stays in Settings)

    private func bgAgeText() -> String {
        var s: String
        if let m = bgAgeMin {
            s = m < 1 ? "just now" : "\(Int(m)) min ago"
        } else {
            s = "waiting for Guardian"
        }
        s += " • Guardian via CareLink EU"
        if bgStale() { s += " • stale" }
        return s
    }

    private func bgStale() -> Bool { (bgAgeMin ?? 999) > 15 }

    private func stepsText() -> String {
        guard let r = result, r.stepsTo10.isFinite else { return "— steps" }
        let n = Int(r.stepsTo10.rounded())
        switch r.stepsTo10Kind {
        case .exact: return "\(n) steps"
        case .extrapolated: return "≈\(n) steps"
        case .atLeast, .bestCase: return "\(n)+ steps"
        }
    }

    private func milesTo10Text() -> String {
        guard let r = result, r.milesTo10.isFinite else { return "— miles" }
        switch r.stepsTo10Kind {
        case .exact: return String(format: "%.2f miles", r.milesTo10)
        case .extrapolated: return String(format: "≈%.2f miles", r.milesTo10)
        case .atLeast, .bestCase: return String(format: "%.2f+ miles", r.milesTo10)
        }
    }

    // MARK: - Data (unchanged logic)

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard predictor.ready else {
            status = predictor.loadError ?? "Models not ready"
            return
        }
        if demo {
            bg = 175; bgAgeMin = 2; trendArrow = "→"; trend15 = -4.0
            snapshotText = "demo: HR 72/72, cadence 100"
            runPrediction(hrRest: 72, hrWalk: 72, hrCov: 1.0, cadence: 100)
            if result != nil {
                status = "DEMO values (simulator-friendly)"
            }
            lastUpdate = Date()
            return
        }
        do {
            guard carelink.isLoggedIn else {
                status = "Log in to CareLink to get Guardian glucose."
                showSettings = true
                return
            }
            let pts = try await carelink.fetchGlucose()
            guard let latest = pts.last else {
                status = "No Guardian readings returned. Try again in a few minutes."
                return
            }
            let ageMin = Date().timeIntervalSince(latest.date) / 60.0
            bg = latest.mgdl
            bgAgeMin = ageMin
            last10 = Array(pts.suffix(10))
            // trend: slope over last ~30 min
            let win = pts.filter { $0.date >= latest.date.addingTimeInterval(-35 * 60) }
            if win.count >= 2,
               let first = win.first,
               latest.date.timeIntervalSince(first.date) > 60 {
                let dtMin = latest.date.timeIntervalSince(first.date) / 60.0
                let rate = (latest.mgdl - first.mgdl) / dtMin  // per min
                trend15 = rate * 15
                trendArrow = rate > 3 ? "↑↑" : rate > 2 ? "↑" : rate > 1 ? "↗"
                    : rate < -3 ? "↓↓" : rate < -2 ? "↓" : rate < -1 ? "↘" : "→"
            } else {
                trend15 = nil; trendArrow = ""
            }
            if ageMin > 15 {
                status = "Guardian reading is stale (\(Int(ageMin)) min). Prediction paused."
                result = nil
                return
            }
            let snap = await health.snapshot()
            let cadence = snap.cadence5 ?? 100.0
            let hasSteps = snap.cadence5 != nil || snap.stepsLastHour > 0
            let hasHR = snap.hrRest != nil || snap.hrRecent != nil
            snapshotText = "rest \(fmt(snap.hrRest)) · recent \(fmt(snap.hrRecent)) · " +
                "cov \(Int((snap.hrCov * 100).rounded()))% · cadence \(Int(cadence.rounded()))"
            runPrediction(hrRest: snap.hrRest, hrWalk: snap.hrRecent ?? snap.hrRest,
                          hrCov: hasHR ? snap.hrCov : nil, cadence: cadence)
            if result == nil {
                // Keep "Prediction failed (model error)." set by runPrediction.
            } else if hasSteps && hasHR {
                status = "Live"
            } else if hasSteps {
                status = "iPhone steps ✓ · No watch — HR-free mode (≈1% accuracy cost)."
            } else if hasHR {
                status = "HR ✓ · No recent steps — assumed cadence 100."
            } else if health.authorized {
                status = "No watch needed — planned cadence 100. Prediction works."
            } else {
                status = "HealthKit unavailable — model defaults (prediction still works)."
            }
            lastUpdate = Date()
        } catch {
            status = "CareLink error: \(error.localizedDescription)"
        }
    }

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))"
    }

    private func runPrediction(hrRest: Double?, hrWalk: Double?, hrCov: Double?, cadence: Double) {
        guard let bg else { return }
        let now = Date()
        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60.0
        let dow = (cal.component(.weekday, from: now) + 5) % 7  // Monday=0
        print("[Predict] in bg0=\(bg) hr=\(hour) rest=\(hrRest?.description ?? "nil") " +
              "walk=\(hrWalk?.description ?? "nil") cov=\(hrCov?.description ?? "nil") " +
              "trend=\(trend15?.description ?? "nil") cad=\(cadence) plan=\(planMin)")
        result = predictor.predict(bg0: bg, hour: hour, dow: dow,
                                   hrRest: hrRest, hrWalk: hrWalk, hrCov: hrCov,
                                   preTrend15: trend15, cadence: cadence, planMin: planMin)
        if let r = result {
            print("[Predict] out s10=\(r.stepsTo10) s70=\(r.stepsTo70) kind=\(r.stepsTo10Kind) best=\(r.bestDropInRange)")
        } else {
            print("[Predict] FAILED (model error)")
            status = "Prediction failed (model error)."
        }
    }
}

#Preview {
    ContentView()
}
