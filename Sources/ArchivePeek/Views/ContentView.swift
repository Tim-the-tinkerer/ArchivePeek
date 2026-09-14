import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var browser: ArchiveBrowserModel

    private var isBusy: Bool {
        browser.isLoading || browser.isCompressing || browser.isPreviewing
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if browser.isBrowsingArchive {
                ArchiveBrowserView()
            } else {
                WelcomeView()
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if browser.isCompressing {
                CompressionProgressOverlay()
                    .environmentObject(browser)
            } else if browser.isLoading {
                loadingOverlay
            }
        }
        .overlay {
            DropHighlightOverlay(
                isTargeted: browser.isDropTargeted,
                title: dropOverlayTitle,
                subtitle: dropOverlaySubtitle
            )
            .animation(.easeInOut(duration: 0.15), value: browser.isDropTargeted)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove from Archive",
            isPresented: $browser.showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                browser.confirmRemoveSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(browser.removeConfirmationMessage)
        }
        .confirmationDialog(
            "Replace Existing Items?",
            isPresented: $browser.showAddReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                browser.confirmAddReplacingExisting()
            }
            Button("Cancel", role: .cancel) {
                browser.cancelPendingAdd()
            }
        } message: {
            Text(browser.addReplaceConfirmationMessage)
        }
        .sheet(isPresented: $browser.needsPassword) {
            PasswordSheet()
                .environmentObject(browser)
        }
        .sheet(isPresented: $browser.showCompressSheet) {
            CompressSheet()
                .environmentObject(browser)
        }
        .sheet(isPresented: $browser.showHelpSheet) {
            HelpView()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton("Open", systemImage: "folder", help: "Open an archive") {
                openArchivePanel()
            }
            .disabled(isBusy)

            toolbarButton("Compress", systemImage: "doc.zipper", help: "Create a new archive") {
                browser.presentCompressSheet()
            }
            .disabled(browser.isCompressing)

            if browser.hasOpenArchive {
                toolbarDivider

                toolbarButton(
                    "Close Archive",
                    systemImage: "xmark.circle",
                    help: "Return to the welcome screen"
                ) {
                    browser.closeArchive()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(browser.isCompressing)
            }

            if browser.listing != nil {
                toolbarDivider

                toolbarButton(
                    "Open Selection",
                    systemImage: "arrow.right.circle",
                    help: "Open the selected file or folder"
                ) {
                    browser.openSelectedEntry()
                }
                .disabled(browser.selection.isEmpty || isBusy)
                .keyboardShortcut(.return)

                Menu {
                    Button("Extract Selected") {
                        browser.extractSelected()
                    }
                    .disabled(browser.selection.isEmpty)

                    Button("Extract All…") {
                        browser.extractAll()
                    }

                    Button("Extract All to Folder…") {
                        browser.extractAllToFolder()
                    }
                } label: {
                    Label("Extract", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Extract files from the archive")
                .disabled(isBusy)

                toolbarButton(
                    "Add Files",
                    systemImage: "plus",
                    help: browser.canMutateOpenArchive
                        ? "Add files or folders to the current folder"
                        : (browser.mutationUnavailableReason ?? "This archive cannot be modified")
                ) {
                    browser.presentAddFilesPanel()
                }
                .disabled(isBusy || !browser.canMutateOpenArchive)

                toolbarButton(
                    "Remove",
                    systemImage: "trash",
                    help: browser.canMutateOpenArchive
                        ? "Remove selected items from the archive"
                        : (browser.mutationUnavailableReason ?? "This archive cannot be modified")
                ) {
                    browser.requestRemoveSelected()
                }
                .disabled(isBusy || !browser.canMutateOpenArchive || browser.selection.isEmpty)

                toolbarButton("Quick Look", systemImage: "eye", help: "Preview the selected file") {
                    browser.quickLookSelected()
                }
                .disabled(browser.selection.isEmpty || isBusy)

                toolbarButton(
                    "Verify Integrity",
                    systemImage: "checkmark.shield",
                    help: "Test the open archive for corruption"
                ) {
                    browser.verifyOpenArchive()
                }
                .disabled(isBusy)
            }

            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 18)
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let url = browser.archiveURL, browser.hasOpenArchive {
                Text(url.lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
                Text("·")
                    .foregroundStyle(.tertiary)
            }

            Text(browser.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Text(ToolLocator.statusSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
            ProgressView()
                .controlSize(.large)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )
    }

    private var dropOverlayTitle: String {
        if browser.isBrowsingArchive {
            return browser.canMutateOpenArchive ? "Drop to Add or Open" : "Drop to Open"
        }
        return "Drop to Open or Compress"
    }

    private var dropOverlaySubtitle: String {
        if browser.isBrowsingArchive {
            if browser.canMutateOpenArchive {
                return "Files and folders are added to this folder. Drop an archive to open it instead."
            }
            return "Drop an archive to open it. This format cannot be modified."
        }
        return "Archives open for browsing. Files and folders are added to compress."
    }

    private func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.message = "Choose an archive to browse."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let standardized = url.standardizedFileURL
            let tokens = SecurityScopedAccess.captureTokens(for: [standardized])
            browser.openArchive(standardized, accessTokens: tokens)
        }
    }

}