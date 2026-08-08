import AppKit
import SwiftUI

@MainActor
enum WindowDropInstaller {
    private static var dropHandler: (([URL]) -> Void)?
    private static var targetingHandler: ((Bool) -> Void)?

    static func configure(
        onDrop: @escaping ([URL]) -> Void,
        onTargetingChanged: @escaping (Bool) -> Void
    ) {
        dropHandler = onDrop
        targetingHandler = onTargetingChanged
    }

    static func install(on window: NSWindow) {
        guard !(window.contentView is WindowDropContainerView) else { return }
        guard let existingContent = window.contentView else { return }

        let container = WindowDropContainerView(frame: existingContent.frame)
        container.autoresizingMask = [.width, .height]
        container.onDrop = { urls in
            dropHandler?(urls)
        }
        container.onTargetingChanged = { targeted in
            targetingHandler?(targeted)
        }

        window.contentView = container
        container.addSubview(existingContent)
        existingContent.frame = container.bounds
        existingContent.autoresizingMask = [.width, .height]
    }
}

final class WindowDropContainerView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onTargetingChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isDragOriginatingInSameWindow(sender) else { return [] }
        guard DropSupport.containsFileURLs(in: sender.draggingPasteboard) else { return [] }
        onTargetingChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetingChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetingChanged?(false)
        guard !isDragOriginatingInSameWindow(sender) else { return false }
        let urls = DropSupport.readFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func isDragOriginatingInSameWindow(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? NSView else { return false }
        return source.window === window
    }
}