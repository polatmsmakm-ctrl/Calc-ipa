import SwiftUI
import QuickLook
import Photos
import VisionKit
import PDFKit
import UniformTypeIdentifiers

struct URLBox: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareBox: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ViewerSpec: Identifiable {
    let id = UUID()
    let items: [VaultItem]
    let start: Int
}

// MARK: - Photos cleanup (حذف الأصل بعد الاستيراد)

enum PhotoCleaner {
    static func delete(_ identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

// MARK: - PDF

enum PDFTools {
    static func pdfData(from images: [UIImage]) -> Data {
        let doc = PDFDocument()
        for (i, img) in images.enumerated() {
            if let page = PDFPage(image: img) {
                doc.insert(page, at: i)
            }
        }
        return doc.dataRepresentation() ?? Data()
    }
}

// MARK: - QuickLook

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        let close = onClose
        ql.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in close() })
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeCoordinator() -> Coord { Coord(onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(_ f: @escaping (Data?) -> Void) { onFinish = f }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let img = info[.originalImage] as? UIImage
            onFinish(img?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

// MARK: - Files picker (UIKit، أوثق من fileImporter)

struct DocumentPicker: UIViewControllerRepresentable {
    let folder: Bool
    let onFinish: ([URL]) -> Void

    func makeCoordinator() -> Coord { Coord(onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = folder ? [.folder] : [.item]
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: !folder)
        p.allowsMultipleSelection = !folder
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onFinish: ([URL]) -> Void
        init(_ f: @escaping ([URL]) -> Void) { onFinish = f }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish([])
        }
    }
}

// MARK: - Document scanner

struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coord { Coord(onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let v = VNDocumentCameraViewController()
        v.delegate = context.coordinator
        return v
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coord: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(_ f: @escaping ([UIImage]) -> Void) { onFinish = f }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var imgs: [UIImage] = []
            for i in 0..<scan.pageCount {
                imgs.append(scan.imageOfPage(at: i))
            }
            onFinish(imgs)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onFinish([])
        }
    }
}
