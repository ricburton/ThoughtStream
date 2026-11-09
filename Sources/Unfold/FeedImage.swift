import AppKit
import ImageIO

enum FeedImage {
    /// Decode locally using macOS, including HEIC/TIFF and other ImageIO formats.
    static func load(path: String?, source: String?, project: URL?) -> [String: String] {
        do {
            let data: Data
            if let path {
                let url: URL
                if path.hasPrefix("file://"), let file = URL(string: path), file.isFileURL { url = file }
                else if path.hasPrefix("/") || path.hasPrefix("~/") { url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
                else if let project { url = project.appendingPathComponent(path) }
                else { return ["error": "The image’s project folder is unavailable."] }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) <= 80 * 1024 * 1024 else {
                    return ["error": "The image is unavailable or larger than 80 MB."]
                }
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } else if let source, source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ",") {
                let header = source[..<comma]
                let content = String(source[source.index(after: comma)...])
                guard source.utf8.count <= 112 * 1024 * 1024 else { return ["error": "The image is larger than 80 MB."] }
                if header.hasSuffix(";base64"), let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) { data = decoded }
                else if !header.hasSuffix(";base64"), let decoded = content.removingPercentEncoding { data = Data(decoded.utf8) }
                else { return ["error": "The image data is incomplete."] }
            } else { return ["error": "This image source could not be read."] }
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
                // AppKit also recognizes vector formats, including SVG and PDF images.
                guard let native = NSImage(data: data),
                      let image = native.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    return ["error": "macOS could not decode this image."]
                }
                return ["src": "data:image/png;base64," + png.base64EncodedString()]
            }
            let type = CGImageSourceGetType(imageSource) as String? ?? ""
            // Preserve animation and original dimensions for browser-native formats.
            let mime = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp"]
            if let contentType = mime[type] { return ["src": "data:\(contentType);base64," + data.base64EncodedString()] }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 8192]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return ["error": "macOS could not decode this image."]
            }
            return ["src": "data:image/png;base64," + png.base64EncodedString()]
        } catch { return ["error": "Image unavailable: \(error.localizedDescription)"] }
    }
}
