import SwiftUI

public struct CalendarSettingsView: View {
    @ObservedObject private var viewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var preferredMinutes = 45
    @State private var dailyMinutes = 180
    @State private var gapMinutes = 15
    @State private var allowWeekends = true
    @State private var titleStyle: CalendarEventTitleStyle = .private
    @State private var timeZoneIdentifier = TimeZone.current.identifier
    @State private var targetCalendarIdentifier = ""
    @State private var days: [AvailabilityDayDraft] = []
    @State private var preferenceID = UUID()
    @State private var isRequestingAccess = false
    @State private var errorMessage: String?
    @State private var isConfirmingSharedCalendar = false
    @State private var sharedCalendarConfirmed = false

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("System Calendar") {
                LabeledContent("Access", value: accessTitle)
                if viewModel.authorization != .fullAccess {
                    Button {
                        requestAccess()
                    } label: {
                        Label("Enable Calendar Access", systemImage: "calendar.badge.plus")
                    }
                    .disabled(isRequestingAccess)
                }
                if viewModel.authorization == .fullAccess {
                    Picker("Target calendar", selection: $targetCalendarIdentifier) {
                        Text("Not selected").tag("")
                        ForEach(viewModel.writableCalendars) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }
                }
            }

            Section("Study Rhythm") {
                Stepper("Session: \(preferredMinutes) min", value: $preferredMinutes, in: 15...240, step: 15)
                Stepper("Daily limit: \(dailyMinutes) min", value: $dailyMinutes, in: 15...720, step: 15)
                Stepper("Minimum gap: \(gapMinutes) min", value: $gapMinutes, in: 0...120, step: 5)
                Toggle("Allow weekends", isOn: $allowWeekends)
                Picker("Event title", selection: $titleStyle) {
                    ForEach(CalendarEventTitleStyle.allCases, id: \.self) { style in
                        Text(title(for: style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Time Zone") {
                Picker("Time zone", selection: $timeZoneIdentifier) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                        Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                    }
                }
            }

            Section("Availability") {
                ForEach($days) { $day in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(day.name, isOn: $day.enabled)
                        if day.enabled {
                            Stepper("Start: \(minuteLabel(day.startMinute))", value: $day.startMinute, in: 0...(day.endMinute - 15), step: 15)
                            Stepper("End: \(minuteLabel(day.endMinute))", value: $day.endMinute, in: (day.startMinute + 15)...(24 * 60), step: 15)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Calendar Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .task { await load() }
        .alert("Settings unavailable", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Use a shared calendar?",
            isPresented: $isConfirmingSharedCalendar,
            titleVisibility: .visible
        ) {
            Button("Use Shared Calendar") {
                sharedCalendarConfirmed = true
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Project names, session titles, goals, and expected Proof will be visible to everyone who can access this calendar.")
        }
    }

    private var accessTitle: String {
        switch viewModel.authorization {
        case .notDetermined: "Not enabled"
        case .fullAccess: "Full access"
        case .denied: "Denied"
        case .restricted: "Restricted"
        }
    }

    private func load() async {
        await viewModel.refresh()
        if viewModel.authorization == .fullAccess {
            try? await viewModel.refreshWritableCalendars()
        }
        do {
            let configuration = try viewModel.schedulingConfiguration()
            preferenceID = configuration.preferences.id
            preferredMinutes = configuration.preferences.preferredSessionMinutes
            dailyMinutes = configuration.preferences.maximumDailyMinutes
            gapMinutes = configuration.preferences.minimumGapMinutes
            allowWeekends = configuration.preferences.allowWeekends
            titleStyle = configuration.preferences.eventTitleStyle
            targetCalendarIdentifier = configuration.targetCalendarIdentifier ?? ""
            timeZoneIdentifier = configuration.availabilityRules.first?.timeZoneIdentifier
                ?? viewModel.currentTimeZoneIdentifier
            days = (1...7).map { weekday in
                let rule = configuration.availabilityRules.first { $0.weekday == weekday }
                return AvailabilityDayDraft(
                    id: rule?.id ?? UUID(),
                    weekday: weekday,
                    enabled: rule?.enabled ?? false,
                    startMinute: rule?.startMinute ?? 18 * 60,
                    endMinute: rule?.endMinute ?? 22 * 60,
                    createdAt: rule?.createdAt ?? Date()
                )
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func requestAccess() {
        isRequestingAccess = true
        Task {
            defer { isRequestingAccess = false }
            do {
                _ = try await viewModel.requestCalendarAccess()
                let dedicated = try await viewModel.configureDedicatedCalendar()
                targetCalendarIdentifier = dedicated.id
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func save() {
        if !sharedCalendarConfirmed,
           viewModel.writableCalendars.first(where: { $0.id == targetCalendarIdentifier })?.isShared == true {
            isConfirmingSharedCalendar = true
            return
        }
        do {
            let updatedAt = Date()
            let preferences = try SchedulingPreferences(
                id: preferenceID,
                preferredSessionMinutes: preferredMinutes,
                maximumDailyMinutes: dailyMinutes,
                minimumGapMinutes: gapMinutes,
                allowWeekends: allowWeekends,
                eventTitleStyle: titleStyle,
                updatedAt: updatedAt
            )
            let rules = try days.map { day in
                try AvailabilityRule(
                    id: day.id,
                    weekday: day.weekday,
                    startMinute: day.startMinute,
                    endMinute: day.endMinute,
                    timeZoneIdentifier: timeZoneIdentifier,
                    minimumSessionMinutes: 15,
                    enabled: day.enabled,
                    createdAt: day.createdAt,
                    updatedAt: updatedAt
                )
            }
            try viewModel.saveSchedulingConfiguration(
                preferences: preferences,
                availabilityRules: rules,
                targetCalendarIdentifier: targetCalendarIdentifier.isEmpty ? nil : targetCalendarIdentifier
            )
            Task {
                await viewModel.changeTimeZone(to: timeZoneIdentifier)
                dismiss()
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func title(for style: CalendarEventTitleStyle) -> String {
        switch style {
        case .project: "Project"
        case .session: "Session"
        case .private: "Private"
        }
    }

    private func minuteLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private struct AvailabilityDayDraft: Identifiable {
    var id: UUID
    var weekday: Int
    var enabled: Bool
    var startMinute: Int
    var endMinute: Int
    var createdAt: Date

    var name: String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "Day \(weekday)"
    }
}
