import SwiftUI

struct ArchiveBrowserView: View {
    @EnvironmentObject private var browser: ArchiveBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            if browser.visibleEntries.isEmpty {
                emptyFolderView
            } else {
                entryTable
            }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(browser.breadcrumbSegments.enumerated()), id: \.element.path) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(segment.label) {
                        browser.navigateTo(path: segment.path)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == browser.breadcrumbSegments.count - 1 ? Color.primary : Color.accentColor)
                    .font(.callout.weight(index == browser.breadcrumbSegments.count - 1 ? .semibold : .regular))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var entryTable: some View {
        ArchiveEntryTableView(
            entries: browser.visibleEntries,
            selection: $browser.selection,
            onOpenEntry: { browser.openEntry($0) },
            onPreviewEntry: { browser.previewEntry($0) },
            onExtractEntry: { browser.extractEntry($0) },
            onOpenSelected: { browser.openSelectedEntry() },
            onExtractSelected: { browser.extractSelected() },
            onQuickLookSelected: { browser.quickLookSelected() },
            onPrepareDragOut: { browser.prepareDragOut(for: $0) },
            preparedDragURL: { browser.preparedDragURL(for: $0) },
            writeDraggedEntry: { browser.writeDraggedEntryToPromise($0, url: $1, completion: $2) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(browser.currentPath)
    }

    private var emptyFolderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Empty Folder")
                .font(.headline)
            Text("This folder contains no items.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}