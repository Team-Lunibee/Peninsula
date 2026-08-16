import AppKit
import QuickLookUI

/// Opens the system Quick Look panel for shelf items.
///
/// Quick Look normally finds its data source by walking the responder chain,
/// which an accessory app driving a non-activating panel cannot rely on. The
/// panel's `dataSource` is therefore set directly, and the app is activated
/// first — Quick Look's window belongs to the calling app and will not come
/// forward for a process that has never been active.
@MainActor
final class QuickLook: NSObject {
    private static let shared = QuickLook()

    private var urls: [URL] = []

    static func present(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        shared.urls = urls

        NSApp.activate(ignoringOtherApps: true)

        guard let panel = QLPreviewPanel.shared() else {
            // No panel means no Quick Look on this system; opening in the
            // default app is the same intent by another route.
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }

        panel.dataSource = shared
        panel.delegate = shared
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }
}

extension QuickLook: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

extension QuickLook: QLPreviewPanelDelegate {}
