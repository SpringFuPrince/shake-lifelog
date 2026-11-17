import SwiftUI
import ShakeCore
import PhotosUI

public struct RecordEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: RecordDraft
    @State private var photo: Data?
    @State private var selection: PhotosPickerItem?
    @State private var weightInput: String
    @State private var durationInput: String
    let allowsPhotoSelection: Bool
    let alternatives: [Classification]
    let classificationMessage: String?
    let lastWeight: Double?
    let onSave: (RecordDraft, Data?) async throws -> Void
    @State private var isSaving = false
    @State private var saveError: String?

    public init(draft: RecordDraft, photo: Data? = nil, alternatives: [Classification] = [],
                classificationMessage: String? = nil,
                lastWeight: Double? = nil, allowsPhotoSelection: Bool = false,
                onSave: @escaping (RecordDraft, Data?) async throws -> Void) {
        _draft = State(initialValue: draft)
        _photo = State(initialValue: photo)
        _weightInput = State(initialValue: draft.payload.weightInherited == true ? "" : draft.payload.weight.map { String($0) } ?? "")
        _durationInput = State(initialValue: draft.payload.durationMinutes.map { String($0) } ?? "")
        self.alternatives = alternatives
        self.classificationMessage = classificationMessage
        self.lastWeight = lastWeight
        self.allowsPhotoSelection = allowsPhotoSelection
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let photo {
                        RecordPhoto(data: photo).frame(maxWidth: .infinity).frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    if allowsPhotoSelection {
                        HStack {
                            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                                Label(photo == nil ? "添加照片" : "更换照片", systemImage: "photo")
                            }
                            if photo != nil {
                                Spacer()
                                Button("移除照片") { photo = nil; selection = nil; draft.hasPhoto = false }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(draft.needsCategory ? "选择记录类别" : "类别")
                            .font(.headline)
                        if draft.needsCategory, let classificationMessage {
                            Text(classificationMessage).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !alternatives.isEmpty {
                            Text("推荐：" + alternatives.map { $0.category.title }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ShakeCore.Category.allCases) { category in
                                    Button {
                                        let changed = draft.category != category
                                        draft.select(category, lastWeight: lastWeight)
                                        if changed { weightInput = ""; durationInput = "" }
                                    } label: {
                                        Label(category.title, systemImage: category.systemImage)
                                            .padding(.horizontal, 13).padding(.vertical, 9)
                                            .background(!draft.needsCategory && draft.category == category ? category.color : Color.secondary.opacity(0.09))
                                            .foregroundStyle(!draft.needsCategory && draft.category == category ? .white : .primary)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("record.editor.category." + category.rawValue)
                                }
                            }
                        }
                    }
                    if !draft.needsCategory { fields.modifier(ShakeCard()) }
                    if let saveError { Text(saveError).foregroundStyle(.red).font(.footnote) }
                    if draft.source == .camera {
                        Text(draft.capturedAt.formatted(ShakeTheme.dateTime()))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            .background(ShakeTheme.paper.ignoresSafeArea())
            .navigationTitle(draft.source == .camera ? "确认记录" : "记录卡片")
            .task(id: selection) {
                guard let selection else { return }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw ShakeError.missingMedia }
                    try Task.checkCancellation()
                    photo = data
                    draft.hasPhoto = true
                } catch is CancellationError {
                } catch { saveError = error.localizedDescription }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(!draft.canSave || !validNumbers || isSaving)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch draft.category {
            case .food:
                Picker("餐次", selection: confirmed(\.meal)) {
                    ForEach(Meal.allCases) { Text($0.title).tag(Optional($0)) }
                }
                VStack(alignment: .leading) {
                    Text("食用情况").font(.subheadline)
                    Picker("食用情况", selection: Binding(get: { draft.payload.eatenPercent ?? 80 }, set: { draft.payload.eatenPercent = $0; draft.confirmOptions() })) {
                        ForEach([0, 25, 50, 80, 100], id: \.self) { Text("\($0)%").tag($0) }
                    }.pickerStyle(.segmented)
                }
                textField("备注（选填）", keyPath: \.note)
            case .weight:
                TextField("体重（kg）", text: $weightInput)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .font(.system(.largeTitle, design: .rounded))
                    .onChange(of: weightInput) { _, value in
                        draft.payload.weight = Double(value.replacingOccurrences(of: ",", with: "."))
                        draft.payload.weightInherited = false
                    }
                Slider(value: Binding(get: { draft.payloadForSave.weight ?? lastWeight ?? 60 },
                                      set: { weightInput = String(format: "%.1f", $0) }),
                       in: 20...300, step: 0.1)
                    .accessibilityLabel("体重，千克")
                if let lastWeight {
                    Button("沿用上次 " + lastWeight.formatted() + " kg") { weightInput = String(lastWeight) }
                }
                textField("备注（选填）", keyPath: \.note)
            case .mood:
                Picker("此刻心情", selection: confirmed(\.mood)) {
                    ForEach(Mood.allCases) { Text($0.title).tag(Optional($0)) }
                }
                textField("想说点什么？（选填）", keyPath: \.note)
            case .knowledge:
                textField("标题（选填）", keyPath: \.title)
                VStack(alignment: .leading) { Text("内容 / 摘录").font(.subheadline); textEditor(keyPath: \.content) }
                tagsField
            case .sport:
                textField("运动类型", keyPath: \.activity)
                TextField("时长（分钟，选填）", text: $durationInput)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onChange(of: durationInput) { _, value in
                        draft.payload.durationMinutes = Int(value)
                    }
                textField("备注（选填）", keyPath: \.note)
            case .daily:
                VStack(alignment: .leading) { Text("备注").font(.subheadline); textEditor(keyPath: \.note) }
                tagsField
            }
        }.padding(18)
    }

    private func textField(_ title: String, keyPath: WritableKeyPath<RecordPayload, String?>) -> some View {
        TextField(title, text: Binding(get: { draft.payload[keyPath: keyPath] ?? "" }, set: { draft.payload[keyPath: keyPath] = $0.isEmpty ? nil : $0 }))
    }
    private func textEditor(keyPath: WritableKeyPath<RecordPayload, String?>) -> some View {
        TextEditor(text: Binding(get: { draft.payload[keyPath: keyPath] ?? "" }, set: { draft.payload[keyPath: keyPath] = $0.isEmpty ? nil : $0 }))
            .frame(minHeight: 100).scrollContentBackground(.hidden).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func confirmed<Value>(_ keyPath: WritableKeyPath<RecordPayload, Value>) -> Binding<Value> {
        Binding(get: { draft.payload[keyPath: keyPath] }, set: { value in
            draft.payload[keyPath: keyPath] = value
            draft.confirmOptions()
        })
    }

    private var validNumbers: Bool {
        (weightInput.isEmpty || draft.payload.weight != nil) &&
        (durationInput.isEmpty || draft.payload.durationMinutes != nil)
    }

    private var tagsField: some View {
        TextField("标签，用逗号分隔", text: Binding(
            get: { draft.payload.tags?.joined(separator: ", ") ?? "" },
            set: { draft.payload.tags = $0.split(separator: ",").map(String.init) }
        ))
    }

    private func save() {
        draft.payload.tags = draft.payload.tags?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        isSaving = true
        Task {
            do { try await onSave(draft, photo); dismiss() }
            catch { saveError = error.localizedDescription }
            isSaving = false
        }
    }
}
