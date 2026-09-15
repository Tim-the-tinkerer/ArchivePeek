import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Keys.compressFormat) private var compressFormatRaw = CompressFormat.defaultFormat.rawValue
    @AppStorage(AppSettings.Keys.compressionLevel) private var compressionLevel = 5
    @AppStorage(AppSettings.Keys.verifyAfterCompress) private var verifyAfterCompress = true
    @AppStorage(AppSettings.Keys.solidArchive) private var solidArchive = false
    @AppStorage(AppSettings.Keys.dmgAppInstaller) private var dmgAppInstaller = false
    @AppStorage(AppSettings.Keys.comicBookZip) private var comicBookZip = false
    @AppStorage(AppSettings.Keys.finderContextMenu) private var finderContextMenuEnabled = false

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

    var body: some View {
        Form {
            Section {
                Picker("Default format", selection: compressFormat) {
                    ForEach(CompressFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }

                Picker("Default compression level", selection: $compressionLevel) {
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
                    Toggle("Save ZIP as comic book (.cbz)", isOn: $comicBookZip)
                }

                if compressFormat.wrappedValue.isDmg {
                    Toggle("DMG app installer layout", isOn: $dmgAppInstaller)
                }
            } header: {
                Text("Compression")
            } footer: {
                Text("These defaults apply whenever you open the Compress sheet. When verify is on, a new archive is integrity-tested before any existing file at the destination is replaced. Comic book ZIP saves a standard ZIP with a .cbz extension. DMG app installer layout is used when compressing .app bundles to DMG. Creating RAR archives requires WinRAR’s rar command; 7-Zip can still open RAR files.")
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
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 520)
        .frame(minHeight: 780, idealHeight: 780, maxHeight: 780)
        .onAppear {
            refreshDefaultAppStatus()
        }
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