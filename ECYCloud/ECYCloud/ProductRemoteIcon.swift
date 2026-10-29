import SwiftUI
import ImageIO
import ECYCloudKit

struct ProductGroupIcon: View {
    let session: ClientSession
    let url: String?
    var selectable = true
    var size: CGFloat = 30
    var placeholder: AnyView?
    var inset = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var source: CGImageSource?
    @State private var vector: SVGIcon?
    @State private var durations: [Double] = []
    @State private var started = Date()
    private var address: URL? { RemoteIconStore.resolve(url, origin: session.endpoints.site) }
    var body: some View {
        Group {
            if let vector { vector }
            else if let source {
                TimelineView(.animation(minimumInterval: durations.min() ?? 0.1, paused: reduceMotion || CGImageSourceGetCount(source) <= 1)) { context in
                    if let image = frame(source, at: context.date) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else { fallback }
                }
            } else { fallback }
        }
        .padding(inset ? size * 0.1 : 0).frame(width: size, height: size)
        .background(inset && scheme == .dark && address != nil ? Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
        .task(id: address) {
            source = nil; vector = nil; durations = []
            guard let address, let data = try? await session.icons.load(address), !Task.isCancelled else { return }
            if let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let type = CGImageSourceGetType(image) as String?, ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(type),
               CGImageSourceGetCount(image) > 0, CGImageSourceGetCount(image) <= 120,
               (0..<CGImageSourceGetCount(image)).allSatisfy({ index in
                   let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any]
                   guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
                         let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return false }
                   return (1...4096).contains(width) && (1...4096).contains(height)
               }) {
                durations = (0..<CGImageSourceGetCount(image)).map { index in
                    let values = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any]
                    let gif = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let webp = values?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                    let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                        ?? webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double ?? webp?[kCGImagePropertyWebPDelayTime] as? Double ?? 0.1
                    return delay.isFinite ? min(60, max(0.02, delay)) : 0.1
                }
                source = image; started = .now
            } else { vector = SVGIcon(data: data) }
        }
    }
    @ViewBuilder private var fallback: some View {
        if let placeholder { placeholder } else {
        ProductGlyph(name: selectable ? "tune_outlined" : "auto_mode_outlined", size: size * 2 / 3)
            .foregroundStyle(ProductPalette(scheme: scheme).accent)
        }
    }
    private func frame(_ source: CGImageSource, at date: Date) -> CGImage? {
        let count = CGImageSourceGetCount(source)
        var index = 0
        if !reduceMotion, count > 1 {
            var time = max(0, date.timeIntervalSince(started)).truncatingRemainder(dividingBy: durations.reduce(0, +))
            while index < count - 1, time >= durations[index] { time -= durations[index]; index += 1 }
        }
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
