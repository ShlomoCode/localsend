import Foundation
import Vision
import AppKit
import ImageIO

// Build and run on the authorized cloud Mac. Coordinates use PNG pixels,
// with the origin at the top left, matching the VNC framebuffer.
func main() throws {
    guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: ocr IMAGE.png [EXACT_PHRASE]"])
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read image"])
    }
    let width = image.width, height = image.height
    let phrase = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil
    if phrase?.isEmpty == true { throw NSError(domain: "OCR", code: 3) }
    func pixels(_ box: CGRect) -> [String: Double] {
        return ["x": Double(box.minX) * Double(width), "y": (1 - Double(box.maxY)) * Double(height),
                "width": Double(box.width) * Double(width), "height": Double(box.height) * Double(height)]
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    var lines: [[String: Any]] = []
    var matches: [[String: Any]] = []
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        lines.append(["text": candidate.string, "confidence": candidate.confidence, "bounds": pixels(observation.boundingBox)])
        if let phrase = phrase, candidate.confidence >= 0.5 {
            var start = candidate.string.startIndex
            while start < candidate.string.endIndex,
                  let range = candidate.string.range(of: phrase, options: [.literal], range: start..<candidate.string.endIndex) {
                // Phrase boundaries prevent "Send" from matching "Sending".
                let previous = range.lowerBound == candidate.string.startIndex ? nil : candidate.string[candidate.string.index(before: range.lowerBound)]
                let next = range.upperBound == candidate.string.endIndex ? nil : candidate.string[range.upperBound]
                let bounded = !(previous?.isLetter == true || previous?.isNumber == true || previous == "_" ||
                                next?.isLetter == true || next?.isNumber == true || next == "_")
                if bounded, let rect = try candidate.boundingBox(for: range) {
                    matches.append(["text": phrase, "line": candidate.string, "confidence": candidate.confidence, "bounds": pixels(rect.boundingBox)])
                }
                start = range.upperBound
            }
        }
    }
    let document: [String: Any] = ["width": width, "height": height, "origin": "top-left", "lines": lines, "matches": matches]
    let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
do { try main() } catch {
    FileHandle.standardError.write(Data("OCR failed: \(error)\n".utf8))
    exit(1)
}
