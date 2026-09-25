import ARKit
import QuickLook
import UIKit

/// UIKit presentations that SwiftUI doesn't cover well: the share sheet for arbitrary files and
/// AR Quick Look (which needs its own full-screen controller with a close button).
@MainActor
enum Presenters {
    static var topViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func share(_ urls: [URL]) {
        guard let top = topViewController else { return }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }

    static func quickLook(_ url: URL) {
        guard let top = topViewController else { return }
        let source = QuickLookSource(url: url)
        let controller = QLPreviewController()
        controller.dataSource = source
        // The data source is weakly held by the controller; keep it alive with the controller.
        objc_setAssociatedObject(controller, &QuickLookSource.key, source, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        controller.modalPresentationStyle = .fullScreen
        top.present(controller, animated: true)
    }
}

private final class QuickLookSource: NSObject, QLPreviewControllerDataSource {
    nonisolated(unsafe) static var key: UInt8 = 0
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        let item = ARQuickLookPreviewItem(fileAt: url)
        item.allowsContentScaling = true
        return item
    }
}
