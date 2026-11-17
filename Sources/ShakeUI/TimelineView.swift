import SwiftUI
import ShakeCore
import CoreLocation
import MapKit

public struct TimelineView: View {
    @ObservedObject var store: ShakeStore
    let retryMedia: (() -> Void)?
    @State private var showManual = false
    @State private var showDeleted = false
    @State private var showCalendar = false
    @AppStorage("timeline.zoom") private var savedZoom = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom = 0.0
    @State private var days: [DayGroup] = []
    @State private var galleryRows: [GalleryRow] = []
    @State private var frameCache = FrameCache()
    #if os(iOS)
    @State private var zoomEnabled = false
    #endif
    @State private var zoomSession: ZoomSession?
    @State private var finishTask: Task<Void, Never>?

    private static let galleryThreshold = 0.28
    private static let maximumZoom = galleryThreshold + 4
    private var inGallery: Bool { zoom >= Self.galleryThreshold }
    private var galleryColumns: Double { 2 + max(0, zoom - Self.galleryThreshold) }

    private struct DayGroup: Identifiable {
        let id: String
        let records: [LifeRecord]
    }

    private enum GalleryRow: Identifiable {
        case header(String)
        case photos(day: String, offset: Int, records: [LifeRecord])

        var id: String {
            switch self {
            case .header(let day): "header-\(day)"
            case .photos(let day, let offset, _): "photos-\(day)-\(offset)"
            }
        }
    }

    private final class FrameCache {
        var frames: [String: CGRect] = [:]
    }

    private final class ZoomSession {
        let id = UUID()
        let recordID: String?
        let targetY: CGFloat
        let fraction: CGFloat
        let scrollBy: (CGFloat) -> Bool
        private var correction: DispatchWorkItem?
        private var pendingDelta: CGFloat = 0

        init(recordID: String?, targetY: CGFloat, fraction: CGFloat, scrollBy: @escaping (CGFloat) -> Bool) {
            self.recordID = recordID
            self.targetY = targetY
            self.fraction = fraction
            self.scrollBy = scrollBy
        }

        func follow(_ frame: CGRect) {
            pendingDelta = frame.minY + frame.height * fraction - targetY
            guard correction == nil, pendingDelta.isFinite, abs(pendingDelta) > 0.75 else { return }
            // SwiftUI reports frames during layout. Move the native scroll view only
            // after that pass, and coalesce reports from the same screen frame.
            let operation = DispatchWorkItem { [weak self] in
                guard let self else { return }
                correction = nil
                if pendingDelta.isFinite, abs(pendingDelta) > 0.75 { _ = scrollBy(pendingDelta) }
            }
            correction = operation
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: operation)
        }

        func cancel() { correction?.cancel(); correction = nil }
    }

    private struct PhotoFrames: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    public init(store: ShakeStore, retryMedia: (() -> Void)? = nil) {
        self.store = store
        self.retryMedia = retryMedia
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                if showCalendar { CalendarView(store: store, retryMedia: retryMedia) }
                else { timeline }
            }
            .background(ShakeTheme.paper.ignoresSafeArea())
            .onChange(of: store.records, initial: true) { _, _ in loadDays() }
            .onChange(of: store.filter) { _, _ in loadDays() }
            .navigationTitle(showCalendar ? "日历" : "时间线")
            .toolbar {
                ToolbarItem(placement: .automatic) { Button { showDeleted = true } label: { Label("最近删除", systemImage: "clock.arrow.circlepath") } }
                ToolbarItem { Button { showCalendar.toggle() } label: {
                    Label(showCalendar ? "时间线" : "日历", systemImage: showCalendar ? "list.bullet" : "calendar")
                } }
                if !showCalendar {
                    ToolbarItem(placement: .primaryAction) { Button { showManual = true } label: { Label("手动记录", systemImage: "plus") } }
                }
            }
            .sheet(isPresented: $showManual) {
                RecordEditorView(draft: RecordDraft(lastWeight: store.recentWeight(), needsCategory: true),
                                 lastWeight: store.recentWeight(), allowsPhotoSelection: true) { draft, photo in
                    try await store.save(draft, photo: photo)
                }.recordSheetSize()
            }
            .sheet(isPresented: $showDeleted) { RecentlyDeletedView(store: store) }
            .overlay(alignment: .bottom) { toast }
            .alert("提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("好") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                filterButton(nil, title: "全部", icon: "square.grid.2x2")
                ForEach(ShakeCore.Category.allCases) { filterButton($0, title: $0.title, icon: $0.systemImage) }
            }.padding(.horizontal, 18).padding(.vertical, 10)
        }
    }
    private func filterButton(_ category: ShakeCore.Category?, title: String, icon: String) -> some View {
        let selected = store.filter == category
        return Button { store.filter = category } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 13).frame(minHeight: 44)
                .foregroundStyle(selected ? ShakeTheme.onAccent : Color.primary)
                .background(selected ? ShakeTheme.accent : ShakeTheme.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("record.filter." + (category?.rawValue ?? "all"))
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ZStack {
                if days.isEmpty {
                    emptyState
                } else if inGallery {
                    if galleryRows.isEmpty {
                        ContentUnavailableView("没有照片记录", systemImage: "photo.on.rectangle",
                                               description: Text("放大可查看文字记录。"))
                    } else {
                        photoGrid
                    }
                } else {
                    #if os(iOS)
                    recordList.scaleEffect(1 - zoom * 0.18, anchor: .top)
                    #else
                    recordList
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .coordinateSpace(name: "shakeTimelineScroll")
            .background {
                #if os(macOS)
                TimelineMagnifier { handleZoom($0, proxy: proxy) }
                #else
                TimelineMagnifier(isActive: zoomEnabled) { handleZoom($0, proxy: proxy) }
                #endif
            }
            .onAppear {
                zoom = min(Self.maximumZoom, max(0, savedZoom))
                #if os(iOS)
                zoomEnabled = true
                #endif
            }
            .onDisappear {
                #if os(iOS)
                zoomEnabled = false
                #endif
                finishTask?.cancel()
                zoomSession?.cancel()
                zoomSession = nil
            }
            .onPreferenceChange(PhotoFrames.self) { frames in
                frameCache.frames = frames
                if let session = zoomSession,
                   let id = session.recordID, let frame = frames[id] {
                    session.follow(frame)
                }
            }
            .accessibilityAction(named: Text("放大照片")) { scaleBy(-1, proxy: proxy); settleZoom() }
            .accessibilityAction(named: Text("缩小照片")) { scaleBy(1, proxy: proxy); settleZoom() }
        }
    }

    private func loadDays() {
        let groups = Dictionary(grouping: store.filteredRecords, by: \.captureDay)
            .sorted { $0.key > $1.key }
            .map { DayGroup(id: $0.key, records: $0.value) }
        days = groups
        galleryRows = groups.flatMap { group -> [GalleryRow] in
            let photos = group.records.filter { $0.media != nil }
            guard !photos.isEmpty else { return [] }
            // A multiple of 2, 3, 4, 5 and 6 keeps row boundaries aligned between lazy chunks.
            let chunks = stride(from: 0, to: photos.count, by: 60).map { offset in
                GalleryRow.photos(day: group.id, offset: offset,
                                  records: Array(photos[offset..<min(photos.count, offset + 60)]))
            }
            return [.header(group.id)] + chunks
        }
    }

    private func handleZoom(_ event: TimelineZoomEvent, proxy: ScrollViewProxy) {
        switch event {
        case let .began(point, scrollBy):
            finishTask?.cancel()
            zoomSession?.cancel()
            let closest = frameCache.frames.min { first, second in
                distance(first.value, from: point) < distance(second.value, from: point)
            }
            let fraction = closest.map { max(0, min(1, (point.y - $0.value.minY) / max(1, $0.value.height))) } ?? 0.5
            zoomSession = ZoomSession(recordID: closest?.key, targetY: point.y, fraction: fraction, scrollBy: scrollBy)
        case .delta(let delta):
            scaleBy(delta, proxy: proxy)
        case .ended:
            settleZoom()
        }
    }

    private func distance(_ frame: CGRect, from point: CGPoint) -> CGFloat {
        let dx = max(0, max(frame.minX - point.x, point.x - frame.maxX))
        let dy = max(0, max(frame.minY - point.y, point.y - frame.maxY))
        return dx * dx + dy * dy
    }

    private func scaleBy(_ delta: Double, proxy: ScrollViewProxy) {
        let next = min(Self.maximumZoom, max(0, zoom + delta))
        guard next != zoom else { return }
        let switchesView = inGallery != (next >= Self.galleryThreshold)
        withAnimation(switchesView && !reduceMotion ? .easeOut(duration: 0.18) : nil) { zoom = next }
        if switchesView, let id = zoomSession?.recordID {
            // Keep the nearby record mounted while the list and gallery exchange places.
            DispatchQueue.main.async {
                if zoomSession?.recordID == id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        if zoomSession == nil { savedZoom = next }
    }

    private func settleZoom() {
        let restingZoom = inGallery ? galleryColumns.rounded() - 2 + Self.galleryThreshold : 0
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { zoom = restingZoom }
        savedZoom = restingZoom
        let sessionID = zoomSession?.id
        finishTask?.cancel()
        finishTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled && zoomSession?.id == sessionID {
                zoomSession?.cancel()
                zoomSession = nil
            }
        }
    }

    private func markPhoto(_ id: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PhotoFrames.self,
                value: [id: geometry.frame(in: .named("shakeTimelineScroll"))])
        }
    }

    private func dayHeader(_ day: String) -> some View {
        Text(dayTitle(day))
            .font(.headline)
            .foregroundStyle(ShakeTheme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var recordList: some View {
        List {
            ForEach(days) { day in
                Section(header: dayHeader(day.id)) {
                    ForEach(day.records) { record in
                        NavigationLink { RecordDetailView(store: store, record: record, retryMedia: retryMedia) } label: { RecordRow(store: store, record: record) }
                            .background { if record.media != nil { markPhoto(record.id) } }
                            .id(record.id)
                            .accessibilityIdentifier("timeline.record.\(record.id)")
                            .listRowBackground(ShakeTheme.paper)
                            .swipeActions { Button("删除", role: .destructive) { store.report { try store.delete(record) } } }
                    }
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .accessibilityIdentifier("timeline.recordList")
    }

    private var photoGrid: some View {
        GeometryReader { viewport in
            let gridWidth = max(1, viewport.size.width - 32)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(galleryRows) { row in
                        switch row {
                        case .header(let day):
                            dayHeader(day)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .photos(_, _, let records):
                            TimelinePhotoLayout(columns: galleryColumns) {
                                ForEach(records) { record in
                                    NavigationLink {
                                        RecordDetailView(store: store, record: record, retryMedia: retryMedia)
                                    } label: {
                                        TimelineThumbnail(url: record.media.map { store.media.url(for: $0.thumbnail) })
                                    }
                                    .buttonStyle(.plain)
                                    .background { markPhoto(record.id) }
                                    .id(record.id)
                                    .zIndex(zoomSession?.recordID == record.id ? 1 : 0)
                                    .accessibilityLabel("\(record.category.title)，\(record.summary)，\(record.capturedAt.formatted(ShakeTheme.clock(in: record.captureTimeZone)))")
                                    .accessibilityIdentifier("timeline.photo.\(record.id)")
                                }
                            }
                            .frame(width: gridWidth)
                            .padding(.bottom, TimelinePhotoLayout.gap)
                        }
                    }
                }
                .frame(width: gridWidth)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .accessibilityIdentifier("timeline.photoGrid")
        }
    }

    private func dayTitle(_ day: String) -> String {
        let dateOnly = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
        guard let date = try? dateOnly.parse(day) else { return day }
        let title = Date.FormatStyle(locale: ShakeTheme.locale, timeZone: .gmt).year().month(.wide).day().weekday(.wide)
        return date.formatted(title)
    }
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(); Image(systemName: "camera.aperture").font(.system(size: 44, weight: .light)).foregroundStyle(ShakeTheme.accent)
            Text(store.filter == nil ? "从眼前这一刻开始" : "这个类别还没有记录").font(.title2).fontWeight(.semibold)
            Text("拍一下，或点右上角手动记录。\n内容会先保存在本机。").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("手动记录") { showManual = true }.buttonStyle(.borderedProminent).tint(ShakeTheme.accent)
            Spacer()
        }.padding()
    }
    @ViewBuilder private var toast: some View {
        if let toast = store.toast {
            Text(toast).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 11)
                .background(ShakeTheme.accent).foregroundStyle(ShakeTheme.onAccent).clipShape(Capsule()).shadow(radius: 10).padding(.bottom, 20)
                
        }
    }
}

private struct TimelineThumbnail: View {
    let url: URL?
    @State private var data: Data?
    var body: some View {
        ShakeTheme.card.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let data {
                    RecordPhoto(data: data)
                } else {
                    Image(systemName: "photo").foregroundStyle(ShakeTheme.mutedInk)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { data = nil; return }
                let imageData = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                if !Task.isCancelled { data = imageData }
            }
    }
}

struct RecordRow: View {
    let store: ShakeStore
    let record: LifeRecord
    var body: some View {
        HStack(spacing: 13) {
            if let thumbnail = record.media?.thumbnail {
                RecordPhoto(data: try? store.media.data(thumbnail)).frame(width: 66, height: 66).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ZStack { record.category.color.opacity(0.12); Image(systemName: record.category.systemImage).font(.title2).foregroundStyle(record.category.color) }
                    .frame(width: 66, height: 66).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.category.title).font(.caption).fontWeight(.semibold).foregroundStyle(record.category.color)
                    Spacer()
                    Text(record.capturedAt.formatted(ShakeTheme.clock(in: record.captureTimeZone)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(record.summary).font(.body).fontWeight(.medium).lineLimit(1)
                if let text = record.payload.note ?? record.payload.content, !text.isEmpty { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.padding(.vertical, 6)
    }
}

public struct RecordDetailView: View {
    @ObservedObject var store: ShakeStore
    let initialRecord: LifeRecord
    let retryMedia: (() -> Void)?
    private var record: LifeRecord { store.records.first { $0.id == initialRecord.id } ?? initialRecord }
    public init(store: ShakeStore, record: LifeRecord, retryMedia: (() -> Void)?) {
        self.retryMedia = retryMedia
        self.store = store
        initialRecord = record
    }
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let media = record.media {
                    if let data = try? store.media.data(media.original) {
                        RecordPhoto(data: data, contentMode: .fit).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityLabel("记录照片")
                            .accessibilityIdentifier("record.detail.photo")
                    } else {
                        VStack(spacing: 10) {
                            Label("照片尚未下载", systemImage: "photo")
                            if let retryMedia { Button("重试同步", action: retryMedia) }
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .modifier(ShakeCard())
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label(record.category.title, systemImage: record.category.systemImage).foregroundStyle(record.category.color).fontWeight(.semibold)
                    RecordDetailFields(record: record)
                    Divider()
                    Label(record.capturedAt.formatted(ShakeTheme.dateTime(in: record.captureTimeZone)), systemImage: "clock")
                    if let location = record.payload.captureLocation {
                        RecordPlaceLabel(location: location)
                    } else if record.media != nil || record.source == .camera {
                        Label("未记录拍摄地点", systemImage: "location.slash").foregroundStyle(.secondary)
                    }
                }.padding(20).modifier(ShakeCard())
            }.padding(20)
        }.background(ShakeTheme.paper).navigationTitle("记录详情")
        .toolbar {
            ToolbarItem { Button("编辑") { editing = true } }
            ToolbarItem { Button("删除", role: .destructive) { confirmDelete = true } }
        }
        .confirmationDialog("删除后会移入最近删除，保留 30 天", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除记录", role: .destructive) { store.report { try store.delete(record) }; dismiss() }
        }
        .sheet(isPresented: $editing) {
            let current = (try? store.repository.get(record.id)) ?? record
            RecordEditorView(draft: RecordDraft(record: current),
                             photo: current.media.flatMap { try? store.media.data($0.original) },
                             lastWeight: store.recentWeight()) { draft, _ in
                try store.update(current.id, draft: draft)
            }.recordSheetSize()
        }
    }
}

private struct RecordPlaceLabel: View {
    let location: CaptureLocation
    @State private var address: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(address ?? coordinates)
                if let accuracy = location.horizontalAccuracy, accuracy >= 100 {
                    Text("定位精度约 \(accuracy.formatted(.number.precision(.fractionLength(0)))) 米")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "location")
        }
        .accessibilityIdentifier("record.detail.location")
        .task(id: location) {
            address = nil
            let coordinate = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let result = await Self.address(for: coordinate)
            if !Task.isCancelled { address = result }
        }
    }

    private var coordinates: String {
        let format = FloatingPointFormatStyle<Double>.number.locale(ShakeTheme.locale).precision(.fractionLength(4))
        return "\(location.latitude.formatted(format)), \(location.longitude.formatted(format))"
    }

    private static func address(for location: CLLocation) async -> String? {
        if #available(iOS 26, macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = ShakeTheme.locale
            return try? await request.mapItems.first?.address?.fullAddress
        } else {
            guard let place = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: ShakeTheme.locale).first else { return nil }
            var parts: [String] = []
            for part in [place.administrativeArea, place.locality, place.subLocality, place.thoroughfare, place.subThoroughfare].compactMap({ $0 })
                where !part.isEmpty && !parts.contains(part) {
                parts.append(part)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}

private struct RecordDetailFields: View {
    let record: LifeRecord

    var body: some View {
        let payload = record.payload
        switch record.category {
        case .food:
            if let meal = payload.meal { LabeledContent("餐次", value: meal.title) }
            if let percent = payload.eatenPercent { LabeledContent("食用情况", value: "\(percent)%") }
        case .weight:
            if let weight = payload.weight {
                LabeledContent("体重", value: weight.formatted() + " kg")
                if payload.weightInherited == true {
                    Text("沿用的参考值 · 待确认").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("未记录体重").foregroundStyle(.secondary)
            }
        case .mood:
            if let mood = payload.mood { LabeledContent("此刻心情", value: mood.title) }
            if let intensity = payload.intensity { LabeledContent("强度", value: "\(intensity)/5") }
        case .sport:
            if let activity = payload.activity, !activity.isEmpty {
                LabeledContent("运动类型", value: activity)
                    .accessibilityIdentifier("record.detail.activity")
            }
            if let duration = payload.durationMinutes {
                LabeledContent("时长", value: "\(duration) 分钟")
                    .accessibilityIdentifier("record.detail.duration")
            }
        case .knowledge, .daily:
            EmptyView()
        }

        if let title = payload.title, !title.isEmpty { Text(title).font(.title2.weight(.semibold)) }
        if let content = payload.content, !content.isEmpty { Text(content) }
        if let activity = payload.activity, !activity.isEmpty, record.category != .sport {
            LabeledContent("运动类型", value: activity)
        }
        if let note = payload.note, !note.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("备注").font(.caption).foregroundStyle(.secondary)
                Text(note)
            }
        }
        if let tags = payload.tags, !tags.isEmpty {
            Text(tags.map { "#\($0)" }.joined(separator: "  ")).foregroundStyle(.secondary)
        }
    }
}

public struct RecentlyDeletedView: View {
    @ObservedObject var store: ShakeStore
    @Environment(\.dismiss) private var dismiss
    public init(store: ShakeStore) { self.store = store }
    public var body: some View {
        NavigationStack {
            Group {
                if store.deletedRecords.isEmpty { ContentUnavailableView("最近删除为空", systemImage: "trash", description: Text("删除的记录会在这里保留 30 天")) }
                else {
                    List(store.deletedRecords) { record in
                        HStack {
                            Image(systemName: record.category.systemImage).foregroundStyle(record.category.color)
                            VStack(alignment: .leading) {
                                Text(record.summary)
                                if let deletedAt = record.deletedAt {
                                    Text("删除于 \(deletedAt.formatted(ShakeTheme.dateTime()))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("恢复") { store.report { try store.restore(record) } }
                        }.listRowBackground(ShakeTheme.paper)
                    }
                    .scrollContentBackground(.hidden)
                }
            }.background(ShakeTheme.paper.ignoresSafeArea())
                .navigationTitle("最近删除").toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .recordSheetSize()
        .onAppear { store.purgeExpired() }
    }
}

extension View {
    @ViewBuilder func recordSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 420, minHeight: 540)
        #else
        self
        #endif
    }
}
