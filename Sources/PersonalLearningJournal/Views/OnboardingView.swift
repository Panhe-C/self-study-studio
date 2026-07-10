import SwiftUI

public struct OnboardingView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var projectDrafts = [
        OnboardingProjectForm(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "整理 perplexity 和 loss 的关系"
        )
    ]
    @State private var firstRecordProject: Project?
    @State private var errorMessage: String?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let pendingProject = viewModel.pendingFirstRecordProject {
                    List {
                        Section {
                            Text(pendingProject.name)
                                .font(.headline)
                            Text(pendingProject.currentNextStep)
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("Your First Record")
                        } footer: {
                            Text("Write one sentence about what you worked on. You can add Proof after saving.")
                        }

                        Section {
                            Button {
                                firstRecordProject = pendingProject
                            } label: {
                                Label("Record First Session", systemImage: "square.and.pencil")
                            }
                        }
                    }
                    .navigationTitle("One More Step")
                } else {
                    Form {
                        ForEach($projectDrafts) { $draft in
                            Section("Current Project") {
                                TextField("Project", text: $draft.name)
                                TextField("Area", text: $draft.area)
                                TextField("Goal", text: $draft.goal, axis: .vertical)
                                TextField("Next Step", text: $draft.nextStep, axis: .vertical)

                                if projectDrafts.count > 1 {
                                    Button(role: .destructive) {
                                        projectDrafts.removeAll { $0.id == draft.id }
                                    } label: {
                                        Label("Remove Project", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }

                        if projectDrafts.count < 3 {
                            Button {
                                projectDrafts.append(nextSuggestedProject())
                            } label: {
                                Label("Add Another Project", systemImage: "plus.circle")
                            }
                        }

                        Button {
                            do {
                                let projects = try viewModel.onboardProjects(
                                    projectDrafts.map {
                                        ProjectOnboardingDraft(
                                            name: $0.name,
                                            area: $0.area,
                                            goal: $0.goal,
                                            nextStep: $0.nextStep
                                        )
                                    }
                                )
                                firstRecordProject = projects.first
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        } label: {
                            Label("Continue to First Record", systemImage: "arrow.forward.circle.fill")
                        }
                    }
                    .navigationTitle("Learning Trail")
                }
            }
            .alert("Could not create project", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $firstRecordProject) { project in
                QuickLogView(viewModel: viewModel, project: project)
            }
        }
    }

    private func nextSuggestedProject() -> OnboardingProjectForm {
        let suggestions = [
            OnboardingProjectForm(
                name: "吉他弹唱",
                area: "Music",
                goal: "完整弹唱 3 首歌",
                nextStep: "练 F 到 C"
            ),
            OnboardingProjectForm(
                name: "DaVinci 调色",
                area: "Color",
                goal: "掌握基础调色工作流",
                nextStep: "做一组 before/after"
            )
        ]

        return suggestions.indices.contains(projectDrafts.count - 1)
            ? suggestions[projectDrafts.count - 1]
            : OnboardingProjectForm(name: "", area: "", goal: "", nextStep: "")
    }
}

private struct OnboardingProjectForm: Identifiable {
    var id = UUID()
    var name: String
    var area: String
    var goal: String
    var nextStep: String
}
