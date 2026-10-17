import SwiftUI
import AVFoundation

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> ScanController { ScanController(found: found) }
    func updateUIViewController(_ uiViewController: ScanController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScanController, coordinator: ()) { uiViewController.stop() }
}

final class ScanController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let work = DispatchQueue(label: "AndroidViewer.qr")
    private var layer: AVCaptureVideoPreviewLayer?
    private let found: (String) -> Void
    private var delivered = false
    private var closed = false
    init(found: @escaping (String) -> Void) { self.found = found; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            if allowed { self.work.async { [weak self] in self?.configure() } }
            else { DispatchQueue.main.async { [weak self] in self?.showError() } }
        }
    }
    private func configure() {
        guard !closed, let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.beginConfiguration(); session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            let preview = AVCaptureVideoPreviewLayer(session: self.session)
            preview.videoGravity = .resizeAspectFill; self.view.layer.addSublayer(preview); self.layer = preview
            preview.frame = self.view.bounds
        }
        session.startRunning()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); found(value)
    }
    func stop() { closed = true; work.async { [weak self] in self?.session.stopRunning() } }
    private func showError() {
        let label = UILabel(); label.text = "Allow Camera access in Settings to scan the pairing code from Mirador on Android."
        label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
        NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28)])
    }
}
