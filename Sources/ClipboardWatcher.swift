import AppKit
import Carbon.HIToolbox
import Foundation

final class ClipboardWatcher {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func markOwnWrite() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundle = Bundle.main.bundleIdentifier
        if frontmost?.bundleIdentifier == ownBundle {
            return
        }

        let types = pasteboard.types ?? []
        let blockedTypes: Set<NSPasteboard.PasteboardType> = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        ]
        if !blockedTypes.isDisjoint(with: types) {
            return
        }

        let source = frontmost?.localizedName

        // Files copied in Finder.
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [NSURL],
           !objects.isEmpty {
            store.addFiles(objects.map { $0.path ?? "" }.filter { !$0.isEmpty }, source: source)
            return
        }

        // Images.
        if let image = readImage(from: pasteboard),
           let converted = ImageTools.pngData(from: image) {
            store.addImage(
                pngData: converted.data,
                pixelWidth: converted.width,
                pixelHeight: converted.height,
                source: source
            )
            return
        }

        // Plain text.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            store.addText(text, source: source)
        }
    }

    private func readImage(from pasteboard: NSPasteboard) -> NSImage? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: data) {
            return image
        }
        return NSImage(pasteboard: pasteboard)
    }
}
