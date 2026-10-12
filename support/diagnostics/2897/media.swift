import AppKit
import AVFoundation
import Foundation

guard CommandLine.arguments.count == 3, let minimumSeconds = Double(CommandLine.arguments[2]) else { exit(2) }
let path = CommandLine.arguments[1]
let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let seconds = CMTimeGetSeconds(asset.duration)
let tracks = asset.tracks(withMediaType: .video)
guard seconds.isFinite, seconds > 1, asset.isPlayable, !tracks.isEmpty else {
    fputs("Recording has no playable continuous video track\n", stderr); exit(3)
}
guard seconds >= minimumSeconds else {
    fputs("Recording duration \(seconds) does not span recorded case interval \(minimumSeconds)\n", stderr); exit(5)
}
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
for (index, second) in [0.0, seconds / 2, max(0, seconds - 1)].enumerated() {
    let cgImage = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(4) }
    try png.write(to: URL(fileURLWithPath: "\(path).frame-\(index).png"))
}
let metadata: [String: Any] = ["file": path, "durationSeconds": seconds, "playable": asset.isPlayable,
    "minimumCaseIntervalSeconds": minimumSeconds, "caseIntervalCovered": seconds >= minimumSeconds,
    "videoTracks": tracks.map { ["width": $0.naturalSize.width, "height": $0.naturalSize.height,
        "nominalFrameRate": $0.nominalFrameRate] as [String: Any] }]
let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
