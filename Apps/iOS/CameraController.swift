import AVFoundation
import SwiftUI

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum State { case requesting, ready, denied, failed }
    @Published var state: State = .requesting
    @Published var capturedPhoto: Data?
    private(set) var shutterTime = Date.now
    private(set) var shutterUptime: TimeInterval = 0
    @Published var error: String?
    @Published private(set) var isCapturing = false
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var zoomStops: [CGFloat] = []
    private var zoomRange: ClosedRange<CGFloat> = 1...1
    private var pinchStartZoom: CGFloat = 1
    private var visible = false

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    /// 所有 session 操作都在这条串行队列上，避免 start/stop 相互竞争。
    private let sessionQueue = DispatchQueue(label: "cn.shake.camera.session")
    private var isConfigured = false
    private var wantsRunning = false
    private var device: AVCaptureDevice?
    private var zoomMultiplier: CGFloat = 1

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaChanged(_:)),
                                               name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// 幂等入口：可被 onAppear 反复调用。
    func prepare() {
        visible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.visible else { return }
                    if granted { self.start() } else { self.state = .denied }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed
        }
    }

    private func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.performStart()
        }
    }

    private func performStart() {
        guard wantsRunning else { return }
        if !isConfigured {
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
            ]
            guard let device = deviceTypes.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first
                ?? AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async { self.state = .failed; self.error = "这台设备没有可用的摄像头" }
                return
            }
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.state = .failed; self.error = "无法创建摄像头输入，请检查相机权限" }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.state = .failed; self.error = "相机被占用或不支持（无法添加输入/输出）" }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            self.device = device
            configureZoom(for: device)
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            isConfigured = true
        }

        if !session.isRunning { session.startRunning() }
        let running = session.isRunning
        DispatchQueue.main.async {
            guard self.visible else { return }
            self.state = running ? .ready : .failed
            self.error = running ? nil : "相机未能启动，请重试"
        }
    }

    private func configureZoom(for device: AVCaptureDevice) {
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        if #available(iOS 18, *) {
            zoomMultiplier = device.displayVideoZoomFactorMultiplier
        } else if let wideIndex = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
                  wideIndex > 0, switches.indices.contains(wideIndex - 1) {
            zoomMultiplier = 1 / switches[wideIndex - 1]
        }
        let lower = device.minAvailableVideoZoomFactor * zoomMultiplier
        let upper = max(lower, min(device.maxAvailableVideoZoomFactor * zoomMultiplier, 10))
        let range = lower...upper
        let start = min(max(1, lower), upper)
        var stops = ([device.minAvailableVideoZoomFactor] + switches).map { $0 * zoomMultiplier }
        // 2× is a useful crop between the main and telephoto lens when both exist.
        if let teleIndex = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInTelephotoCamera }),
           teleIndex > 0, switches.indices.contains(teleIndex - 1), switches[teleIndex - 1] * zoomMultiplier > 2.2 {
            stops.append(2)
        }
        if switches.isEmpty && range.contains(2) { stops.append(2) }
        let available = Set(([start] + stops.filter { range.contains($0) })).sorted()
        applyZoom(start, on: device)
        DispatchQueue.main.async {
            self.zoomRange = range
            self.zoomStops = available
            self.zoom = start
        }
    }

    func setZoom(_ target: CGFloat) {
        let value = min(max(target, zoomRange.lowerBound), zoomRange.upperBound)
        guard value != zoom else { return }
        zoom = value
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyZoom(value, on: device)
        }
    }

    private func applyZoom(_ value: CGFloat, on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = min(max(value / zoomMultiplier, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    func pinch(scale: CGFloat, began: Bool) {
        if began { pinchStartZoom = zoom }
        setZoom(pinchStartZoom * scale)
    }

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in self?.applyFocus(at: point, continuous: false) }
    }

    private func applyFocus(at point: CGPoint, continuous: Bool) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let focusMode: AVCaptureDevice.FocusMode = continuous ? .continuousAutoFocus : .autoFocus
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = point
            device.focusMode = focusMode
        }
        let exposureMode: AVCaptureDevice.ExposureMode = continuous ? .continuousAutoExposure : .autoExpose
        if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
            device.exposurePointOfInterest = point
            device.exposureMode = exposureMode
        }
        device.isSubjectAreaChangeMonitoringEnabled = !continuous
    }

    @objc private func subjectAreaChanged(_ note: Notification) {
        guard let changed = note.object as? AVCaptureDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.device === changed else { return }
            self.applyFocus(at: CGPoint(x: 0.5, y: 0.5), continuous: true)
        }
    }

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        shutterTime = .now
        shutterUptime = ProcessInfo.processInfo.systemUptime
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.wantsRunning, self.session.isRunning else {
                DispatchQueue.main.async { self.isCapturing = false; self.error = "相机尚未就绪" }
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .balanced
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async {
            self.isCapturing = false
            guard self.visible else { return }
            if let data {
                self.capturedPhoto = data
            } else {
                self.error = error?.localizedDescription ?? "无法读取拍摄的照片"
            }
        }
    }

    func stop() {
        visible = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - 系统通知

    @objc private func sessionRuntimeError(_ note: Notification) {
        let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "未知错误"
        DispatchQueue.main.async {
            self.state = .failed
            self.error = "相机运行错误：\(message)"
        }
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        let message: String
        switch raw {
        case 1: message = "相机被系统中断（有更高优先级的来电/请求）"
        case 2: message = "相机被系统中断（应用进入后台）"
        case 3: message = "相机被系统中断（系统设置变更）"
        case 4: message = "相机被其他前台应用占用，请关闭其他正在用摄像头的 App（如微信视频/扫码）后点重试"
        case 5: message = "相机被系统中断（资源压力）"
        default: message = "相机被系统中断（原因码 \(raw)）"
        }
        DispatchQueue.main.async { self.error = message }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        sessionQueue.async { [weak self] in self?.performStart() }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void
    let onPinch: (CGFloat, Bool) -> Void
    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onFocus = onFocus
        uiView.onPinch = onPinch
    }
}

final class PreviewView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onFocus: ((CGPoint) -> Void)?
    var onPinch: ((CGFloat, Bool) -> Void)?
    private let focusRing = CAShapeLayer()
    private var hideFocus: DispatchWorkItem?

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        layer.addSublayer(previewLayer)
        focusRing.fillColor = UIColor.clear.cgColor
        focusRing.strokeColor = UIColor(red: 0.58, green: 0.97, blue: 0.84, alpha: 1).cgColor
        focusRing.lineWidth = 2
        focusRing.shadowColor = UIColor.black.cgColor
        focusRing.shadowOpacity = 0.7
        focusRing.shadowRadius = 2
        focusRing.isHidden = true
        layer.addSublayer(focusRing)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        hideFocus?.cancel()
        focusRing.path = UIBezierPath(roundedRect: CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                                     cornerRadius: 6).cgPath
        focusRing.isHidden = false
        let hide = DispatchWorkItem { [weak self] in self?.focusRing.isHidden = true }
        hideFocus = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: hide)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed {
            onPinch?(recognizer.scale, recognizer.state == .began)
        }
    }
}
