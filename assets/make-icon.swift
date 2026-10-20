// Draws telly's iPad icon (1024×1024, full bleed, no transparency; iPadOS rounds the corners):
// the white wordmark and accent bar on the blue-slate gradient, as on the Mac.
// Run: swift assets/make-icon.swift Telly/Assets.xcassets/AppIcon.appiconset/icon.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
// An opaque bitmap: the App Store and iPadOS reject icons with an alpha channel.
let cg = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

let gradient = NSGradient(colors: [NSColor(srgbRed: 0x2a/255, green: 0x3a/255, blue: 0x55/255, alpha: 1),
                                   NSColor(srgbRed: 0x15/255, green: 0x1a/255, blue: 0x22/255, alpha: 1)])!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)

let font = NSFont.systemFont(ofSize: 300, weight: .black)
let text = NSAttributedString(string: "telly", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -2])
let b = text.size()
text.draw(at: NSPoint(x: (size - b.width) / 2, y: (size - b.height) / 2 + 10))
NSColor(srgbRed: 0x4f/255, green: 0xc3/255, blue: 0xf7/255, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: (size - 180) / 2, y: 300, width: 180, height: 22), xRadius: 11, yRadius: 11).fill()

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
