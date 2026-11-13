import AppKit
import SwiftUI

// MARK: - Remote images

/// Memory + URLCache-backed image loader. Images are decoded and downsampled off the main
/// thread to the pixel size they're drawn at — decoding full 1280×720 thumbnails lazily during
/// drawing is what made scrolling stutter.
actor ImageLoader {
    static let shared = ImageLoader()

    private nonisolated(unsafe) let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20,
                                   directory: AppPaths.cacheDir.appending(path: "images"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    init() { memory.totalCostLimit = 256 << 20 }

    private nonisolated static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(maxPixel)#\(url.absoluteString)" as NSString }

    nonisolated func cached(_ url: URL, maxPixel: Int) -> NSImage? { memory.object(forKey: Self.key(url, maxPixel)) }

    func image(_ url: URL, maxPixel: Int) async -> NSImage? {
        let key = Self.key(url, maxPixel) as String
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let task = inflight[key] { return await task.value }
        let session = session
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image, let rep = image.representations.first {
            memory.setObject(image, forKey: key as NSString, cost: rep.pixelsWide * rep.pixelsHigh * 4)
        }
        return image
    }

    /// Decode straight to a bitmap no larger than `maxPixel` on its longest side.
    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// Longest side in pixels to decode at; match it to the drawn size (×2 for Retina).
    var maxPixel: Int = 640
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, let u = URL(string: url) else { image = nil; return }
            if let hit = ImageLoader.shared.cached(u, maxPixel: maxPixel) { image = hit; return }
            image = nil
            let loaded = await ImageLoader.shared.image(u, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}

// MARK: - Toasts

struct ToastOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            ForEach(app.toasts) { toast in
                Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(toast.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

// MARK: - Playlist artwork

struct PlaylistArtwork: View {
    let url: String?
    var size: CGFloat = 36
    var circle = false

    var body: some View {
        RemoteImage(url: url, maxPixel: Int(size * 2)) {
            Rectangle().fill(.quaternary).overlay {
                Image(systemName: "music.note.list").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.18)))
    }
}

/// App icon used as the brand mark (signed-out screen, toolbar).
struct AppMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
