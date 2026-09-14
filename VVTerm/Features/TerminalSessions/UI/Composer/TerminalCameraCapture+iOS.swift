#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

struct TerminalCameraCapture: View {
    let complete: (Result<TerminalAttachmentPayload, Error>?) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var access = Access.checking
    private enum Access { case checking, ready, denied, unavailable }

    var body: some View {
        Group {
            switch access {
            case .checking: ProgressView()
            case .ready: TerminalCameraPicker(complete: complete).ignoresSafeArea()
            case .denied, .unavailable:
                VStack(spacing: 20) {
                    Text(access == .denied ? String(localized: "Allow camera access in Settings to take a photo.") : String(localized: "Camera is not available on this device."))
                        .multilineTextAlignment(.center)
                    if access == .denied {
                        Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    }
                    Button("Cancel") { complete(nil) }
                }.padding()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, access == .denied,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized { access = .ready }
        }
        .task {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { access = .unavailable; return }
            let granted: Bool
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                granted = await AVCaptureDevice.requestAccess(for: .video)
            } else { granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
            guard !Task.isCancelled else { return }
            access = granted ? .ready : .denied
        }
    }
}

struct TerminalCameraPicker: UIViewControllerRepresentable {
    let complete: (Result<TerminalAttachmentPayload, Error>?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let complete: (Result<TerminalAttachmentPayload, Error>?) -> Void
        init(complete: @escaping (Result<TerminalAttachmentPayload, Error>?) -> Void) { self.complete = complete }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { complete(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 1) else {
                complete(.failure(TerminalAttachmentError.unreadable)); return
            }
            complete(.success(TerminalAttachmentPayload(data: data, contentType: .jpeg,
                                                        suggestedFilename: "camera-\(UUID().uuidString).jpg")))
        }
    }
}
#endif
