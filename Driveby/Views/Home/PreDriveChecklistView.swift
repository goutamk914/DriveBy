import SwiftUI

struct PreDriveChecklistView: View {
    var onStart: (String, Bool) -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var supervisor = ""
    @State private var supervisorPresent = false
    @State private var checked: Set<String> = []

    private struct Item: Identifiable { var id: String; var detail: String }

    private var items: [Item] {
        var list = [Item(id: "Phone mounted, level, not blocking your view",
                         detail: "Don't touch it until you park.")]
        if settings.driverMode == .newDriver {
            list = [
                Item(id: "Seat and mirrors adjusted", detail: "Reach the pedals, see all mirrors."),
                Item(id: "Everyone's seatbelt is on", detail: "Driver and every passenger."),
            ] + list + [
                Item(id: "Phone on Do Not Disturb (Driving Focus)", detail: "No notifications while you drive."),
                Item(id: "Route talked through with your supervisor", detail: "Know where you're going."),
                Item(id: "I won't touch the phone while the car is moving", detail: "Your supervisor stops the recording."),
            ]
        }
        return list
    }

    private var ready: Bool {
        supervisorPresent && !supervisor.trimmingCharacters(in: .whitespaces).isEmpty && items.allSatisfy { checked.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DisclaimerBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Supervisor's name", text: $supervisor)
                        .textContentType(.name)
                    Toggle(isOn: $supervisorPresent) {
                        Text("A licensed adult is in the passenger seat")
                    }
                } header: { Text("Supervising driver (required)") } footer: {
                    Text("Licensed driver 21+, parent or guardian, or licensed sibling 18+.")
                }
                Section(settings.driverMode == .newDriver ? "Before you drive" : "Quick check") {
                    ForEach(items) { item in
                        Button {
                            if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: checked.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(checked.contains(item.id) ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.id).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if settings.driverMode == .newDriver {
                                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button { go(auto: false) } label: {
                        Text("Start recording").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!ready)
                    Button { go(auto: true) } label: {
                        Text("Start automatically when the car moves").frame(maxWidth: .infinity)
                    }
                    .disabled(!ready)
                } footer: {
                    Text(ready ? "All set." : "Add your supervisor and tick every item.")
                }
            }
            .navigationTitle("Ready to practise?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if supervisor.isEmpty { supervisor = settings.defaultSupervisor } }
        }
    }

    private func go(auto: Bool) {
        let name = supervisor.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.defaultSupervisor = name
        onStart(name, auto)
        dismiss()
    }
}
