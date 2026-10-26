import SwiftUI

struct VehiclePickerView: View {
    var onPick: (Vehicle) -> Void

    @State private var years: [EPAMenuItem] = []
    @State private var makes: [EPAMenuItem] = []
    @State private var modelsByMake: [String: [EPAMenuItem]] = [:]
    @State private var options: [EPAMenuItem] = []
    @State private var year: String?
    @State private var query = ""
    @State private var chosen: (make: String, model: EPAMenuItem)?
    @State private var loading = false
    @State private var error: String?
    @State private var manual = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Form {
            if manual {
                ManualVehicleForm(onPick: onPick)
                Section { Button("Search the EPA list instead") { manual = false } }
            } else {
                yearSection
                if year != nil {
                    if let chosen {
                        trimSection(chosen)
                    } else {
                        searchSection
                        resultsSection
                    }
                }
                if loading { Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } } }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        Button("Retry") { Task { await retry() } }
                    }
                }
                Section {
                    Button("Can't find it? Enter my car manually") { manual = true }
                } footer: {
                    Text("Ratings from fueleconomy.gov.")
                }
            }
        }
        .navigationTitle("Your car")
        .task { if years.isEmpty { await loadYears() } }
        .onChange(of: year) { _, y in
            makes = []; modelsByMake = [:]; options = []; chosen = nil
            guard let y else { return }
            Task {
                await load {
                    let list = try await FuelEconomyAPI.makes(year: y)
                    if year == y { makes = list }
                }
                await ensureModels()
            }
        }
        .onChange(of: query) { _, q in
            let p = VehicleSearch.parse(q, years: years.map(\.value), makes: makes.map(\.value))
            if let y = p.year, y != year {
                year = y
                query = VehicleSearch.words(q).filter { $0 != y }.joined(separator: " ") + " "
                return
            }
            Task { await ensureModels() }
        }
    }

    private var yearSection: some View {
        Section {
            Picker("Model year", selection: $year) {
                Text("Choose…").tag(String?.none)
                ForEach(years) { y in
                    Text(y.text).monospacedDigit().tag(Optional(y.value))
                }
            }
            .pickerStyle(.menu)
            .disabled(years.isEmpty)
        } header: {
            Text("1 · Model year")
        } footer: {
            if year == nil { Text("Or type it in the search.") }
        }
    }

    private var parsed: VehicleSearch.Parsed {
        VehicleSearch.parse(query, years: years.map(\.value), makes: makes.map(\.value))
    }

    private var searchSection: some View {
        Section {
            HStack {
                TextField("Search make and model, e.g. Honda Civic", text: $query)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: { Text("Clear").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
        } header: {
            Text("2 · Search your car (\(year ?? ""))")
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        let p = parsed
        if let make = p.make {
            let all = modelsByMake[make] ?? []
            let hits = VehicleSearch.matchModels(p.rest, models: all.map(\.text))
            let items = hits.compactMap { t in all.first { $0.text == t } }
            Section {
                if items.isEmpty && !loading && modelsByMake[make] != nil {
                    Text("No \(make) models match \"\(p.rest.joined(separator: " "))\".")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(items.prefix(60)) { m in
                    resultRow(title: "\(make) \(m.text)") { selectModel(make: make, model: m) }
                }
            } header: {
                Text(items.isEmpty ? make : "\(make) · \(items.count) model\(items.count == 1 ? "" : "s")")
            }
        } else {
            let hits = VehicleSearch.matchMakes(p.rest.joined(separator: " "), makes: makes.map(\.value))
            Section {
                if hits.isEmpty && !makes.isEmpty {
                    Text("No make matches \"\(query.trimmingCharacters(in: .whitespaces))\".")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(hits.prefix(80), id: \.self) { make in
                    resultRow(title: make) {
                        query = make + " "
                        searchFocused = true
                    }
                }
            } header: {
                Text(query.isEmpty ? "All makes" : "Makes")
            }
        }
    }

    private func resultRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
    }

    private func trimSection(_ c: (make: String, model: EPAMenuItem)) -> some View {
        Section {
            ForEach(options) { o in
                resultRow(title: o.text) { Task { await pick(o) } }
            }
            Button("Change car") { chosen = nil; options = [] }
        } header: {
            Text("3 · Engine / trim: \(year ?? "") \(c.make) \(c.model.text)")
        }
    }

    private func load(_ work: () async throws -> Void) async {
        loading = true; error = nil
        defer { loading = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }

    private func loadYears() async {
        await load {
            let all = try await FuelEconomyAPI.years()
            years = all.sorted { $0.value > $1.value }
        }
    }

    private func retry() async {
        if years.isEmpty { await loadYears(); return }
        if let y = year, makes.isEmpty {
            await load {
                let list = try await FuelEconomyAPI.makes(year: y)
                if year == y { makes = list }
            }
        }
        await ensureModels()
    }

    private func ensureModels() async {
        guard let y = year, let make = parsed.make, modelsByMake[make] == nil else { return }
        await load {
            let list = try await FuelEconomyAPI.models(year: y, make: make)
            if year == y { modelsByMake[make] = list }
        }
    }

    private func selectModel(make: String, model: EPAMenuItem) {
        guard let y = year else { return }
        searchFocused = false
        chosen = (make, model)
        options = []
        Task {
            await load {
                let list = try await FuelEconomyAPI.options(year: y, make: make, model: model.value)
                if chosen?.model.value == model.value { options = list }
            }
            if options.count == 1, let only = options.first { await pick(only) }
        }
    }

    private func pick(_ option: EPAMenuItem) async {
        await load {
            let v = try await FuelEconomyAPI.vehicle(id: option.value)
            let vehicle = Vehicle(make: v.make.isEmpty ? (chosen?.make ?? "") : v.make,
                                  model: v.model.isEmpty ? (chosen?.model.text ?? "") : v.model,
                                  year: v.year > 0 ? v.year : Int(year ?? "") ?? 0,
                                  epaId: v.id, epaCity: v.city, epaHwy: v.highway, epaCombined: v.combined,
                                  fuelType: v.fuelType, atvType: v.atvType,
                                  regenFactor: Vehicle.defaultRegen(atvType: v.atvType), trim: option.text)
            onPick(vehicle)
        }
    }
}

private struct ManualVehicleForm: View {
    var onPick: (Vehicle) -> Void
    private static let firstYear = 1984
    private static let newestYear = Calendar.current.component(.year, from: Date()) + 1
    private static let typicalAge = 5
    @State private var year = Calendar.current.component(.year, from: Date()) - typicalAge
    @State private var make = ""
    @State private var model = ""
    @State private var combined: Double?
    @State private var hybrid = false

    var body: some View {
        Section("Your car") {
            Picker("Year", selection: $year) {
                ForEach((Self.firstYear...Self.newestYear).reversed(), id: \.self) { y in
                    Text(String(y)).monospacedDigit().tag(y)
                }
            }
            .pickerStyle(.menu)
            TextField("Make (e.g. Honda)", text: $make)
            TextField("Model (e.g. Civic)", text: $model)
            LabeledContent("Combined MPG (window sticker)") {
                TextField("optional", value: $combined, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Toggle("Hybrid / electric", isOn: $hybrid)
        }
        Section {
            Button("Use this car") {
                onPick(Vehicle(make: make, model: model, year: year, epaCombined: combined, atvType: hybrid ? "Hybrid" : nil,
                               regenFactor: hybrid ? 0.5 : 0))
            }
            .disabled(make.trimmingCharacters(in: .whitespaces).isEmpty || model.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
