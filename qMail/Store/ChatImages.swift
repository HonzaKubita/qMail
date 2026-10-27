import Foundation
import ImageIO
import MailCore
import UniformTypeIdentifiers

/// A downscaled image from an email, shown inline in chat messages.
struct ChatImage: Sendable, Hashable, Identifiable {
    let attachmentID: Int
    let filename: String
    let data: Data
    let width: Int
    let height: Int

    var id: Int { attachmentID }
}

enum ChatImages {
    /// Photos and screenshots from a message, skipping logos, spacers and images that only
    /// appear in the quoted part of a reply.
    static func extract(from message: ParsedMessage) -> [ChatImage] {
        let html = message.htmlBody?.lowercased()
        let ownHTML = message.htmlBody.map { QuoteStripper.cutHTMLQuote($0).lowercased() }
        let displaySizes = message.htmlBody.map(declaredSizes) ?? [:]
        let images = message.attachments.filter { attachment in
            guard attachment.mimeType.hasPrefix("image/") else { return false }
            if let cid = attachment.contentID?.lowercased(), let html, html.contains("cid:\(cid)") {
                // Signature logos are big files shown small: trust the size the email displays them at.
                if let shown = displaySizes[cid], shown < 180 { return false }
                return ownHTML?.contains("cid:\(cid)") ?? false
            }
            return true
        }
        return images.prefix(8).compactMap(thumbnail)
    }

    private static let imageTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
    private static let cidSource = try! NSRegularExpression(pattern: #"src\s*=\s*["']?cid:([^"'\s>]+)"#, options: [.caseInsensitive])
    private static let dimension = try! NSRegularExpression(
        // Lookbehind keeps max-width/min-height out of it.
        pattern: #"(?<![-\w])(?:width|height)\s*(?:=\s*["']?|:\s*)(\d+(?:\.\d+)?)(?:px)?"#,
        options: [.caseInsensitive]
    )

    /// The largest width/height an HTML email declares for each inline (cid) image.
    private static func declaredSizes(in html: String) -> [String: Double] {
        var sizes: [String: Double] = [:]
        for match in imageTag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let whole = NSRange(tag.startIndex..., in: tag)
            guard let cidMatch = cidSource.firstMatch(in: tag, range: whole),
                  let cidRange = Range(cidMatch.range(at: 1), in: tag) else { continue }
            let values = dimension.matches(in: tag, range: whole).compactMap { result in
                Range(result.range(at: 1), in: tag).flatMap { Double(tag[$0]) }
            }
            if let largest = values.max() { sizes[tag[cidRange].lowercased()] = largest }
        }
        return sizes
    }

    private static func thumbnail(_ attachment: MailAttachment) -> ChatImage? {
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Signature logos, social icons and tracking pixels are small; real pictures aren't.
        guard max(width, height) >= 200, min(width, height) >= 100 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let output = NSMutableData()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ChatImage(attachmentID: attachment.id, filename: attachment.filename, data: output as Data,
                         width: image.width, height: image.height)
    }
}
