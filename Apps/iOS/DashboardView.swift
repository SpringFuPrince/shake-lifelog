import SwiftUI
import Charts
import ShakeCore
import ShakeUI

struct DashboardView: View {
    @ObservedObject var store: ShakeStore
    let onTimeline: () -> Void
    let onManual: (ShakeCore.Category) -> Void
    let retryMedia: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var type
    @AppStorage("dashboard.activity") private var showsActivity = true
    @AppStorage("dashboard.weight") private var showsWeight = true
    @AppStorage("dashboard.recent") private var showsRecent = true

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    private var dayFormat: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().dateSeparator(.dash)
    }

    var body: some View {
        let now = Date.now
        let today = now.formatted(dayFormat)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    greeting
                    shortcuts
                    if showsActivity { activity(now: now) }
                    if showsRecent { recent(today: today) }
                    if showsWeight { weightTrend }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(ShakeTheme.paper.ignoresSafeArea())
            .navigationTitle("拾刻")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Toggle("记录足迹", isOn: $showsActivity)
                    Toggle("最近记录", isOn: $showsRecent)
                    Toggle("体重趋势", isOn: $showsWeight)
                } label: {
                    Label("自定义首页", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("你好，")
                .font(.title2.weight(.medium))
            Text("开始记录今天吧")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(ShakeTheme.accent)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷记录").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: type.isAccessibilitySize ? 2 : 5), spacing: 10) {
                ForEach(ShakeCore.Category.allCases) { category in
                    Button { onManual(category) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: category.systemImage).font(.body.weight(.medium))
                                .foregroundStyle(ShakeTheme.accent)
                                .accessibilityHidden(true)
                            Text(category.title).font(.caption.weight(.medium)).foregroundStyle(ShakeTheme.mutedInk)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                    }.buttonStyle(DashboardPressStyle())
                }
            }
        }
    }

    private func activity(now: Date) -> some View {
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear, value: -11, to: thisWeek) ?? today
        let dayLabels = ["一", "二", "三", "四", "五", "六", "日"]
        let counts = store.records.reduce(into: [String: Int]()) { $0[$1.captureDay, default: 0] += 1 }
        return VStack(alignment: .leading, spacing: 12) {
            Text("记录足迹").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Grid(alignment: .center, horizontalSpacing: 4, verticalSpacing: 6) {
                ForEach(0..<7) { row in
                    GridRow {
                        Text([0, 2, 4, 6].contains(row) ? dayLabels[row] : " ")
                            .font(.caption).foregroundStyle(ShakeTheme.mutedInk).accessibilityHidden(true)
                        ForEach(0..<12) { column in
                            if let date = calendar.date(byAdding: .day, value: column * 7 + row, to: start), date <= today {
                                let count = counts[date.formatted(dayFormat), default: 0]
                                Circle()
                                    .fill(count == 0 ? ShakeTheme.separator : ShakeTheme.accent.opacity(min(0.50 + Double(count) * 0.12, 1)))
                                    .overlay {
                                        if date == today { Circle().strokeBorder(ShakeTheme.accent, lineWidth: 1) }
                                    }
                                    .frame(width: date == today ? 12 : (count == 0 ? 6 : 12),
                                           height: date == today ? 12 : (count == 0 ? 6 : 12))
                                    .frame(maxWidth: .infinity, minHeight: 14)
                                    .accessibilityElement()
                                    .accessibilityLabel("\(date.formatted(.dateTime.month().day().locale(ShakeTheme.locale)))，\(count) 条记录")
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 14)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            HStack {
                Text(start.formatted(.dateTime.month(.wide).day().locale(ShakeTheme.locale)))
                Spacer()
                Text("今天")
            }.font(.caption).foregroundStyle(ShakeTheme.mutedInk)
        }.padding(.vertical, 2)
    }

    private var weightTrend: some View {
        let weightRecords = Array(store.records.filter { $0.category == .weight && $0.payload.weightInherited != true && $0.payload.weight != nil }.prefix(14)).reversed()
        return VStack(alignment: .leading, spacing: 14) {
            Text("体重趋势").font(.headline).accessibilityAddTraits(.isHeader)
            if weightRecords.isEmpty {
                Text("确认体重数值后显示趋势。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart(weightRecords) { record in
                    if let value = record.payload.weight {
                        LineMark(x: .value("日期", record.capturedAt), y: .value("kg", value))
                        PointMark(x: .value("日期", record.capturedAt), y: .value("kg", value))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .foregroundStyle(ShakeTheme.accent).frame(height: 130)
            }
        }
    }

    private func recent(today: String) -> some View {
        let records = store.records.prefix(3)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近记录").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("时间线", action: onTimeline).font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
            if records.isEmpty {
                Text("还没有记录").font(.subheadline).foregroundStyle(ShakeTheme.mutedInk)
            }
            ForEach(records) { record in
                recordLink(record, isToday: record.captureDay == today, isFirst: record.id == records.first?.id)
            }
        }
    }

    private func recordLink(_ record: LifeRecord, isToday: Bool, isFirst: Bool) -> some View {
        NavigationLink {
            RecordDetailView(store: store, record: record, retryMedia: retryMedia)
        } label: {
            HStack(spacing: 12) {
                if !type.isAccessibilitySize {
                    if let thumbnail = record.media?.thumbnail,
                       let data = try? store.media.data(thumbnail) {
                        RecordPhoto(data: data).frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 10)).accessibilityHidden(true)
                    } else {
                        Image(systemName: record.category.systemImage)
                            .foregroundStyle(ShakeTheme.accent)
                            .frame(width: 46, height: 46)
                            .background(ShakeTheme.card, in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.summary).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(record.category.title + "  " + recordDate(record, isToday: isToday))
                        .font(.caption).foregroundStyle(ShakeTheme.mutedInk)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: 50)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ShakeTheme.separator).frame(height: 1).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }.buttonStyle(DashboardPressStyle())
        .accessibilityIdentifier(isFirst ? "dashboard.latest" : "dashboard.recent")
    }

    private func recordDate(_ record: LifeRecord, isToday: Bool) -> String {
        if isToday {
            return record.capturedAt.formatted(ShakeTheme.clock(in: record.captureTimeZone))
        }
        let dateStyle = Date.FormatStyle(locale: ShakeTheme.locale, timeZone: record.captureTimeZone)
            .month(.wide).day()
        return record.capturedAt.formatted(dateStyle)
    }
}

private struct DashboardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
    }
}
