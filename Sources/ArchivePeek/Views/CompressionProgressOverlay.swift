import SwiftUI

struct CompressionProgressOverlay: View {
    @EnvironmentObject private var browser: ArchiveBrowserModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.20)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(browser.progressOperationTitle, systemImage: progressSymbol)
                        .font(.headline)
                    Spacer()
                }

                Text(browser.compressProgressMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                if browser.compressProgressIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: browser.compressProgress, total: 1.0)
                        .progressViewStyle(.linear)
                }

                Text(percentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack {
                    Spacer()
                    Button("Stop") {
                        browser.cancelCompression()
                    }
                }
            }
            .padding(24)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }

    private var progressSymbol: String {
        switch browser.progressOperationTitle {
        case "Adding Files": return "plus.circle"
        case "Removing Items": return "trash"
        default: return "doc.zipper"
        }
    }

    private var percentLabel: String {
        if browser.compressProgressIndeterminate {
            return "Working…"
        }
        let percent = Int((browser.compressProgress * 100).rounded())
        return "\(percent)%"
    }
}