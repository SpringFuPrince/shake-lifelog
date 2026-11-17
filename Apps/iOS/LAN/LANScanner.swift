import AVFoundation
import SwiftUI

struct LANScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.stop()
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cn.shake.lan.scanner")
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private var finished = false

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = PreviewView(session: session) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.viewIfLoaded?.window != nil else { return }
                    if allowed { self.start() } else { self.reportPermission() }
                }
            }
        default: reportPermission()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty {
                let output = AVCaptureMetadataOutput()
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.onError("相机不可用。") }
                    return
                }
                self.session.beginConfiguration()
                self.session.addInput(input)
                guard self.session.canAddOutput(output) else {
                    self.session.removeInput(input)
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.onError("无法开启二维码扫描。") }
                    return
                }
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
                self.session.commitConfiguration()
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func reportPermission() { onError("请在系统设置中允许拾刻使用相机，然后重试。") }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !finished, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        finished = true
        stop()
        onCode(code)
    }
}
