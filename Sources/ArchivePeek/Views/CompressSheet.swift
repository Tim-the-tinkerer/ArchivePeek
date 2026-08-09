import AppKit
import SwiftUI

struct CompressSheet: View {
    @EnvironmentObject private var browser: ArchiveBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Archive")
                .font(.title2.bold())

            Text("Choose files or folders, pick a format, and save the new archive.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sourceList

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Format", selection: $browser.compressFormat) {
                        ForEach(CompressFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Compression")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Compression", selection: $browser.compressionLevel) {
                        Text("Store").tag(0)
                        Text("Fast").tag(1)
                        Text("Normal").tag(5)
                        Text("Maximum").tag(9)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            if browser.compressFormat.supportsPassword {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $browser.compressPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if browser.compressFormat.supportsSolidArchive {
                Toggle(isOn: $browser.compressSolidArchive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Solid archive")
                        Text("Better compression for many similar files, but slower to create and extract individual files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if browser.compressFormat.requiresSingleFile {
                Text("\(browser.compressFormat.label) can only archive a single file.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if browser.compressFormat.isDmg {
                if browser.canCreateDmgAppInstaller {
                    Toggle(isOn: $browser.compressDmgAppInstaller) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App installer layout")
                            Text("Adds an Applications folder shortcut so users can drag the app to install.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Creates a standard macOS disk image. Store uses an uncompressed read-only image; other levels use zlib compression.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $browser.verifyAfterCompress) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify before replacing existing file")
                    Text("Integrity-tests the new archive before replacing any file already at the destination. If verification fails, the previous archive is left intact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Add Files…") {
                    browser.addCompressSources()
                }
                Spacer()
                Button("Cancel") {
                    browser.closeCompressSheet()
                    dismiss()
                }
                Button("Create Archive…") {
                    browser.chooseCompressDestination()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(browser.compressSources.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: browser.compressFormat) { format in
            if !format.isDmg {
                browser.compressDmgAppInstaller = false
            }
            if !format.supportsPassword {
                browser.compressPassword = ""
            }
        }
        .onChange(of: browser.compressSources.map(\.path)) { _ in
            if !browser.canCreateDmgAppInstaller {
                browser.compressDmgAppInstaller = false
            }
        }
        .fileDropDestination(
            isTargeted: $isDropTargeted,
            title: "Drop Files or Folders",
            subtitle: "Dropped items will be added to this archive."
        ) { urls in
            let items = urls.filter { !ArchiveFormatCatalog.isArchive($0) }
            if items.isEmpty {
                browser.errorMessage = "Drop files or folders to compress, not archives."
            } else {
                browser.mergeCompressSourcesFromDrop(items)
            }
        }
    }

    private var sourceList: some View {
        Group {
            if browser.compressSources.isEmpty {
                ContentPlaceholder(
                    title: "No Items Selected",
                    subtitle: "Add files or folders, or drag them here."
                )
            } else {
                List {
                    ForEach(browser.compressSources, id: \.absoluteString) { url in
                        HStack(spacing: 10) {
                            Image(systemName: iconName(for: url))
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                browser.removeCompressSource(url)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                        }
                    }
                }
                .frame(height: min(180, CGFloat(browser.compressSources.count) * 32 + 24))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func iconName(for url: URL) -> String {
        if CompressionSupport.isApplicationBundle(url) {
            return "app.fill"
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder.fill"
        }
        return "doc"
    }
}

private struct ContentPlaceholder: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}