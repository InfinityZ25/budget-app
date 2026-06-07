import SwiftUI

struct ReceiptScanResult: Hashable {
    var pageCount: Int
    var recognizedText: String
    var lineItems: [ReceiptLineItemDraft]
}

#if canImport(UIKit) && canImport(VisionKit)
import UIKit
import Vision
import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScanComplete: (ReceiptScanResult) -> Void
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
        let onScanComplete: (ReceiptScanResult) -> Void
        let dismiss: DismissAction

        init(onScanComplete: @escaping (ReceiptScanResult) -> Void, dismiss: DismissAction) {
            self.onScanComplete = onScanComplete
            self.dismiss = dismiss
        }

        @MainActor
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            Task {
                let result = await ReceiptOCR.recognize(images: images)
                onScanComplete(result)
                dismiss()
            }
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

private enum ReceiptOCR {
    static func recognize(images: [UIImage]) async -> ReceiptScanResult {
        let textBlocks = images.map { image in
            recognizeText(in: image)
        }
        let text = textBlocks.joined(separator: "\n")
        return ReceiptScanResult(pageCount: images.count, recognizedText: text, lineItems: parseLineItems(from: text))
    }

    private static func recognizeText(in image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation), options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            return ""
        }
    }

    private static func parseLineItems(from text: String) -> [ReceiptLineItemDraft] {
        Array(text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(parseLineItem)
            .prefix(40))
    }

    private static func parseLineItem(_ rawLine: String) -> ReceiptLineItemDraft? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > 4 else { return nil }
        let lowercased = line.lowercased()
        let excludedTokens = ["subtotal", "total", "tax", "visa", "mastercard", "amex", "debit", "credit", "change", "balance", "approval"]
        guard !excludedTokens.contains(where: lowercased.contains) else { return nil }
        guard let range = line.range(of: #"[-+]?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\s*$"#, options: .regularExpression) else {
            return nil
        }
        let amount = String(line[range])
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(line[..<range.lowerBound])
            .replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -\t"))
        guard !name.isEmpty else { return nil }
        return ReceiptLineItemDraft(name: name, quantity: "", amountText: amount, categoryName: suggestedCategory(for: name))
    }

    private static func suggestedCategory(for name: String) -> String {
        let text = name.lowercased()
        if text.contains("paper") || text.contains("soap") || text.contains("detergent") || text.contains("clean") {
            return "Household"
        }
        if text.contains("coffee") || text.contains("snack") || text.contains("chips") || text.contains("candy") {
            return "Snacks"
        }
        return "Groceries"
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#else
struct DocumentScannerView: View {
    var onScanComplete: (ReceiptScanResult) -> Void

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
