import SwiftUI
import Charts
import UsageCore

func tokenLabel(_ number: Int64) -> String {
    let value = Double(number)
    if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(number)
}

func profileDisplayName(_ command: String) -> String {
    if command == "claude" { return "default" }
    if command == "shared-history" { return "Shared history" }
    return command.hasPrefix("claude-") ? String(command.dropFirst(7)) : command
}

struct OverviewView: View {
    @ObservedObject var store: MonitorStore
    @State private var selectedDay: Date?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(store.analytics?.truncated == true ? "Partial local history" : "Local activity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.analytics?.truncated == true ? accent : muted)
                    Spacer()
                    if store.analyticsBusy { ProgressView().controlSize(.small) }
                    Picker("Period", selection: $store.analyticsDays) {
                        Text("7 days").tag(7); Text("30 days").tag(30)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 145)
                }
                if let data = store.analytics, store.analyticsRangeDays == store.analyticsDays || store.isDemo {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tokenLabel(data.totals.total)).font(.system(size: 36, weight: .semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                            .help(data.totals.total.formatted() + " tokens")
                        Text("processed tokens · includes cache reads and writes")
                            .font(.system(size: 13)).foregroundStyle(muted)
                        if data.hasSharedHistory {
                            Text("Shared conversation folders cannot be reliably split by account.").font(.system(size: 10)).foregroundStyle(accent)
                        }
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input + output").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                            Text(tokenLabel(TokenTotals(input: data.totals.input, output: data.totals.output).total)).font(.system(size: 24, weight: .medium, design: .rounded))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Subagent contribution").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                            Text(tokenLabel(data.subagentTokens.total)).font(.system(size: 18, weight: .medium, design: .rounded))
                        }
                    }
                    HStack(alignment: .top, spacing: 0) {
                        stat("Output", value: tokenLabel(data.totals.output))
                        stat("Sessions", value: "\(data.sessions.count)")
                        let context = Double(data.totals.input) + Double(data.totals.cacheRead) + Double(data.totals.cacheWrite)
                        stat("Cache reuse", value: context > 0 ? String(format: "%.0f%%", Double(data.totals.cacheRead) / context * 100) : "N/A")
                    }
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("Daily tokens").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            if let selectedDay, let point = data.daily.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }) {
                                Text("\(point.day.formatted(.dateTime.month(.abbreviated).day())) · \(tokenLabel(point.tokens))")
                                    .font(.system(size: 10)).foregroundStyle(accent)
                            }
                        }
                        Chart(data.daily) { day in
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", Double(day.tokens)))
                                .foregroundStyle(accent).cornerRadius(3)
                                .opacity(selectedDay == nil || Calendar.current.isDate(day.day, inSameDayAs: selectedDay!) ? 1 : 0.45)
                        }
                        .chartXSelection(value: $selectedDay)
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: store.analyticsDays == 7 ? 1 : 7)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(ink.opacity(0.07))
                            AxisValueLabel { if let v = value.as(Double.self) { Text(tokenLabel(Int64(min(v, Double(Int64.max - 1024))))).font(.system(size: 9)) } }
                        } }
                        .frame(height: 160)
                        .accessibilityLabel("Daily recorded tokens for the past \(store.analyticsDays) days")
                    }
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Tokens by profile").font(.system(size: 14, weight: .semibold))
                        ForEach(data.profiles.sorted { $0.tokens.total > $1.tokens.total }) { profile in
                            HStack(spacing: 12) {
                                Text(profileDisplayName(profile.command))
                                    .font(.system(size: 12, weight: .medium)).frame(width: 90, alignment: .leading).lineLimit(1)
                                GeometryReader { proxy in
                                    Capsule().fill(accent.opacity(0.17))
                                    Capsule().fill(accent).frame(width: proxy.size.width * (data.totals.total > 0 ? Double(profile.tokens.total) / Double(data.totals.total) : 0))
                                }.frame(height: 5)
                                Text(tokenLabel(profile.tokens.total)).font(.system(size: 11, design: .monospaced)).frame(width: 64, alignment: .trailing)
                                    .help("Input \(profile.tokens.input.formatted()) · Output \(profile.tokens.output.formatted()) · Cache read \(profile.tokens.cacheRead.formatted()) · Cache write \(profile.tokens.cacheWrite.formatted())")
                            }
                        }
                        if data.profiles.isEmpty { Text("No session logs found in this period. Start a Claude session to see activity here.").font(.caption).foregroundStyle(muted) }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Input \(tokenLabel(data.totals.input))")
                            Spacer()
                            Text("Cache read \(tokenLabel(data.totals.cacheRead))")
                            Spacer()
                            Text("Cache write \(tokenLabel(data.totals.cacheWrite))")
                        }.font(.system(size: 11)).monospacedDigit()
                        Text("Local recorded activity, including cache reuse. Not billing or subscription allowance.")
                            .font(.system(size: 11)).lineSpacing(3)
                        DisclosureGroup("How tokens are counted") {
                            Text("Includes main sessions and recognized subagent logs. Reused context counts again on each request. Duplicate messages are counted once. Isolated copied histories use oldest-copy attribution; shared folders remain unattributed.")
                                .font(.system(size: 11)).lineSpacing(3).padding(.top, 5)
                        }.font(.system(size: 11))
                        if !store.isDemo {
                            Text("Scanned \(data.scannedFiles.formatted()) / \(data.eligibleFiles.formatted()) files\(store.analyticsUpdatedAt.map { " · as of " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")\(store.analyticsBusy ? " · updating…" : "")")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if data.truncated {
                            Label("Partial history: some files were skipped or the bounded scan reached its limit.", systemImage: "exclamationmark.circle")
                                .font(.system(size: 10)).foregroundStyle(accent)
                        }
                    }.foregroundStyle(muted)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading local session activity…").font(.caption).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 90)
                }
            }.padding(24)
        }
    }
    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
