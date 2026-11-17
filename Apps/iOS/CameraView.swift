import SwiftUI
import AVFoundation
import OSLog
import ShakeCore
import ShakeUI

struct CameraView: View {
    private static let metrics = Logger(subsystem: "cn.shake.lifelog", category: "Capture")
    @State private var reviewBeganAt: TimeInterval?

    @ObservedObject var store: ShakeStore
    let onManual: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var processing = false
    @StateObject private var camera = CameraController()
    @StateObject private var locationTracker = CaptureLocationTracker()
    @State private var showingCamera = false
    @State private var draft: RecordDraft?
    @State private var photo: Data?
    @State private var alternatives: [Classification] = []
    @State private var classifierMessage: String?
    private let classifier = ShakeClassifier()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.state == .ready {
                CameraPreview(session: camera.session, onFocus: camera.focus(at:), onPinch: camera.pinch(scale:began:))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            if camera.state == .requesting { Text("正在启动相机…").foregroundStyle(.white).font(.callout) }
            VStack {
                Spacer()
                if processing { Text("正在识别…").font(.caption).padding(10).background(.black.opacity(0.65)).foregroundStyle(.white).clipShape(Capsule()) }
                if camera.state == .denied || camera.state == .failed { permissionView }
                VStack(spacing: 12) {
                    if camera.state == .ready && !camera.zoomStops.isEmpty { zoomControl }
                    HStack(spacing: 0) {
                        Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                        Button { camera.capture() } label: {
                            Circle().strokeBorder(.white, lineWidth: 3).frame(width: 76, height: 76)
                                .overlay { Circle().fill(.white).padding(7) }
                        }.accessibilityLabel("快门")
                            .disabled(camera.state != .ready || draft != nil || processing || camera.isCapturing)
                        Button(action: onManual) {
                            Image(systemName: "keyboard").font(.title2)
                                .frame(width: 49, height: 49)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .foregroundStyle(.white).accessibilityLabel("手动记录")
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: 76)
                    .buttonStyle(.plain)
                }.padding(.bottom, 29)
            }
        }
        .onAppear {
            showingCamera = true
            camera.prepare()
            if scenePhase == .active && camera.state == .ready { locationTracker.start() }
        }
        .onChange(of: camera.state) { _, state in
            if state == .ready && scenePhase == .active && showingCamera { locationTracker.start() }
            else { locationTracker.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard showingCamera else { return }
            if phase == .active {
                camera.prepare()
                if camera.state == .ready { locationTracker.start() }
            } else {
                locationTracker.stop()
                camera.stop()
            }
        }
        .onDisappear { showingCamera = false; locationTracker.stop(); camera.stop() }
        .onChange(of: camera.capturedPhoto) { _, data in if let data { classify(data) } }
        .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil; photo = nil; camera.capturedPhoto = nil; alternatives = []; classifierMessage = nil; reviewBeganAt = nil } })) {
            if let draft {
                RecordEditorView(draft: draft, photo: photo, alternatives: alternatives,
                                 classificationMessage: classifierMessage, lastWeight: store.recentWeight()) { draft, photo in
                    let saveBeganAt = ProcessInfo.processInfo.systemUptime
                    try await store.save(draft, photo: photo)
                    recordCaptureTiming(saveBeganAt: saveBeganAt)
                }
                .onAppear { reviewBeganAt = ProcessInfo.processInfo.systemUptime }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast { Text(toast).padding(12).background(.white).foregroundStyle(.black).clipShape(Capsule()).padding(.bottom, 120) }
        }
        .alert("相机", isPresented: Binding(
            get: { camera.state == .ready && camera.error != nil },
            set: { if !$0 { camera.error = nil } }
        )) {
            Button("好") { camera.error = nil }
        } message: {
            Text(camera.error ?? "")
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 3) {
            ForEach(camera.zoomStops, id: \.self) { stop in
                let selected = abs(camera.zoom - stop) < 0.035
                Button { camera.setZoom(stop) } label: {
                    Text(zoomLabel(stop))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(selected ? Color.white : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("倍率 \(zoomLabel(stop))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if !camera.zoomStops.contains(where: { abs(camera.zoom - $0) < 0.035 }) {
                Text(zoomLabel(camera.zoom))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .accessibilityLabel("当前倍率 \(zoomLabel(camera.zoom))")
            }
        }.padding(3).background(.black.opacity(0.67), in: Capsule())
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(0...1))) + "×"
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(camera.state == .denied ? "相机权限未开启，也可以手动记录" : "相机暂不可用，也可以手动记录")
            if let reason = camera.error { Text(reason).font(.caption2).opacity(0.8).multilineTextAlignment(.center) }
            HStack(spacing: 12) {
                if camera.state == .denied {
                    Button("去设置开启") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                } else {
                    Button("重试") { camera.error = nil; camera.prepare() }
                        .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                }
            }
        }.foregroundStyle(.white).padding(24).background(.black.opacity(0.72)).clipShape(RoundedRectangle(cornerRadius: 18)).padding()
    }
    private func recordCaptureTiming(saveBeganAt: TimeInterval) {
        let completedAt = ProcessInfo.processInfo.systemUptime
        let total = (completedAt - camera.shutterUptime) * 1_000
        let confirmation = max(0, saveBeganAt - (reviewBeganAt ?? saveBeganAt)) * 1_000
        let processing = total - confirmation
        Self.metrics.info("capture_saved total_ms=\(total, privacy: .public) confirmation_ms=\(confirmation, privacy: .public) processing_ms=\(processing, privacy: .public)")
    }

    private func classify(_ data: Data) {
        let capturedAt = camera.shutterTime
        processing = true
        Task {
            async let location = locationTracker.location(at: capturedAt)
            defer { processing = false }
            let results: [Classification]
            do {
                results = try await classifier.classify(data)
            } catch {
                results = []
            }
            let decision = ClassificationPolicy.draft(from: results, at: capturedAt, lastWeight: store.recentWeight())
            var review = decision.draft
            review.payload.captureLocation = await location
            guard showingCamera else { camera.capturedPhoto = nil; return }
            photo = data
            alternatives = decision.alternatives
            classifierMessage = decision.modelUnavailable ? ClassifierError.invalidLabels.localizedDescription : nil
            draft = review
        }
    }
}
