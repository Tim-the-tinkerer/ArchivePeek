import AppKit
import SwiftUI

package struct SettingsView: View {
    package init() {}
    @AppStorage(AppSettings.Keys.compressFormat) private var compressFormatRaw = CompressFormat.defaultFormat.rawValue
    @AppStorage(AppSettings.Keys.compressionLevel) private var compressionLevel = 5
    @AppStorage(AppSettings.Keys.verifyAfterCompress) private var verifyAfterCompress = true
    @AppStorage(AppSettings.Keys.solidArchive) private var solidArchive = false
    @AppStorage(AppSettings.Keys.dmgAppInstaller) private var dmgAppInstaller = false
    @AppStorage(AppSettings.Keys.comicBookZip) private var comicBookZip = false
    @AppStorage(AppSettings.Keys.zipMethod) private var zipMethodRaw = ZipCompressionMethod.defaultMethod.rawValue
    @AppStorage(AppSettings.Keys.finderContextMenu) private var finderContextMenuEnabled = false

    @State private var exclusionPatterns: [String] = []
    @State private var exclusionDraft = ""
    @State private var exclusionMessage: String?
    @State private var defaultAppSummary = ""
    @State private var defaultAppMessage: String?
    @State private var isSettingDefaultApp = false

    private var finderContextMenu: Binding<Bool> {
        Binding(
            get: { finderContextMenuEnabled },
            set: { finderContextMenuEnabled = $0 }
        )
    }

    private var compressFormat: Binding<CompressFormat> {
        Binding(
            get: { CompressFormat(rawValue: compressFormatRaw) ?? .defaultFormat },
            set: { compressFormatRaw = $0.rawValue }
        )
    }

    private var zipMethod: Binding<ZipCompressionMethod> {
        Binding(
            get: { ZipCompressionMethod(rawValue: zipMethodRaw) ?? .defaultMethod },
            set: { zipMethodRaw = $0.rawValue }
        )
    }

    private var compressionLevelSelection: Binding<Int> {
        Binding(
            get: { AppSettings.normalizedCompressionLevel(compressionLevel) },
            set: { compressionLevel = AppSettings.normalizedCompressionLevel($0) }
        )
    }

    package var body: some View {
        ScrollView {
        Form {
            Section {
                Picker("Default format", selection: compressFormat) {
                    ForEach(CompressFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }

                Picker("Default compression level", selection: compressionLevelSelection) {
                    Text("Store").tag(0)
                    Text("Fast").tag(1)
                    Text("Normal").tag(5)
                    Text("Maximum").tag(9)
                }

                Toggle("Verify before replacing existing file", isOn: $verifyAfterCompress)

                if compressFormat.wrappedValue.supportsSolidArchive {
                    Toggle("Solid archive (7z / RAR)", isOn: $solidArchive)
                }

                if compressFormat.wrappedValue.isZip {
                    Picker("ZIP method", selection: zipMethod) {
                        ForEach(ZipCompressionMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    Toggle("Save ZIP as comic book (.cbz)", isOn: $comicBookZip)
                }

                if compressFormat.wrappedValue.isDmg {
                    Toggle("DMG app installer layout", isOn: $dmgAppInstaller)
                }
            } header: {
                Text("Compression")
            } footer: {
                Text("These defaults apply whenever you open the Compress sheet. When verify is on, a new archive is integrity-tested before any existing file at the destination is replaced. Comic book ZIP saves a standard ZIP with a .cbz extension. ZIP method Deflate64 uses a 64 KB window and is written with 7-Zip. ArchivePeek and unzip can open it. macOS ditto cannot. Store still writes uncompressed files. DMG app installer layout is used when compressing .app bundles to DMG. Creating RAR archives requires WinRAR’s rar command; 7-Zip can still open RAR files.")
            }

            Section {
                if exclusionPatterns.isEmpty {
                    Text("No extra exclusions.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(exclusionPatterns, id: \.self) { pattern in
                                HStack(spacing: 8) {
                                    Text(pattern)
                                        .font(.body.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Button {
                                        AppSettings.removeCustomExclusion(pattern)
                                        reloadExclusions()
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Remove \(pattern)")
                                    .accessibilityLabel("Remove \(pattern)")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }

                HStack(spacing: 8) {
                    TextField("Name or pattern", text: $exclusionDraft)
                        .onSubmit(addExclusion)
                    Button("Add", action: addExclusion)
                        .disabled(exclusionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let exclusionMessage {
                    Text(exclusionMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Exclusions")
            } footer: {
                Text("Left out of new archives and of files added to an open ZIP or 7z. A name matches anywhere: node_modules, .git, *.log. A path matches that sequence: dist/.staging or src/*.swift. * and ? are wildcards inside one name. ** matches any folders, as in logs/**. Matching ignores case. .DS_Store, ._* AppleDouble files, and __MACOSX are always removed and do not need to be listed. The list starts empty, so project files stay until you add a pattern.")
            }

            Section {
                Toggle("Show in Finder contextual menu", isOn: finderContextMenu)
                    .onChange(of: finderContextMenuEnabled) { enabled in
                        FinderServices.setContextMenuEnabled(enabled)
                    }

                Button("Open Keyboard Shortcuts…") {
                    openServicesSettings()
                }
            } header: {
                Text("Finder")
            } footer: {
                Text("Adds ArchivePeek: Extract Here and ArchivePeek: Create Archive to Finder. Look under Services or Quick Actions in the right-click menu (macOS often nests them there). Extract unpacks into a folder next to the archive. Create uses your default format. After turning this on, relaunch ArchivePeek and right-click a file again. If the items are missing, use Open Keyboard Shortcuts… and enable them under Services → Files and Folders.")
            }

            Section {
                Text(defaultAppSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    setDefaultApplication()
                } label: {
                    if isSettingDefaultApp {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Setting default application…")
                        }
                    } else {
                        Text("Set ArchivePeek as Default for Archives")
                    }
                }
                .disabled(isSettingDefaultApp)

                if let defaultAppMessage {
                    Text(defaultAppMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Default Application")
            } footer: {
                Text("Registers ArchivePeek for archive types such as ZIP, 7z, TAR, and RAR. DMG and ISO are excluded — use Disk Utility or Finder for those. macOS may ask you to confirm a single change.")
            }

            Section {
                Text("Version \(AppInfo.versionLabel)")
                    .foregroundStyle(.secondary)

                Button("Check for Updates…") {
                    UpdateChecker.checkAndPresent()
                }

                Button("ArchivePeek on GitHub") {
                    NSWorkspace.shared.open(AppInfo.githubRepositoryURL)
                }
            } header: {
                Text("About")
            } footer: {
                Text("Checks the latest release on GitHub (github.com/Tim-the-tinkerer/ArchivePeek). Updates are installed by downloading a new build from Releases.")
            }
        }
        .formStyle(.grouped)
        }
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 560)
        .frame(minHeight: 480, idealHeight: 680, maxHeight: 840)
        .onAppear {
            let snapped = AppSettings.normalizedCompressionLevel(compressionLevel)
            if snapped != compressionLevel {
                compressionLevel = snapped
            }
            reloadExclusions()
            refreshDefaultAppStatus()
        }
        .onChange(of: exclusionDraft) { _ in
            exclusionMessage = nil
        }
    }

    private func reloadExclusions() {
        exclusionPatterns = AppSettings.customExclusionPatterns
    }

    private func addExclusion() {
        if let message = AppSettings.addCustomExclusion(exclusionDraft) {
            exclusionMessage = message
        } else {
            exclusionDraft = ""
            exclusionMessage = nil
        }
        reloadExclusions()
    }

    private func refreshDefaultAppStatus() {
        defaultAppSummary = DefaultAppRegistration.defaultApplicationSummary()
    }

    private func setDefaultApplication() {
        isSettingDefaultApp = true
        defaultAppMessage = nil

        let result = DefaultAppRegistration.setAsDefaultArchiveApplication()
        refreshDefaultAppStatus()

        if result.succeeded {
            defaultAppMessage = "ArchivePeek is now the default app for archives."
        } else {
            defaultAppMessage = "Could not set ArchivePeek as the default app. Try again or choose ArchivePeek manually in Finder → Get Info → Open With."
        }

        isSettingDefaultApp = false
    }

    private func openServicesSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Services",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}