import AppKit
import SwiftUI

@main
struct RenderProbe: GuardedRender {
    static func render() throws {
        let renderer = ImageRenderer(content: Color.blue.frame(width: 32, height: 32))
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Guarded image render failed")
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
