// Prints the text in an image, one line per recognised line (Vision, accurate mode).
//   swift scripts/ocr.swift image.png   (scripts/bambu-gui-check.sh builds and uses it for dialogs)
import Foundation
import Vision

guard let path = CommandLine.arguments.dropFirst().first,
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { FileHandle.standardError.write(Data("usage: ocr image.png\n".utf8)); exit(2) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: image).perform([request])
for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string { print(text) }
}
