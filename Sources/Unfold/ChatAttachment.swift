import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let path: String

    static let maximumCount = 8
    static var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnfoldNative/Attachments", isDirectory: true)
    }

    enum Source: Sendable { case file(URL), data(Data) }

    static func sources(from pasteboard: NSPasteboard) -> [Source] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !files.isEmpty { return files.map(Source.file) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [.data(data)] }
        }
        return []
    }

    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.png, .tiff]) != nil { return true }
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    /// Keep a private, normalized copy so moving the original does not break a draft.
    static func importImage(_ source: Source, directory: URL = storage) throws -> ChatAttachment {
        let data: Data
        let name: String
        switch source {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 40 * 1024 * 1024 else {
                throw failure("Choose an image smaller than 40 MB.")
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe); name = url.lastPathComponent
        case .data(let bytes): data = bytes; name = "Pasted image"
        }
        guard data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw failure("This image could not be opened. Try a PNG, JPEG or HEIC image.") }
        let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw failure("The image could not be saved.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("The image could not be saved.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ChatAttachment(id: id, name: name, path: url.path)
    }

    func thumbnail() -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 180
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    var input: [String: Any] { ["type": "localImage", "path": path] }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ThoughtStream.Attachments", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class AttachmentTile: NSView {
    let attachment: ChatAttachment
    let preview = NSImageView()
    private var onRemove: () -> Void

    init(_ attachment: ChatAttachment, onRemove: @escaping () -> Void) {
        self.attachment = attachment; self.onRemove = onRemove
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12
        layer?.borderWidth = 1; layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        preview.image = attachment.thumbnail(); preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.cornerRadius = 8; preview.layer?.masksToBounds = true
        preview.setAccessibilityLabel("Attached image: \(attachment.name)")
        let label = NSTextField(labelWithString: attachment.name)
        label.font = Typography.metadata; label.textColor = FeedPalette.muted; label.lineBreakMode = .byTruncatingMiddle
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(attachment.name)")!, target: self, action: #selector(removeAttachment))
        remove.isBordered = false; remove.imageScaling = .scaleProportionallyDown
        remove.toolTip = "Remove \(attachment.name)"; remove.contentTintColor = .labelColor
        for child in [preview, label, remove] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 100), heightAnchor.constraint(equalToConstant: 80),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), preview.topAnchor.constraint(equalTo: topAnchor, constant: 4), preview.heightAnchor.constraint(equalToConstant: 54),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), remove.topAnchor.constraint(equalTo: topAnchor, constant: 1), remove.widthAnchor.constraint(equalToConstant: 24), remove.heightAnchor.constraint(equalToConstant: 24)
        ])
        toolTip = attachment.name
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    @objc private func removeAttachment() { onRemove() }
}

@MainActor
final class ImageDropHint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 12, yRadius: 12).fill()
        let text = "Drop images to attach"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.controlAccentColor]
        let size = text.size(withAttributes: attributes)
        let x = (bounds.width - size.width - 30) / 2
        NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)?.draw(in: NSRect(x: x, y: (bounds.height - 22) / 2, width: 22, height: 22))
        text.draw(at: NSPoint(x: x + 30, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
