import SwiftUI
import MediaPlayer

/// iPod-style Cover Flow: the selected album faces front, its neighbors stand angled to the
/// sides, all with reflections, on black. The wheel moves through albums.
struct CoverFlowView: View {
    let albums: [MPMediaItemCollection]
    let index: Int

    /// How many albums are drawn on each side of the selected one.
    private let reach = 5

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.height * 0.56
            if albums.isEmpty {
                Text("Albüm yok")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: geo.size.height * 0.03) {
                    ZStack {
                        ForEach(max(0, index - reach) ... min(albums.count - 1, index + reach), id: \.self) { i in
                            let offset = i - index
                            ReflectedCover(album: albums[i], size: size)
                                .rotation3DEffect(.degrees(offset == 0 ? 0 : offset < 0 ? 62 : -62),
                                                  axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                                .scaleEffect(offset == 0 ? 1 : 0.86)
                                .offset(x: xOffset(offset, size: size))
                                .zIndex(Double(-abs(offset)))
                        }
                    }
                    .frame(width: geo.size.width, height: size * 1.32, alignment: .top)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: index)

                    VStack(spacing: 2) {
                        Text(Library.albumName(albums[index].representativeItem))
                            .font(.system(size: geo.size.height * 0.07, weight: .bold))
                        Text(Library.artistName(albums[index].representativeItem))
                            .font(.system(size: geo.size.height * 0.06))
                            .foregroundColor(Color(white: 0.7))
                    }
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                }
                .padding(.top, geo.size.height * 0.05)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color.black)
        .clipped()
    }

    /// The front cover is centered; side covers start just outside it and then stack closely.
    private func xOffset(_ offset: Int, size: CGFloat) -> CGFloat {
        guard offset != 0 else { return 0 }
        let side: CGFloat = offset < 0 ? -1 : 1
        return side * (size * 0.62 + CGFloat(abs(offset) - 1) * size * 0.24)
    }
}

private struct ReflectedCover: View {
    let album: MPMediaItemCollection
    let size: CGFloat

    var body: some View {
        VStack(spacing: 1) {
            cover
            // The mirrored copy, cropped to its top (the cover's bottom edge) and faded out.
            cover
                .scaleEffect(x: 1, y: -1)
                .frame(height: size * 0.3, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
        }
    }

    private var cover: some View {
        Group {
            if let image = ArtworkCache.image(for: album, size: size) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.35), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundColor(Color(white: 0.55))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

/// Artwork decoding is slow enough to stutter the scroll animation, so covers are cached.
enum ArtworkCache {
    private static let cache = NSCache<NSNumber, UIImage>()

    static func image(for album: MPMediaItemCollection, size: CGFloat) -> UIImage? {
        guard let item = album.representativeItem else { return nil }
        let key = NSNumber(value: item.albumPersistentID)
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = item.artwork?.image(at: CGSize(width: size * 2, height: size * 2)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
