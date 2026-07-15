import SwiftUI

public struct OnboardingView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var name = ""
    @State private var area = ""
    @State private var errorMessage: String?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                    TextField("Area", text: $area)
                } header: {
                    Text("Capture an idea")
                } footer: {
                    Text("Start lightweight. Goal, Next Step, and Evidence Contract are added when you activate it.")
                }
                Button {
                    do {
                        _ = try viewModel.createIdea(name: name, area: area)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Create Idea", systemImage: "plus.circle.fill")
                }
                .disabled(name.trimmedForJournal.isEmpty)
            }
            .navigationTitle("Learning Trail")
            .alert("Could not create idea", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
