import SwiftUI

#if canImport(UIKit) && canImport(VisionKit)
import UIKit
import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScanComplete: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        guard VNDocumentCameraViewController.isSupported else {
            return UIHostingController(rootView: UnsupportedScannerView())
        }
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanComplete: onScanComplete, dismiss: dismiss)
    }

    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onScanComplete: (Int) -> Void
        let dismiss: DismissAction

        init(onScanComplete: @escaping (Int) -> Void, dismiss: DismissAction) {
            self.onScanComplete = onScanComplete
            self.dismiss = dismiss
        }

        @MainActor
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScanComplete(scan.pageCount)
        }

        @MainActor
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            dismiss()
        }

        @MainActor
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            dismiss()
        }
    }
}
#else
struct DocumentScannerView: View {
    var onScanComplete: (Int) -> Void

    var body: some View {
        UnsupportedScannerView()
    }
}
#endif

private struct UnsupportedScannerView: View {
    var body: some View {
        ContentUnavailableView("Scanner Unavailable", systemImage: "camera.viewfinder", description: Text("Receipt scanning requires a physical iPhone with document camera support."))
    }
}
