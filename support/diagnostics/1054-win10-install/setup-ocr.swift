import AppKit
import Foundation
import Vision

// Read the original guest framebuffer without changing the OS or application.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
try VNImageRequestHandler(url: url).perform([request])
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
print(String(data: try JSONSerialization.data(withJSONObject: lines), encoding: .utf8)!)
