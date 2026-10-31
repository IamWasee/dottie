//
//  DottieThumbnailCache.swift
//  leanring-buddy
//
//  Small copies of the pictures shown in Home (the conversation's pictures,
//  the picture library), made once and kept in memory. Views used to load
//  each picture at full size from disk every time they were drawn.
//

import AppKit
import ImageIO

@MainActor
enum DottieThumbnailCache {
    private static let thumbnailsByKey: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    /// The picture at `fileURL`, at most `maximumPixelSize` on its longest
    /// side. Made again only when the file changes.
    static func thumbnail(of fileURL: URL, maximumPixelSize: Int) -> NSImage? {
        let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let cacheKey = "\(fileURL.path)|\(maximumPixelSize)|\(modificationDate?.timeIntervalSince1970 ?? 0)" as NSString
        if let cachedThumbnail = thumbnailsByKey.object(forKey: cacheKey) {
            return cachedThumbnail
        }
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: thumbnailImage, size: NSSize(width: thumbnailImage.width, height: thumbnailImage.height))
        thumbnailsByKey.setObject(thumbnail, forKey: cacheKey)
        return thumbnail
    }
}
