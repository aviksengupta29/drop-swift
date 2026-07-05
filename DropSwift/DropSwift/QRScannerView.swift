//
//  QRScannerView.swift
//  DropSwift
//
//  Camera scanner used to pair with the computer by scanning the QR code
//  shown in the DropSwift Server app, instead of typing the access code.
//

import SwiftUI
import AVFoundation

/// Runs an AVCaptureSession that watches for QR codes and reports the first
/// one it finds. Stays paused after a hit until `resume()` is called (so a
/// failed pairing attempt can retry without re-presenting the camera).
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var awaitingResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureSession() } else { self?.onPermissionDenied?() }
                }
            }
        default:
            onPermissionDenied?()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        awaitingResult = true
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    /// Re-arms scanning after a failed pairing attempt.
    func resume() {
        awaitingResult = true
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard awaitingResult,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        awaitingResult = false
        onCode?(value)
    }

    func stop() { session.stopRunning() }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let controller: QRScannerController
    func makeUIViewController(context: Context) -> QRScannerController { controller }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

/// Full-screen sheet: points the camera at the QR code shown in the DropSwift
/// Server app and connects automatically once it reads a valid pairing code.
struct QRScanView: View {
    @EnvironmentObject var server: ServerConnection
    @Environment(\.dismiss) private var dismiss

    @State private var scanner = QRScannerController()
    @State private var connecting = false
    @State private var error: String?
    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
                permissionCard
            } else {
                QRScannerRepresentable(controller: scanner)
                    .ignoresSafeArea()
                    .onAppear {
                        scanner.onCode = handle
                        scanner.onPermissionDenied = { permissionDenied = true }
                    }

                VStack(spacing: 0) {
                    Spacer()
                    viewfinder
                    Spacer()
                    instructions
                        .padding(.bottom, Space.xxl)
                }

                if connecting {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView().tint(.white).controlSize(.large)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        Haptics.light()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }

    private var viewfinder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.white.opacity(0.9), lineWidth: 3)
            .frame(width: 240, height: 240)
            .shadow(color: .black.opacity(0.3), radius: 12)
    }

    private var instructions: some View {
        VStack(spacing: Space.s) {
            Text("Scan the QR code")
                .font(.headline).foregroundStyle(.white)
            Text(error ?? "Shown in the DropSwift Server app on your computer")
                .font(.subheadline)
                .foregroundStyle(error == nil ? .white.opacity(0.75) : Color(Theme.error))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
        }
    }

    private var permissionCard: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40)).foregroundStyle(.white.opacity(0.8))
            VStack(spacing: Space.xs) {
                Text("Camera access needed").font(.title3.weight(.bold)).foregroundStyle(.white)
                Text("Allow camera access in Settings to scan the QR code.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "Open Settings", icon: "gearshape.fill") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .frame(maxWidth: 260)
        }
        .padding(Space.xl)
    }

    private func handle(_ raw: String) {
        guard !connecting else { return }
        guard let payload = QRPairingPayload.parse(raw) else {
            error = "That's not a DropSwift pairing code. Try again."
            Haptics.warning()
            scanner.resume()
            return
        }
        connecting = true
        error = nil
        Task {
            await server.connectFromQR(payload)
            connecting = false
            if server.isConnected {
                Haptics.success()
                dismiss()
            } else {
                Haptics.warning()
                error = server.lastError ?? "Couldn't connect. Try again."
                scanner.resume()
            }
        }
    }
}
