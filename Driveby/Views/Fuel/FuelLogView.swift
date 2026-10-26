import SwiftUI

struct FuelLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(GarageStore.self) private var garage
    @State private var editing: FuelLog?
    @State private var csvURL: URL?

    private var logs: [FuelLog] { garage.logs(for: model.activeVehicle?.id) }

    private var tankMPG: [UUID: Double] {
        var out: [UUID: Double] = [:]
        for iv in Validation.tankIntervals(logs: garage.fuelLogs, drives: [], vehicleId: model.activeVehicle?.id) { out[iv.end.id] = iv.mpg }
        return out
    }

    var body: some View {
        Group {
            List {
                Section {
                    Text("Fill to the first click every time.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { ValidationView() } label: {
                        Text("See how your score predicts MPG")
                    }
                }
                Section(model.activeVehicle?.displayName ?? "Fill-ups") {
                    if logs.isEmpty {
                        Text("No fill-ups yet.").foregroundStyle(.secondary)
                    }
                    let mpg = tankMPG
                    ForEach(logs) { l in
                        Button { editing = l } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Fmt.dayTime.string(from: l.loggedAt)).font(.subheadline)
                                    Text(l.gallons == 0 ? String(format: "%.0f mi · starting point", l.odometerMi)
                                         : String(format: "%.0f mi · %.3f gal", l.odometerMi, l.gallons) + (l.filledToFull ? "" : " · partial"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let m = mpg[l.id] { Text(String(format: "%.1f mpg", m)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                                    if let p = l.pricePerGallon { Text(String(format: "$%.2f/gal", p)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        let ids = idx.map { logs[$0].id }
                        ids.forEach { garage.deleteFuelLog($0) }
                    }
                }
            }
            .navigationTitle("Fuel log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = FuelLog(vehicleId: model.activeVehicle?.id, loggedAt: Date(),
                                          odometerMi: (logs.first?.odometerMi ?? 0), gallons: 0)
                    } label: { Text("Add") }
                    .accessibilityLabel("Add fill-up")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let csvURL {
                        ShareLink(item: csvURL) { Text("Export") }
                    }
                }
            }
            .sheet(item: $editing) { log in
                FuelEntryForm(log: log, isNew: !garage.fuelLogs.contains { $0.id == log.id })
            }
            .task(id: garage.fuelLogs.count) {
                let url = Storage.exportsRoot.appendingPathComponent("fuel_log.csv")
                try? garage.fuelCSV().data(using: .utf8)?.write(to: url, options: .atomic)
                csvURL = url
            }
        }
    }
}

struct FuelEntryForm: View {
    @State var log: FuelLog
    var isNew: Bool
    @Environment(GarageStore.self) private var garage
    @Environment(\.dismiss) private var dismiss
    @State private var odometer = ""
    @State private var gallons = ""
    @State private var price = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $log.loggedAt)
                    LabeledContent("Odometer (mi)") {
                        TextField("e.g. 48210", text: $odometer).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Gallons") {
                        TextField("e.g. 11.482", text: $gallons).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Total price ($)") {
                        TextField("optional", text: $price).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Toggle("Filled to the first click", isOn: $log.filledToFull)
                } footer: {
                    Text("Partial fills roll into the next full tank.")
                }
                if !garage.vehicles.isEmpty {
                    Picker("Vehicle", selection: $log.vehicleId) {
                        ForEach(garage.vehicles) { v in Text(v.displayName).tag(Optional(v.id)) }
                    }
                }
            }
            .navigationTitle(isNew ? "Add fill-up" : "Edit fill-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!valid)
                }
            }
            .onAppear {
                if log.odometerMi > 0 { odometer = String(format: "%.0f", log.odometerMi) }
                if log.gallons > 0 { gallons = String(format: "%.3f", log.gallons) }
                if let p = log.priceTotal { price = String(format: "%.2f", p) }
            }
        }
    }

    private func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    private var valid: Bool {
        guard let o = number(odometer), let g = number(gallons) else { return false }
        return o > 0 && g > 0 && g < 60
    }

    private func save() {
        guard let o = number(odometer), let g = number(gallons) else { return }
        log.odometerMi = o
        log.gallons = g
        log.priceTotal = number(price)
        garage.upsert(log)
        dismiss()
    }
}
