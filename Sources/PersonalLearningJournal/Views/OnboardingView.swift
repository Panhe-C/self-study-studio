import SwiftUI

/// vNext onboarding (spec 6.2): one product promise sentence, then a choice
/// — create the first course (project shell + plan wizard) or record
/// manually first. No forced fake session. Existing users never see this:
/// `JournalViewModel.shouldShowMainTabs` gates on existing projects.
public struct OnboardingView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let onCreateCourse: (Project) -> Void

    @State private var courseName = ""
    @State private var manualName = ""
    @State private var manualArea = ""
    @State private var errorMessage: String?

    public init(
        viewModel: JournalViewModel,
        onCreateCourse: @escaping (Project) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onCreateCourse = onCreateCourse
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("onboarding.promise")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    TextField(
                        String(localized: "onboarding.course_name"),
                        text: $courseName
                    )
                    Button {
                        createCourse()
                    } label: {
                        Label("onboarding.create_course", systemImage: "book.closed.fill")
                    }
                    .disabled(courseName.trimmedForJournal.isEmpty)
                } footer: {
                    Text("onboarding.create_course_detail")
                }

                Section {
                    TextField(
                        String(localized: "onboarding.manual_name"),
                        text: $manualName
                    )
                    TextField(
                        String(localized: "onboarding.manual_area"),
                        text: $manualArea
                    )
                    Button {
                        createManualProject()
                    } label: {
                        Label("onboarding.manual", systemImage: "square.and.pencil")
                    }
                    .disabled(manualName.trimmedForJournal.isEmpty)
                } footer: {
                    Text("onboarding.manual_detail")
                }
            }
            .navigationTitle("Learning Trail")
            .alert(
                String(localized: "onboarding.error_title"),
                isPresented: .constant(errorMessage != nil)
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Creates the project shell and hands off to the plan wizard (presented
    /// by RootView so it survives the transition to the main tabs). The plan
    /// may stay a draft; Today simply shows no planned sessions until it is
    /// activated.
    private func createCourse() {
        do {
            let project = try viewModel.createIdea(name: courseName, area: "")
            onCreateCourse(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The manual path: one lightweight idea project through the existing
    /// create API, then the learner lands on Today.
    private func createManualProject() {
        do {
            _ = try viewModel.createIdea(name: manualName, area: manualArea)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
