import AppKit
import CryptoKit
import Foundation

final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let maxItems = 100
    private let maxTextLength = 200_000
    private let maxImageBytes = 25_000_000

    private let baseURL: URL
    private let imagesURL: URL
    private let historyURL: URL

    private let ioQueue = DispatchQueue(label: "com.icopy.store.io", qos: .utility)
    private let imageCache = NSCache<NSString, NSImage>()

    var dataFolderURL: URL { baseURL }

    init() {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        baseURL = support.appendingPathComponent("icopy", isDirectory: true)
        imagesURL = baseURL.appendingPathComponent("images", isDirectory: true)
        historyURL = baseURL.appendingPathComponent("history.json")

        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        if load() {
            removeOrphanedImages()
        }
    }

    // MARK: - Capture

    func addText(_ text: String, source: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let limited = String(text.prefix(maxTextLength))
        let item = ClipItem(
            id: UUID(),
            kind: .text,
            text: limited,
            imageName: nil,
            filePaths: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            date: Date(),
            pinned: false,
            sourceApp: source,
            key: "t:" + Self.hash(Data(limited.utf8))
        )
        insert(item)
    }

    func addImage(pngData: Data, pixelWidth: Int, pixelHeight: Int, source: String?) {
        guard !pngData.isEmpty, pngData.count <= maxImageBytes else { return }
        let key = "i:" + Self.hash(pngData)

        if items.contains(where: { $0.key == key }) {
            insert(ClipItem(
                id: UUID(),
                kind: .image,
                text: nil,
                imageName: nil,
                filePaths: nil,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                date: Date(),
                pinned: false,
                sourceApp: source,
                key: key
            ))
            return
        }

        let name = UUID().uuidString + ".png"
        let url = imagesURL.appendingPathComponent(name)
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            return
        }

        insert(ClipItem(
            id: UUID(),
            kind: .image,
            text: nil,
            imageName: name,
            filePaths: nil,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            date: Date(),
            pinned: false,
            sourceApp: source,
            key: key
        ))
    }

    func addFiles(_ paths: [String], source: String?) {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }

        let item = ClipItem(
            id: UUID(),
            kind: .files,
            text: nil,
            imageName: nil,
            filePaths: unique,
            pixelWidth: nil,
            pixelHeight: nil,
            date: Date(),
            pinned: false,
            sourceApp: source,
            key: "f:" + Self.hash(Data(unique.joined(separator: "\u{1F}").utf8))
        )
        insert(item)
    }

    // MARK: - Mutations

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.pinned.toggle()
        if item.pinned {
            items.insert(item, at: 0)
        } else {
            items.insert(item, at: pinnedCount)
        }
        save()
        notifyChange()
    }

    func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].pinned else { return }
        var item = items.remove(at: index)
        item.date = Date()
        items.insert(item, at: pinnedCount)
        save()
        notifyChange()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        removeImageFile(for: item)
        save()
        notifyChange()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        removed.forEach { removeImageFile(for: $0) }
        save()
        notifyChange()
    }

    func flush() {
        ioQueue.sync {}
    }

    // MARK: - Reading images

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageName else { return nil }
        return imagesURL.appendingPathComponent(name)
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let name = item.imageName else { return nil }
        if let cached = imageCache.object(forKey: name as NSString) {
            return cached
        }
        guard let image = NSImage(contentsOf: imagesURL.appendingPathComponent(name)) else {
            return nil
        }
        imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    // MARK: - Private

    private var pinnedCount: Int {
        items.firstIndex(where: { !$0.pinned }) ?? items.count
    }

    private func insert(_ newItem: ClipItem) {
        if let index = items.firstIndex(where: { $0.key == newItem.key }) {
            var existing = items.remove(at: index)
            existing.date = newItem.date
            if let source = newItem.sourceApp, !source.isEmpty {
                existing.sourceApp = source
            }
            if let w = newItem.pixelWidth { existing.pixelWidth = w }
            if let h = newItem.pixelHeight { existing.pixelHeight = h }
            items.insert(existing, at: existing.pinned ? 0 : pinnedCount)
            save()
            notifyChange()
            return
        }

        if newItem.pinned {
            items.insert(newItem, at: 0)
        } else {
            items.insert(newItem, at: pinnedCount)
        }
        trim()
        save()
        notifyChange()
    }

    private func trim() {
        let pinned = items.filter { $0.pinned }
        let allowedUnpinned = max(0, maxItems - pinned.count)
        var result = pinned
        var kept = 0
        for item in items where !item.pinned {
            if kept < allowedUnpinned {
                result.append(item)
                kept += 1
            } else {
                removeImageFile(for: item)
            }
        }
        items = result
    }

    private func removeImageFile(for item: ClipItem) {
        guard let name = item.imageName else { return }
        imageCache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: imagesURL.appendingPathComponent(name))
    }

    private func notifyChange() {
        onChange?()
    }

    private func save() {
        let snapshot = items
        let url = historyURL
        ioQueue.async {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    @discardableResult
    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return true
        }
        guard
            let data = try? Data(contentsOf: historyURL),
            let decoded = try? JSONDecoder().decode([ClipItem].self, from: data)
        else {
            return false
        }

        let valid = decoded.filter { item in
            guard item.kind == .image else { return true }
            guard let name = item.imageName else { return false }
            return FileManager.default.fileExists(atPath: imagesURL.appendingPathComponent(name).path)
        }

        let pinned = valid.filter { $0.pinned }
        let unpinned = valid.filter { !$0.pinned }.prefix(max(0, maxItems - pinned.count))
        items = pinned + unpinned
        return true
    }

    private func removeOrphanedImages() {
        let referenced = Set(items.compactMap { $0.imageName })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ClipboardWriter {
    @discardableResult
    static func write(_ item: ClipItem, store: ClipboardStore) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            return pasteboard.setString(item.text ?? "", forType: .string)

        case .image:
            guard let url = store.imageURL(for: item),
                  let png = try? Data(contentsOf: url) else {
                return false
            }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            if let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return true

        case .files:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }
    }
}

enum ImageTools {
    static func pngData(from image: NSImage, maxDimension: CGFloat = 3200) -> (data: Data, width: Int, height: Int)? {
        let pixelSize = actualPixelSize(of: image)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        let largest = max(pixelSize.width, pixelSize.height)
        let scale = min(1, maxDimension / largest)
        let targetWidth = max(1, Int((pixelSize.width * scale).rounded()))
        let targetHeight = max(1, Int((pixelSize.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, targetWidth, targetHeight)
    }

    private static func actualPixelSize(of image: NSImage) -> (width: CGFloat, height: CGFloat) {
        let best = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        if let best, best.pixelsWide > 0, best.pixelsHigh > 0 {
            return (CGFloat(best.pixelsWide), CGFloat(best.pixelsHigh))
        }
        return (image.size.width, image.size.height)
    }
}
