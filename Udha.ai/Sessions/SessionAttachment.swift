import SwiftUI
import UIKit

/// One image on its way from the phone's library to a session's prompt.
///
/// Claude cannot be handed bytes through tmux, so an image reaches a session as
/// a path it can read — exactly what the Mac does when you drop a file on a
/// session pane. The phone's extra hop is the upload: the host stages the bytes
/// under `/tmp/udha/attachments`, copies them to the box if that is where the
/// session lives, and answers with the path. Until that answer arrives the chip
/// says "staging…" and Send stays off, because sending the prompt first would
/// hand Claude a path to a file that is not there yet.
struct SessionAttachment: Identifiable, Equatable {
    /// Also the correlation token on the wire — the host echoes it so a reply
    /// can find its chip when two images are in flight for one session.
    let id: String
    /// Which session this is staged for. An attachment is never global: you
    /// picked it while looking at one pane.
    let sessionID: String
    let name: String
    /// Thumbnail for the chip, decoded once at pick time.
    let thumbnail: UIImage?
    /// Bytes actually sent, for the chip's size line. The honest number to show
    /// is what crossed the wire, not what the library held.
    let byteCount: Int
    /// The path on the machine that will read it. Nil while in flight.
    var path: String?
    /// Set when the host refused or could not copy it. The chip says so.
    var failure: String?

    var isReady: Bool { path != nil }
    var isInFlight: Bool { path == nil && failure == nil }

    /// "412 KB" — small enough to sit in a chip, exact enough to explain a slow
    /// upload on a phone connection.
    var sizeText: String {
        byteCount >= 1_048_576
            ? String(format: "%.1f MB", Double(byteCount) / 1_048_576)
            : "\(max(byteCount / 1024, 1)) KB"
    }
}

// MARK: - Preparing an image for the wire

/// Turning a photo-library item into something worth sending.
///
/// A screenshot off an iPhone 16 Pro is a 1290×2796 PNG of several megabytes,
/// and base64 adds a third on top. None of that reaches Claude: it reads the
/// image at a far smaller size, and the only thing the extra megabytes buy is a
/// slow upload on a phone connection. So every image is drawn down to fit a
/// bounding box and re-encoded as JPEG, stepping quality down until it fits the
/// budget — text in a screenshot stays legible at 1600px, which is the thing
/// being sent for.
enum AttachmentEncoder {

    /// Longest edge of the image that gets sent. Above this nothing is gained;
    /// below it a screenshot's text starts to smear.
    static let maximumEdge: CGFloat = 1600

    /// What one image may weigh on the wire, before base64. Chosen so the
    /// encoded message stays well inside the socket's ceiling even with two
    /// images picked at once.
    static let byteBudget = 700 * 1024

    struct Prepared: Sendable {
        var data: Data
        var name: String
        var mime: String
    }

    /// Scale, encode, and keep stepping quality down until it fits. Returns nil
    /// only when the data is not an image at all.
    static func prepare(_ data: Data, name: String) -> Prepared? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = downscaled(image)

        // A small PNG is left alone: re-encoding a 40 KB screenshot of a
        // terminal as JPEG makes it both bigger and blurrier.
        if data.count <= byteBudget / 3, isPNG(data), scaled.size == image.size {
            return Prepared(data: data, name: stem(name) + ".png", mime: "image/png")
        }

        for quality in [0.8, 0.65, 0.5, 0.35] as [CGFloat] {
            guard let jpeg = scaled.jpegData(compressionQuality: quality) else { continue }
            if jpeg.count <= byteBudget {
                return Prepared(data: jpeg, name: stem(name) + ".jpg", mime: "image/jpeg")
            }
        }
        // Still too heavy at the lowest quality: halve the edge once more and
        // take whatever that gives, rather than refusing to send anything.
        let smaller = downscaled(scaled, edge: maximumEdge / 2)
        guard let jpeg = smaller.jpegData(compressionQuality: 0.5) else { return nil }
        return Prepared(data: jpeg, name: stem(name) + ".jpg", mime: "image/jpeg")
    }

    /// A chip-sized preview. Drawn from the scaled image so a huge original
    /// never sits in memory twice.
    static func thumbnail(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return downscaled(image, edge: 120)
    }

    private static func downscaled(_ image: UIImage, edge: CGFloat = maximumEdge) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > edge, longest > 0 else { return image }
        let scale = edge / longest
        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        // 1, not the screen's scale: the point size *is* the pixel size here.
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// A readable stem for the staged filename. The host makes it unique; this
    /// only has to say what the thing was.
    private static func stem(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "screenshot" : trimmed
    }
}
