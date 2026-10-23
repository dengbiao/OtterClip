import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

guard (2...3).contains(CommandLine.arguments.count) else {
    fail("Usage: swift scripts/make-icon.swift <output.iconset> [source.png]")
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let defaultSource = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Assets/AppIcon.png")
let source = CommandLine.arguments.count == 3
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : defaultSource

guard FileManager.default.fileExists(atPath: source.path) else {
    fail("Source image is missing: \(source.path). Add Assets/AppIcon.png or pass a source path.")
}

do {
    let data = try Data(contentsOf: source)
    let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard data.starts(with: pngSignature),
          let sourceRepresentation = NSBitmapImageRep(data: data),
          let cgImage = sourceRepresentation.cgImage else {
        fail("Invalid source image: \(source.path). Expected a readable PNG.")
    }
    let width = cgImage.width
    let height = cgImage.height
    guard width == height, width >= 1024 else {
        fail("Invalid source dimensions: \(width) × \(height). Expected a square PNG of at least 1024 × 1024 pixels.")
    }

    let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: pixels * 4,
                bitsPerPixel: 32
            ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
                fail("Could not create a \(pixels) × \(pixels) RGBA bitmap.")
            }
            representation.size = NSSize(width: pixels, height: pixels)
            let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            context.cgContext.interpolationQuality = .high
            context.cgContext.clear(bounds)
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                       respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()

            guard let png = representation.representation(using: .png, properties: [:]) else {
                fail("Could not encode the \(pixels) × \(pixels) PNG.")
            }
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
} catch {
    fail(error.localizedDescription)
}
