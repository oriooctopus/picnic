import SwiftUI
import AVFoundation

/// Pure crop-box math, in unit coordinates (0...1, origin top-left) of the
/// image as displayed. Kept out of the view so it's unit-testable
/// (CropGeometryTests); CropView only converts points to units.
enum CropGeometry {
    enum Corner: String, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Drags one corner by `delta` from where the drag began (`start`); the
    /// opposite corner stays pinned. Clamped to the image and to `minSize`,
    /// so a corner dragged past its opposite stops instead of flipping.
    static func resize(_ start: CGRect, corner: Corner, by delta: CGSize, minSize: CGSize) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch corner {
        case .topLeft, .bottomLeft: minX = min(max(0, minX + delta.width), maxX - minSize.width)
        case .topRight, .bottomRight: maxX = max(min(1, maxX + delta.width), minX + minSize.width)
        }
        switch corner {
        case .topLeft, .topRight: minY = min(max(0, minY + delta.height), maxY - minSize.height)
        case .bottomLeft, .bottomRight: maxY = max(min(1, maxY + delta.height), minY + minSize.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Slides the whole box by `delta`, keeping its size and staying inside the image.
    static func move(_ start: CGRect, by delta: CGSize) -> CGRect {
        CGRect(x: min(max(0, start.minX + delta.width), 1 - start.width),
               y: min(max(0, start.minY + delta.height), 1 - start.height),
               width: start.width, height: start.height)
    }

    /// Save does nothing useful when the box still covers (almost) the whole image.
    static func isUncropped(_ rect: CGRect) -> Bool {
        rect.minX < 0.005 && rect.minY < 0.005 && rect.maxX > 0.995 && rect.maxY > 0.995
    }
}

/// Full-screen crop editor for the deck's current photo or video, presented
/// as a DeckPresentation so its drags never compete with the card's swipe
/// pan. A video is cropped on its poster frame: the crop applies to every
/// frame identically, so one still is enough to frame it.
struct CropView: View {
    let image: UIImage
    /// The asset's current pixel size (display orientation), for the
    /// output-size readout; the crop itself is sent as unit coordinates.
    let pixelSize: CGSize
    let onCancel: () -> Void
    /// Unit rect, origin top-left (see MediaCropper.crop).
    let onSave: (CGRect) -> Void

    @State private var rect = CropGeometry.full
    /// The rect when the current drag began: gestures report translation from
    /// their start, so applying it to the live rect would compound per frame.
    @State private var dragStart: CGRect?

    private let handleSize: CGFloat = 22
    /// Smallest box, in points on screen. A guess at "still grabbable and
    /// still meaningful"; converted to units per image fit below.
    private let minSidePoints: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let fit = AVMakeRect(aspectRatio: image.size,
                                     insideRect: CGRect(origin: .zero, size: geo.size).insetBy(dx: 24, dy: 24))
                editor(fit: fit)
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("crop.cancel")
                Spacer()
                Text(sizeLabel)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("crop.size")
                Spacer()
                Button("Save") { onSave(rect) }
                    .fontWeight(.bold)
                    .foregroundStyle(.yellow.opacity(CropGeometry.isUncropped(rect) ? 0.35 : 1))
                    .disabled(CropGeometry.isUncropped(rect))
                    .accessibilityIdentifier("crop.save")
            }
            .font(.system(size: 17))
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// "1200 × 900": what Save will produce, in pixels.
    private var sizeLabel: String {
        "\(Int((rect.width * pixelSize.width).rounded())) × \(Int((rect.height * pixelSize.height).rounded()))"
    }

    private func editor(fit: CGRect) -> some View {
        let box = CGRect(x: fit.minX + rect.minX * fit.width, y: fit.minY + rect.minY * fit.height,
                         width: rect.width * fit.width, height: rect.height * fit.height)
        let minSize = CGSize(width: min(1, minSidePoints / fit.width), height: min(1, minSidePoints / fit.height))
        let units: (CGSize) -> CGSize = { CGSize(width: $0.width / fit.width, height: $0.height / fit.height) }

        return ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: fit.width, height: fit.height)
                .offset(x: fit.minX, y: fit.minY)

            // Dim everything outside the box (even-odd fill punches the hole).
            Path { p in p.addRect(fit); p.addRect(box) }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            // Drag inside the box to move it.
            Rectangle()
                .strokeBorder(.white, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? rect
                        dragStart = start
                        rect = CropGeometry.move(start, by: units(value.translation))
                    }
                    .onEnded { _ in dragStart = nil })
                .accessibilityIdentifier("crop.box")

            ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
                Rectangle()
                    .fill(.white)
                    .frame(width: handleSize, height: handleSize)
                    // Hit area well beyond the drawn square: corners sit on
                    // the image edge, where a fingertip is hard to place.
                    .contentShape(Rectangle().inset(by: -14))
                    .position(point(of: corner, in: box))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStart ?? rect
                            dragStart = start
                            rect = CropGeometry.resize(start, corner: corner, by: units(value.translation), minSize: minSize)
                        }
                        .onEnded { _ in dragStart = nil })
                    .accessibilityIdentifier("crop.handle.\(corner.rawValue)")
            }
        }
    }

    private func point(of corner: CropGeometry.Corner, in box: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: box.minX, y: box.minY)
        case .topRight: return CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        }
    }
}
