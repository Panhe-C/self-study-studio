import SwiftUI

public struct ProductHealthView: View {
    private let report: ProductHealthReport

    public init(report: ProductHealthReport) {
        self.report = report
    }

    public var body: some View {
        List {
            Section("Coverage") {
                LabeledContent("Canonical Next Steps", value: "\(report.canonicalStepProjects) / \(report.eligibleProjects)")
                LabeledContent("Accepted periods", value: "\(report.acceptedContractPeriods)")
                LabeledContent("Review-resolved periods", value: "\(report.resolvedContractPeriods)")
            }
            Section("Needs attention") {
                LabeledContent("Silent misses", value: "\(report.silentMisses)")
                LabeledContent("Incomplete Reviews", value: "\(report.incompleteReviews)")
            }
            Section("Evidence depth") {
                LabeledContent("Projects with Proof sequences", value: "\(report.projectsWithProofSequences)")
            }
        }
        .navigationTitle("product_health.title")
    }
}
