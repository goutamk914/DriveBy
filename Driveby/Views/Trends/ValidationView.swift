import Charts
import SwiftUI

struct ValidationView: View {
    @Environment(AppModel.self) private var model
    @Environment(GarageStore.self) private var garage
    @State private var source: ValidationResult.Source = .tank
    @State private var includeLowCoverage = false
    @State private var fitMessage: String?

    private var vehicle: Vehicle? { model.activeVehicle }

    private var result: ValidationResult {
        let drives = model.validationDrives(vehicleId: vehicle?.id)
        switch source {
        case .tank:
            let intervals = Validation.tankIntervals(logs: garage.fuelLogs, drives: drives, vehicleId: vehicle?.id)
            return Validation.tankValidation(intervals: intervals, model: model.model, epaCombined: vehicle?.epaCombined,
                                             minCoverage: includeLowCoverage ? 0 : 0.5)
        case .obd:
            return Validation.obdValidation(drives: drives, model: model.model, epaCombined: vehicle?.epaCombined)
        }
    }

    var body: some View {
        let r = result
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Ground truth", selection: $source) {
                    Text("Fuel log").tag(ValidationResult.Source.tank)
                    Text("OBD-II").tag(ValidationResult.Source.obd)
                }
                .pickerStyle(.segmented)
                chart(r)
                Card {
                    Text(r.honestSummary).font(.headline)
                    Text(explanation(r)).font(.subheadline).foregroundStyle(.secondary)
                    if source == .tank {
                        Toggle("Include tanks with < 50% of miles recorded", isOn: $includeLowCoverage).font(.subheadline)
                    }
                }
                fitCard(r)
                Card {
                    Text("The efficiency score is validated against real fuel consumption. The safety score is not — it's built from established telematics thresholds, and validating it would require crash data we don't have access to.")
                        .font(.footnote)
                }
                if source == .tank { tankTable }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Validation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chart(_ r: ValidationResult) -> some View {
        let yLabel = r.normalizedByEPA ? "Actual MPG ÷ EPA combined" : "Actual MPG"
        return Card {
            SectionHeader(title: "Efficiency score vs. real fuel economy", subtitle: r.source.rawValue)
            if r.points.isEmpty {
                ContentUnavailableView { Text("No data yet") } description: { Text(source == .tank
                                                         ? "Log every fill-up (fill to the first click). Each full tank becomes one point."
                                                         : "Connect an OBD-II BLE adapter in Settings — every drive becomes a point.") }
            } else {
                Chart {
                    ForEach(r.points) { p in
                        PointMark(x: .value("Efficiency score", p.score), y: .value(yLabel, p.target))
                            .foregroundStyle(p.lowCoverage ? Color.gray.opacity(0.5) : Theme.efficiency)
                            .symbolSize(p.lowCoverage ? 40 : 80)
                    }
                    if let fit = r.fit, let lo = r.points.map(\.score).min(), let hi = r.points.map(\.score).max() {
                        LineMark(x: .value("Efficiency score", lo), y: .value(yLabel, fit.predict(lo)), series: .value("fit", "fit"))
                            .foregroundStyle(.primary)
                        LineMark(x: .value("Efficiency score", hi), y: .value(yLabel, fit.predict(hi)), series: .value("fit", "fit"))
                            .foregroundStyle(.primary)
                    }
                }
                .chartXAxisLabel("Driveby efficiency score")
                .chartYAxisLabel(yLabel)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXScale(domain: .automatic(includesZero: false))
                .frame(height: 260)
                .overlay(alignment: .topLeading) {
                    if let fit = r.fit {
                        Text(String(format: "r² = %.2f   n = %d", fit.r2, r.fit?.n ?? r.n))
                            .font(.headline.monospacedDigit())
                            .padding(6).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(.leading, 40)
                    }
                }
            }
        }
    }

    private func explanation(_ r: ValidationResult) -> String {
        switch source {
        case .tank:
            return "Each point is one tank: miles driven ÷ gallons to refill, against the distance-weighted average score of the drives on that tank. Grey points had less than half their miles recorded, so they're excluded from the fit."
        case .obd:
            return "Each point is one drive: fuel measured by the car's own engine computer (OBD-II fuel rate, or air-flow ÷ 14.7) against that drive's score."
        }
    }

    private func fitCard(_ r: ValidationResult) -> some View {
        Card {
            SectionHeader(title: "Scoring weights", subtitle: "Source: \(model.baseModel.source)\(model.baseModel.fitN.map { " · fitted on n=\($0)" } ?? "")")
            ForEach(EfficiencyComponents.keys, id: \.self) { k in
                InfoRow(label: EfficiencyComponents.label(k), value: String(format: "%.2f", model.model.weights[k] ?? 0))
            }
            Button("Fit weights to my data") { fit() }
                .buttonStyle(.borderedProminent)
                .disabled(fitRows().count < 6)
            if fitRows().count < 6 {
                Text("Needs at least 6 \(source == .tank ? "tanks" : "OBD drives") — the notebook (notebooks/validation.ipynb) does the full analysis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fitMessage { Text(fitMessage).font(.footnote) }
            if model.baseModel.source != "default" {
                Button("Reset to default weights", role: .destructive) { model.resetScoringModel(); fitMessage = nil }
            }
        }
    }

    private func fitRows() -> [(components: EfficiencyComponents, target: Double)] {
        let drives = model.validationDrives(vehicleId: vehicle?.id)
        let epa = vehicle?.epaCombined
        switch source {
        case .tank:
            return Validation.tankIntervals(logs: garage.fuelLogs, drives: drives, vehicleId: vehicle?.id)
                .filter { $0.coverage >= 0.5 }
                .compactMap { iv -> (components: EfficiencyComponents, target: Double)? in
                    guard let c = iv.meanComponents else { return nil }
                    return (components: c, target: epa.map { e in iv.mpg / e } ?? iv.mpg)
                }
        case .obd:
            return drives.compactMap { d -> (components: EfficiencyComponents, target: Double)? in
                guard let g = d.obdFuelGal, g > 0.01, d.miles > 0.5 else { return nil }
                let mpg = d.miles / g
                return (components: d.components, target: epa.map { mpg / $0 } ?? mpg)
            }
        }
    }

    private func fit() {
        let rows = fitRows()
        guard let m = Validation.fitWeights(rows: rows, base: model.model) else {
            fitMessage = "The data didn't support any component (no negative relationship found). Keep collecting."
            return
        }
        model.setBaseModel(m)
        fitMessage = String(format: "Fitted on n=%d, in-sample r²=%.2f. In-sample fits flatter you — say n out loud.", m.fitN ?? rows.count, m.fitR2 ?? 0)
    }

    private var tankTable: some View {
        let drives = model.validationDrives(vehicleId: vehicle?.id)
        let intervals = Validation.tankIntervals(logs: garage.fuelLogs, drives: drives, vehicleId: vehicle?.id)
        return Card {
            SectionHeader(title: "Tanks", subtitle: "Coverage = recorded miles ÷ odometer miles")
            if intervals.isEmpty { Text("Two full fill-ups make the first tank.").foregroundStyle(.secondary) }
            ForEach(intervals) { iv in
                HStack {
                    Text(Fmt.day.string(from: iv.end.loggedAt)).font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f mpg", iv.mpg)).monospacedDigit()
                    Text(String(format: "%.0f%%", iv.coverage * 100)).monospacedDigit()
                        .foregroundStyle(iv.coverage < 0.5 ? Color.orange : Color.secondary).frame(width: 48, alignment: .trailing)
                }
                .font(.subheadline)
            }
        }
    }
}
