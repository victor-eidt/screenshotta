import CoreImage
import Vision

/// On-device text recognition with Vision. Nothing leaves the Mac.
nonisolated enum TextRecognizer {
    /// Recognizes the text in `image` and returns it in reading order, or an empty string when there is none.
    @concurrent
    static func text(in image: CGImage) async throws -> String {
        RecognizedTextLayout.assemble(try fragments(in: image))
    }

    static func fragments(in image: CGImage) throws -> [RecognizedTextLayout.Fragment] {
        let prepared = prepare(image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // The default ignores text shorter than 1/32 of the image: body text in a big selection.
        request.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: prepared, options: [:]).perform([request])

        let size = CGSize(width: prepared.width, height: prepared.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLayout.Fragment(text: candidate.string, normalizedBox: observation.boundingBox, imageSize: size)
        }
    }

    /// Selections are often dragged tight around the text, and Vision misses glyphs that touch the edge,
    /// so the image gets a margin of its own edge pixels (which look like the background). Small
    /// selections are also enlarged: Vision reads small, non-Retina text much better at twice the size.
    static func prepare(_ image: CGImage) -> CGImage {
        let scale: CGFloat = max(image.width, image.height) < 800 ? 2 : 1
        let margin = 16 * scale
        // Clamped before scaling, so the filter samples edge pixels past the border, not transparency
        // (which would leave a faded, see-through band around the text).
        var input = CIImage(cgImage: image).clampedToExtent()
        if scale != 1 {
            input = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let content = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let extent = content.insetBy(dx: -margin, dy: -margin)
        let padded = input.cropped(to: extent).settingAlphaOne(in: extent)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(padded, from: extent) ?? image
    }
}
