// FILE: UserAttachmentViews.swift
// Purpose: Renders user image attachments in timeline rows and resolves preview images.
// Layer: Turn UI component
// Exports: UserAttachmentStrip, AttachmentPreviewImageResolver
// Depends on: Foundation, SwiftUI, UIKit, CodexImageAttachment, HapticFeedback

import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
private enum UserAttachmentThumbnailCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    nonisolated static func cacheKey(for attachment: CodexImageAttachment) -> String {
        [
            attachment.id,
            attachment.thumbnailContentFingerprint.cacheKey,
            attachment.payloadContentFingerprint?.cacheKey ?? "no-payload",
        ].joined(separator: "|")
    }
}

private enum UserAttachmentThumbnailDecoder {
    struct DecodedThumbnail: @unchecked Sendable {
        let image: UIImage
    }

    nonisolated static func thumbnailImage(for attachment: CodexImageAttachment, maxPixelSize: Int) -> DecodedThumbnail? {
        guard let thumbnailData = thumbnailJPEGData(for: attachment, maxPixelSize: maxPixelSize),
              let image = UIImage(data: thumbnailData)
        else {
            return nil
        }
        return DecodedThumbnail(image: image)
    }

    nonisolated static func thumbnailJPEGData(for attachment: CodexImageAttachment, maxPixelSize: Int) -> Data? {
        let thumbnailBase64 = attachment.thumbnailBase64JPEG.trimmingCharacters(in: .whitespacesAndNewlines)
        if !thumbnailBase64.isEmpty,
           let thumbnailData = Data(base64Encoded: thumbnailBase64)
        {
            return thumbnailData
        }

        guard let payloadDataURL = attachment.payloadDataURL,
              let imageData = decodeImageDataFromDataURL(payloadDataURL)
        else {
            return nil
        }

        return downsampledJPEGData(from: imageData, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decodeImageDataFromDataURL(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let metadata = dataURL[..<commaIndex].lowercased()
        guard metadata.hasPrefix("data:image"),
              metadata.contains(";base64")
        else {
            return nil
        }

        let payloadStart = dataURL.index(after: commaIndex)
        return Data(base64Encoded: String(dataURL[payloadStart...]))
    }

    private nonisolated static func downsampledJPEGData(from imageData: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.75,
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

private struct UserAttachmentThumbnailView: View {
    let attachment: CodexImageAttachment
    private let side = TurnAttachmentThumbnailMetrics.side
    private let cornerRadius = TurnAttachmentThumbnailMetrics.cornerRadius
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnailUIImage: UIImage?

    var body: some View {
        Group {
            if let image = thumbnailUIImage ?? UserAttachmentThumbnailCache.image(forKey: cacheKey) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: side, height: side)
                    .overlay(
                        RemodexIcon.image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )
            }
        }
        .task(id: cacheKey) {
            await loadThumbnailIfNeeded()
        }
    }

    private var cacheKey: String {
        UserAttachmentThumbnailCache.cacheKey(for: attachment)
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        if let cached = UserAttachmentThumbnailCache.image(forKey: cacheKey) {
            thumbnailUIImage = cached
            return
        }

        let cacheKey = cacheKey
        let attachment = attachment
        let maxPixelSize = Int(ceil(side * max(displayScale, 1)))
        let decodedThumbnail = await Task.detached(priority: .utility) {
            UserAttachmentThumbnailDecoder.thumbnailImage(
                for: attachment,
                maxPixelSize: maxPixelSize
            )
        }.value
        guard !Task.isCancelled,
              let image = decodedThumbnail?.image
        else {
            return
        }

        UserAttachmentThumbnailCache.insert(image, forKey: cacheKey)
        thumbnailUIImage = image
    }
}

struct UserAttachmentStrip: View {
    let attachments: [CodexImageAttachment]
    let onTap: (CodexImageAttachment) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(attachments) { attachment in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onTap(attachment)
                } label: {
                    UserAttachmentThumbnailView(attachment: attachment)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
enum AttachmentPreviewImageResolver {
    // Uses full payload data URL first, then falls back to the cached thumbnail for resilience.
    static func resolve(_ attachment: CodexImageAttachment) -> UIImage? {
        if let payloadDataURL = attachment.payloadDataURL,
           let imageData = decodeImageDataFromDataURL(payloadDataURL),
           let image = UIImage(data: imageData)
        {
            return image
        }

        let cacheKey = UserAttachmentThumbnailCache.cacheKey(for: attachment)
        return UserAttachmentThumbnailCache.image(forKey: cacheKey)
    }

    private static func decodeImageDataFromDataURL(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let metadata = dataURL[..<commaIndex].lowercased()
        guard metadata.hasPrefix("data:image"),
              metadata.contains(";base64")
        else {
            return nil
        }

        let payloadStart = dataURL.index(after: commaIndex)
        return Data(base64Encoded: String(dataURL[payloadStart...]))
    }
}
