import SwiftUI
import ShakeCore

struct CalendarView: View {
    @ObservedObject var store: ShakeStore
    let retryMedia: (() -> Void)?
    @State private var month = Date.now
    @State private var selectedDay: CalendarDay?
    private let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.locale = ShakeTheme.locale
        return calendar
    }()
    private var dayFormat: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().dateSeparator(.dash)
    }
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    private struct CalendarDay: Identifiable {
        let date: Date
        var id: Date { date }
    }

    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)?.start ?? month }
    private var leadingDays: Int { (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7 }
    private var days: Range<Int> { calendar.range(of: .day, in: .month, for: month) ?? 1..<1 }
    var body: some View {
        let recordsByDay = Dictionary(grouping: store.filteredRecords, by: \.captureDay)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(month.formatted(.dateTime.year().month(.wide).locale(ShakeTheme.locale))).font(.title2.bold())
                    Spacer()
                    Button("今天") { month = .now }
                    Button { moveMonth(-1) } label: { Label("上个月", systemImage: "chevron.left").labelStyle(.iconOnly) }
                    Button { moveMonth(1) } label: { Label("下个月", systemImage: "chevron.right").labelStyle(.iconOnly) }
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<7) { offset in
                        Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(0..<leadingDays, id: \.self) { _ in Color.clear.frame(height: 44) }
                    ForEach(days, id: \.self) { day in
                        if let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) {
                            dayButton(date, number: day, count: recordsByDay[date.formatted(dayFormat)]?.count ?? 0)
                        }
                    }
                }
            }.padding(18).modifier(ShakeCard()).padding(18)
        }
        .sheet(item: $selectedDay) { day in
            NavigationStack {
                Group {
                    if let records = recordsByDay[day.date.formatted(dayFormat)], !records.isEmpty {
                        List(records) { record in
                            NavigationLink {
                                RecordDetailView(store: store, record: record, retryMedia: retryMedia)
                            } label: {
                                RecordRow(store: store, record: record)
                            }
                        }
                    } else {
                        ContentUnavailableView(store.filter == nil ? "这天还没有记录" : "这天没有该类别的记录",
                                               systemImage: "calendar")
                    }
                }
                .navigationTitle(day.date.formatted(.dateTime.month(.wide).day().locale(ShakeTheme.locale)))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { selectedDay = nil } } }
            }.recordSheetSize()
        }
    }

    private func dayButton(_ date: Date, number: Int, count: Int) -> some View {
        Button {
            selectedDay = CalendarDay(date: date)
        } label: {
            VStack(spacing: 4) {
                Text(number.formatted()).font(.callout.weight(calendar.isDateInToday(date) ? .bold : .regular))
                HStack(spacing: 2) {
                    ForEach(0..<min(count, 3), id: \.self) { _ in
                        Circle().fill(ShakeTheme.accent).frame(width: 4, height: 4)
                    }
                }.frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(calendar.isDateInToday(date) ? ShakeTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(calendar.isDateInToday(date) ? "calendar.today" : "calendar.day")
        .accessibilityLabel("\(date.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(ShakeTheme.locale)))，\(count) 条记录")
    }

    private func moveMonth(_ offset: Int) {
        if let next = calendar.date(byAdding: .month, value: offset, to: monthStart) { month = next }
    }
}
