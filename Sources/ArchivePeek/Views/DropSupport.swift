import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DropSupport {
    static let acceptedTypes: [UTType] = [.fileURL, .url, .data]

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            var finished = false
            let finish: (URL?) -> Void = { url in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                if let url {
                    urls.append(url.standardizedFileURL)
                }
                group.leave()
            }

            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    finish(object)
                }
                continue
            }

            let typeIdentifiers = [
                UTType.fileURL.identifier,
                UTType.url.identifier,
                "public.file-url",
            ]

            guard let type = typeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                finish(nil)
                continue
            }

            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                finish(urlFromDropItem(item))
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }

    static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map { $0.standardizedFileURL }
        }

        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }

        return []
    }

    static func containsFileURLs(in pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return pasteboard.availableType(from: [NSPasteboard.PasteboardType("NSFilenamesPboardType")]) != nil
    }

    private static func urlFromDropItem(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(fileURLWithPath: string)
        }
        return nil
    }
}

struct DropHighlightOverlay: View {
    let isTargeted: Bool
    let title: String
    let subtitle: String

    var body: some View {
        if isTargeted {
            ZStack {
                Color.accentColor.opacity(0.08)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)

                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28, weight: .medium))
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

struct FileDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let title: String
    let subtitle: String
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                DropHighlightOverlay(isTargeted: isTargeted, title: title, subtitle: subtitle)
            }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onDrop(of: DropSupport.acceptedTypes, isTargeted: $isTargeted) { providers in
                DropSupport.loadURLs(from: providers) { urls in
                    guard !urls.isEmpty else { return }
                    onDrop(urls)
                }
                return !providers.isEmpty
            }
    }
}

extension View {
    func fileDropDestination(
        isTargeted: Binding<Bool>,
        title: String,
        subtitle: String,
        perform: @escaping ([URL]) -> Void
    ) -> some View {
        modifier(FileDropModifier(isTargeted: isTargeted, title: title, subtitle: subtitle, onDrop: perform))
    }
}