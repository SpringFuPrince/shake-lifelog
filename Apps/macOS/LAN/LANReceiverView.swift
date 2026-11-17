import CoreImage.CIFilterBuiltins
import ShakeCore
import ShakeUI
import SwiftUI

struct LANReceiverView: View {
    @ObservedObject var store: ShakeStore
    @StateObject private var receiver = LANReceiver()
    @State private var refreshError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("让 iPhone 和 Mac 连接同一 Wi-Fi。在 iPhone 的「我的 → 局域网同步」扫描二维码。")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    if let pairing = receiver.pairing {
                        if let image = Self.qrImage(for: pairing.code) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 224, height: 224)
                                .padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("拾刻局域网配对二维码")
                        }
                        Text(pairing.name).font(.headline)
                        if let expiresAt = receiver.expiresAt {
                            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(context.date))))
                                Text("二维码有效期剩余 " + String(format: "%d:%02d", remaining / 60, remaining % 60))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("停止接收") { receiver.stop() }
                    } else {
                        Label("等待开启接收", systemImage: "wifi").font(.headline)
                        Button(receiver.isStarting ? "正在开启…" : "开启接收") {
                            refreshError = nil
                            receiver.start(importer: LANImporter(repository: store.repository, media: store.media)) {
                                do { try store.refresh() }
                                catch { refreshError = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(receiver.isStarting)
                    }
                    if receiver.importedCount + receiver.skippedCount + receiver.rejectedCount > 0 {
                        Text("已导入 \(receiver.importedCount) 条，已存在 \(receiver.skippedCount) 条，失败 \(receiver.rejectedCount) 条")
                            .font(.subheadline)
                    }
                    if let message = receiver.message ?? refreshError {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .modifier(ShakeCard())
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(ShakeTheme.paper.ignoresSafeArea())
        .navigationTitle("局域网同步")
        .onDisappear { receiver.stop() }
    }

    private static func qrImage(for code: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
