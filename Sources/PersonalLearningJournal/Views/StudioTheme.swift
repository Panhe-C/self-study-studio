import SwiftUI

public enum StudioTheme {
    public static let accent = Color(red: 0.12, green: 0.30, blue: 0.72)
    public static let planned = accent
    public static let completed = Color(red: 0.24, green: 0.50, blue: 0.38)
    public static let notice = Color(red: 0.82, green: 0.31, blue: 0.25)
    public static let pageBackground = Color(red: 0.96, green: 0.97, blue: 0.99)
    public static let mutedSurface = Color(red: 0.89, green: 0.91, blue: 0.95)
    public static let pageInset: CGFloat = 16
    public static let sectionSpacing: CGFloat = 24
    public static let rowSpacing: CGFloat = 12
}

public struct StudioSectionHeader: View {
    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .tint(StudioTheme.accent)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

public struct StudioNoticeRow: View {
    private let title: String
    private let detail: String?
    private let icon: String
    private let tint: Color

    public init(
        title: String,
        detail: String? = nil,
        icon: String = "exclamationmark.circle.fill",
        tint: Color = StudioTheme.notice
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
