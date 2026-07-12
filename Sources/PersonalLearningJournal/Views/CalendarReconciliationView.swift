import SwiftUI

public struct CalendarReconciliationView: View {
    @ObservedObject private var viewModel: CalendarViewModel
    @State private var errorMessage: String?

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            if viewModel.reconciliationItems.isEmpty {
                ContentUnavailableView("No Calendar Changes", systemImage: "checkmark.calendar")
            }
            ForEach(viewModel.reconciliationItems) { item in
                Section(title(for: item.plannedSessionID)) {
                    LabeledContent("App", value: range(item.binding.lastWrittenStart, item.binding.lastWrittenEnd))
                    if let external = item.externalEvent {
                        LabeledContent("Calendar", value: range(external.start, external.end))
                    } else {
                        LabeledContent("Calendar", value: "Deleted")
                    }
                    if item.externalEvent != nil {
                        Button("Adopt Calendar Change") { resolve(item, action: .adoptExternal) }
                        Button("Overwrite Calendar Event") { resolve(item, action: .overwriteExternal) }
                    } else {
                        Button("Recreate Calendar Event") { resolve(item, action: .recreateDeleted) }
                    }
                    Button("Detach", role: .destructive) { resolve(item, action: .detach) }
                }
            }
        }
        .navigationTitle("Calendar Changes")
        .task { await viewModel.refresh() }
        .alert("Action failed", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func resolve(_ item: CalendarReconciliationItem, action: CalendarReconciliationAction) {
        Task {
            do {
                try await viewModel.resolve(item, action: action)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func title(for id: UUID) -> String {
        viewModel.items.first(where: { $0.plannedSessionID == id })?.title ?? "Study Session"
    }

    private func range(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
