import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// A file the user attached, ready to send.
public struct Attachment: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case image, pdf, text, folder
    }

    public var id: UUID
    public var url: URL
    public var name: String
    public var kind: Kind
    public var byteCount: Int
    public var part: ContentPart

    public var systemImage: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .folder: return "folder"
        }
    }
}

public enum AttachmentError: LocalizedError {
    case unreadable(String)
    case tooLarge(String, Int)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "\(name) could not be read."
        case .tooLarge(let name, let limit): return "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .unsupported(let name): return "\(name) is not an image, PDF or text file."
        }
    }
}

public enum AttachmentLoader {
    public static let maxTextBytes = 512_000
    public static let maxPDFBytes = 30_000_000
    public static let maxImageBytes = 20_000_000
    /// Images are scaled so their long edge is at most this, which every
    /// provider accepts and which keeps the request small.
    public static let maxImageDimension = 2_048

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]

    /// Loads a file off the main actor.
    public static func load(_ url: URL) async throws -> Attachment {
        try await FileIO.offMainThrowing { try loadSync(url) }
    }

    static func loadSync(_ url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AttachmentError.unreadable(name)
        }
        if isDirectory.boolValue {
            let listing = folderListing(url)
            return Attachment(id: UUID(), url: url, name: name, kind: .folder, byteCount: listing.utf8.count,
                              part: .text("<folder path=\"\(url.path)\">\n\(listing)\n</folder>"))
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ext = url.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            guard size <= maxImageBytes else { throw AttachmentError.tooLarge(name, maxImageBytes) }
            let image = try loadImage(url)
            return Attachment(id: UUID(), url: url, name: name, kind: .image, byteCount: size, part: .image(image))
        }

        if ext == "pdf" {
            guard size <= maxPDFBytes else { throw AttachmentError.tooLarge(name, maxPDFBytes) }
            guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(name) }
            let document = DocumentContent(
                filename: name,
                data: InlineData(mediaType: "application/pdf", data: data),
                extractedText: pdfText(url)
            )
            return Attachment(id: UUID(), url: url, name: name, kind: .pdf, byteCount: size, part: .document(document))
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AttachmentError.unreadable(name) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes + 1)) ?? Data()
        guard looksLikeText(data) else { throw AttachmentError.unsupported(name) }
        var text = String(decoding: data.prefix(maxTextBytes), as: UTF8.self)
        if data.count > maxTextBytes { text += "\n[Truncated: the file is longer than \(maxTextBytes / 1000) KB.]" }
        let document = DocumentContent(filename: name, data: nil, extractedText: text)
        return Attachment(id: UUID(), url: url, name: name, kind: .text, byteCount: size, part: .document(document))
    }

    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        if sample.isEmpty { return true }
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil || String(data: sample.dropLast(3), encoding: .utf8) != nil
    }

    static func folderListing(_ url: URL, limit: Int = 300) -> String {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return "" }
        var lines: [String] = []
        let prefix = url.standardizedFileURL.path + "/"
        for case let child as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            lines.append(child.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") + (isDirectory ? "/" : ""))
            if lines.count >= limit {
                lines.append("… (more files not listed)")
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    static func pdfText(_ url: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 300) {
            if let text = document.page(at: index)?.string, !text.isEmpty {
                pages.append("[Page \(index + 1)]\n\(text)")
            }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
        #else
        return nil
        #endif
    }

    static func loadImage(_ url: URL) throws -> InlineData {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AttachmentError.unreadable(url.lastPathComponent)
        }
        let ext = url.pathExtension.lowercased()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let passThrough = ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) && max(width, height) <= maxImageDimension
        if passThrough, let data = try? Data(contentsOf: url) {
            let type = ext == "jpg" ? "jpeg" : ext
            return InlineData(mediaType: "image/\(type)", data: data)
        }
        // Re-encode (HEIC, TIFF, oversized) as JPEG at a bounded size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError.unreadable(url.lastPathComponent)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentError.unreadable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unreadable(url.lastPathComponent) }
        return InlineData(mediaType: "image/jpeg", data: output as Data)
        #else
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(url.lastPathComponent) }
        return InlineData(mediaType: "image/\(url.pathExtension.lowercased())", data: data)
        #endif
    }
}

/// Reads the files selected in Finder through Apple Events. Needs the
/// `apple-events` capability, and macOS asks the user once to let Droppy
/// control Finder.
public enum FinderSelection {
    public enum Failure: LocalizedError {
        case notAuthorized
        case finderNotRunning
        case script(String)

        public var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Droppy is not allowed to control Finder. Turn it on in System Settings, Privacy & Security, Automation."
            case .finderNotRunning: return "Finder is not running."
            case .script(let message): return message
            }
        }
    }

    static let source = """
    if application "Finder" is not running then return "DROPCHAT_FINDER_NOT_RUNNING"
    tell application "Finder"
        set out to ""
        repeat with anItem in (get selection)
            set out to out & POSIX path of (anItem as alias) & linefeed
        end repeat
        return out
    end tell
    """

    private static let queue = DispatchQueue(label: "dropchat.finder-selection")

    /// The POSIX paths of Finder's selection, in order.
    public static func selectedURLs() async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: Failure.script("The Finder script could not be built."))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if code == -1743 || code == -10004 {
                        continuation.resume(throwing: Failure.notAuthorized)
                    } else {
                        continuation.resume(throwing: Failure.script(error[NSAppleScript.errorMessage] as? String ?? "Finder did not answer."))
                    }
                    return
                }
                let text = result.stringValue ?? ""
                if text == "DROPCHAT_FINDER_NOT_RUNNING" {
                    continuation.resume(throwing: Failure.finderNotRunning)
                    return
                }
                let urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                continuation.resume(returning: urls)
            }
        }
    }
}
