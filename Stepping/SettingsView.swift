import SwiftUI

/// Everything that is NOT on the front view lives here:
/// progress/status, prediction details, inputs, recent readings,
/// connections (CareLink / HealthKit) and diagnostics.
struct SettingsView: View {
    @ObservedObject var carelink = CareLinkClient.shared
    @ObservedObject var health = HealthKitManager.shared
    @ObservedObject var predictor = Predictor.shared

    @Binding var planMin: Double
    @Binding var demo: Bool

    var busy: Bool
    var status: String
    var bg: Double?
    var bgAgeMin: Double?
    var trend15: Double?
    var trendArrow: String
    var last10: [CareLinkClient.GlucosePoint]
    var result: Predictor.Result?
    var lastUpdate: Date?
    var snapshotText: String
    var onRefresh: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var showLogin = false

    var body: some View {
        NavigationStack {
            Form {
                // Progress / status
                Section("Status") {
                    HStack {
                        if busy { ProgressView() }
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Models")
                        Spacer()
                        Text(predictor.ready ? "ready" : (predictor.loadError ?? "loading…"))
                            .font(.caption)
                            .foregroundStyle(predictor.ready ? Color.secondary : Color.red)
                    }
                    if let t = lastUpdate {
                        HStack {
                            Text("Updated")
                            Spacer()
                            Text(t.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(busy ? "Refreshing…" : "Refresh now") { onRefresh() }
                        .disabled(busy)
                }

                // Full prediction detail (front shows only the headline numbers)
                if let r = result {
                    Section("Prediction detail") {
                        Labeled("Steps to −10", value(r.stepsTo10, suffix: "steps"))
                        Labeled("Miles to −10", String(format: "%.2f mi", r.milesTo10))
                        Labeled("Estimate kind", kindText(r.stepsTo10Kind))
                        Labeled("Steps to 70 (conservative)", value(r.stepsTo70, suffix: "steps"))
                        Labeled("Miles to 70 (conservative)", String(format: "%.2f mi", r.milesTo70))
                        if r.bestDropInRange.isFinite {
                            Labeled("Best drop in 10k", String(format: "%+.0f mg/dl", r.bestDropInRange))
                        }
                    }
                }

                // Inputs that feed the model
                Section("Inputs") {
                    Stepper("Planned walk \(Int(planMin)) min", value: $planMin, in: 10...120, step: 5)
                    Toggle("Demo values", isOn: $demo)
                    if let bg {
                        Labeled("BG", "\(Int(bg.rounded())) mg/dl \(trendArrow)")
                    }
                    if let m = bgAgeMin {
                        Labeled("BG age", m < 1 ? "just now" : "\(Int(m)) min ago")
                    }
                    if let t = trend15 {
                        Labeled("Trend /15 min", String(format: "%+.0f mg/dl", t))
                    }
                    Labeled("HR / cadence", snapshotText)
                }

                // Recent Guardian readings, newest first
                if !last10.isEmpty {
                    Section("Recent Guardian readings") {
                        ForEach(last10.suffix(10).reversed()) { p in
                            HStack {
                                Text("\(Int(p.mgdl.rounded())) mg/dl")
                                    .font(.headline)
                                Spacer()
                                Text(p.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Connections
                Section("Connections") {
                    HStack {
                        Text("CareLink")
                        Spacer()
                        Text(carelink.isLoggedIn ? "logged in" : "logged out")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(carelink.isLoggedIn ? "CareLink settings" : "Log in to CareLink") {
                        showLogin = true
                    }
                    HStack {
                        Text("HealthKit")
                        Spacer()
                        Text(health.authorized ? "allowed" : "not allowed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !health.authorized {
                        Button("Allow HealthKit") {
                            Task { await health.requestAccess() }
                        }
                    }
                }

                if !carelink.diagnostics.isEmpty {
                    Section("Diagnostics") {
                        Text(carelink.diagnostics)
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) { LoginView() }
        }
    }

    private func Labeled(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func value(_ steps: Double, suffix: String) -> String {
        steps.isFinite ? "\(Int(steps.rounded())) \(suffix)" : "beyond range"
    }

    private func kindText(_ kind: Predictor.StepsTo10Kind) -> String {
        switch kind {
        case .exact: return "exact (median crosses −10)"
        case .extrapolated: return "rough estimate (past 10k range)"
        case .atLeast: return "lower bound (BG rising)"
        case .bestCase: return "best case (earliest plausible)"
        }
    }
}
