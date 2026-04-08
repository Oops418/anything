import AppKit
@preconcurrency import QuickLookUI

@MainActor
final class QuickPreviewCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickPreviewCoordinator()

    private var currentURL: URL?
    private(set) var isVisible = false

    func togglePreview(for url: URL?) {
        guard let url else {
            NSSound.beep()
            return
        }

        if isVisible, currentURL == url {
            dismissPreview()
            return
        }

        currentURL = url
        presentPreview()
    }

    func dismissPreview() {
        QLPreviewPanel.shared()?.orderOut(nil)
        isVisible = false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentURL as NSURL?
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        isVisible = false
    }

    private func presentPreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
    }
}
