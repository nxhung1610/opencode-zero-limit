import Charts
import RelayDockCore
import SwiftUI

struct UsageView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Usage",
                    subtitle: "Observed activity read locally from OpenCode’s database."
                ) {
                    HStack(spacing: 8) {
                        Picker("Time window", selection: $model.usageDays) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("1 year").tag(365)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()

                        Button {
                            Task { await model.refreshUsage() }
                        } label: {
                            if model.usageLoading {
                                ProgressView().controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.usageLoading)
                        .help("Refresh local usage counters")
                        .accessibilityLabel("Refresh usage")
                    }
                }

                if let event = model.quotaEvent, isRecent(event) {
                    quotaNotice(event)
                }

                if let error = model.usageError {
                    ContentUnavailableView {
                        Label("Couldn't Read Usage", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task { await model.refreshUsage() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(minHeight: 220)
                } else if model.usageLoading && model.usageSummary == nil {
                    ProgressView("Reading OpenCode’s local database…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let summary = model.usageSummary {
                    summaryContent(summary)
                } else {
                    ContentUnavailableView(
                        "No Usage Data",
                        systemImage: "chart.bar",
                        description: Text("Usage appears after OpenCode records messages in its local database.")
                    )
                    .frame(minHeight: 220)
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: model.usageDays) {
            await model.refreshUsage()
        }
    }

    private func quotaNotice(_ event: QuotaEvent) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title + (event.rotatedTo.map { " — switched to \($0)" } ?? ""))
                        .font(.callout.weight(.semibold))
                    if !event.message.isEmpty {
                        Text(event.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let resetAt = event.resetAt {
                        Text("Resets \(Date(timeIntervalSince1970: TimeInterval(resetAt) / 1_000).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        } label: {
            Label("OpenCode quota event", systemImage: "bolt.horizontal.circle")
        }
    }

    private func isRecent(_ event: QuotaEvent) -> Bool {
        let age = Date().timeIntervalSince1970 * 1_000 - Double(event.at)
        return age >= 0 && age < 5 * 60 * 1_000
    }

    @ViewBuilder
    private func summaryContent(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    metric("Assistant messages", value: summary.assistantMessages.formatted())
                    metricDivider
                    metric("User messages", value: summary.userMessages.formatted())
                    metricDivider
                    metric("Sessions", value: summary.sessions.formatted())
                    metricDivider
                    metric("Observed cost", value: summary.cost.formatted(.currency(code: "USD")))
                    metricDivider
                    metric("Total tokens", value: summary.totalTokens.formatted(.number.notation(.compactName)))
                }
                .frame(minWidth: 720)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 18)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    metric("Assistant messages", value: summary.assistantMessages.formatted())
                    metric("User messages", value: summary.userMessages.formatted())
                    metric("Sessions", value: summary.sessions.formatted())
                    metric("Observed cost", value: summary.cost.formatted(.currency(code: "USD")))
                    metric("Total tokens", value: summary.totalTokens.formatted(.number.notation(.compactName)))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    tokenBreakdown(summary)
                    modelActivity(summary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    tokenBreakdown(summary)
                    modelActivity(summary)
                }
            }

            GroupBox("Account context") {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeAccountLabel(for: summary.activeAccountID))
                            .font(.body.weight(.medium))
                        Text("Active account reported by OpenCode’s local database")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("Last \(summary.days) days")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }

            Label(
                "OpenCode does not expose a stable local remaining-quota value. These are observed usage totals, not a quota estimate.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 46)
            .padding(.horizontal, 12)
            .padding(.top, 4)
    }

    private func tokenBreakdown(_ summary: UsageSummary) -> some View {
        GroupBox("Token breakdown") {
            VStack(spacing: 0) {
                tokenRow("Input", value: summary.inputTokens)
                Divider()
                tokenRow("Output", value: summary.outputTokens)
                Divider()
                tokenRow("Reasoning", value: summary.reasoningTokens)
                Divider()
                tokenRow("Cache read", value: summary.cacheReadTokens)
                Divider()
                tokenRow("Cache write", value: summary.cacheWriteTokens)
            }
            .padding(.top, 4)
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
    }

    private func modelActivity(_ summary: UsageSummary) -> some View {
        GroupBox("Requests by model") {
            if summary.models.isEmpty {
                ContentUnavailableView(
                    "No Model Activity",
                    systemImage: "cpu",
                    description: Text("No assistant requests were recorded in this period.")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                Chart(summary.models) { modelUsage in
                    BarMark(
                        x: .value("Requests", modelUsage.requests),
                        y: .value("Model", modelUsage.model)
                    )
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .trailing, alignment: .center) {
                        Text(modelUsage.requests.formatted())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom, values: .automatic(desiredCount: 4))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: max(190, CGFloat(summary.models.count) * 34))
                .padding(.top, 8)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
    }

    private func tokenRow(_ title: String, value: Int) -> some View {
        LabeledContent(title) {
            Text(value.formatted(.number.notation(.compactName)))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }

    private func activeAccountLabel(for id: String) -> String {
        if id == "anonymous" { return "No active Console account detected" }
        if let connection = model.consoleConnections.first(where: { $0.id == id }) { return connection.label }
        return "An OpenCode account is active"
    }
}
