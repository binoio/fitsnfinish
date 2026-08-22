// Programmatic app-icon generator for FITS n' Finish.
//
// macOS 26 (Tahoe) and iOS 26 apply the squircle mask themselves, so the
// artwork must fill the entire square canvas edge-to-edge — no pre-rounded
// corners, no margins. Design: a deep-sky frame being "finished" — warm
// light-pollution skyglow rising from the bottom is wiped to a clean
// starfield above, with a faint nebula and a hero star.
//
// Usage: swift Scripts/generate_icons.swift <output-directory>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Deterministic LCG so every run yields the identical starfield.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
}

func renderMaster(size: Int) -> CGImage {
    let s = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // 1. Night-sky base: near-black zenith to deep indigo.
    let sky = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            color(0.015, 0.020, 0.060),
            color(0.040, 0.055, 0.145),
            color(0.075, 0.090, 0.220),
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: []
    )

    // 2. Faint nebula blobs, upper half.
    func blob(cx: CGFloat, cy: CGFloat, radius: CGFloat, core: CGColor) {
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [core, core.copy(alpha: 0)!] as CFArray,
            locations: [0, 1]
        )!
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: cx * s, y: cy * s), startRadius: 0,
            endCenter: CGPoint(x: cx * s, y: cy * s), endRadius: radius * s,
            options: []
        )
    }
    blob(cx: 0.36, cy: 0.70, radius: 0.34, core: color(0.42, 0.20, 0.55, 0.32))
    blob(cx: 0.50, cy: 0.62, radius: 0.26, core: color(0.16, 0.42, 0.52, 0.30))
    blob(cx: 0.30, cy: 0.62, radius: 0.16, core: color(0.60, 0.28, 0.45, 0.22))

    // 3. Skyglow gradient rising from the bottom edge — the thing the app
    // removes — strongest in the corner, wiped away with altitude.
    let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            color(0.95, 0.55, 0.18, 0.85),
            color(0.80, 0.38, 0.14, 0.45),
            color(0.55, 0.22, 0.14, 0.0),
        ] as CFArray,
        locations: [0, 0.4, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 0.28 * s, y: -0.18 * s), startRadius: 0,
        endCenter: CGPoint(x: 0.28 * s, y: -0.18 * s), endRadius: 0.72 * s,
        options: []
    )

    // 4. Deterministic starfield, denser and brighter away from the glow.
    var rng = SeededRandom(seed: 20260822)
    for _ in 0 ..< 170 {
        let x = CGFloat(rng.next())
        let y = CGFloat(rng.next())
        let magnitude = rng.next()
        // Fade stars swallowed by the skyglow (bottom-left).
        let glowDistance = hypot(x - 0.28, y + 0.18)
        let visibility = min(max((glowDistance - 0.30) / 0.35, 0.06), 1)
        let radius = CGFloat(0.8 + magnitude * magnitude * 3.6) * s / 1024
        let alpha = CGFloat((0.35 + 0.65 * magnitude) * visibility)
        let warm = rng.next()
        context.setFillColor(color(
            1.0 - CGFloat(warm) * 0.08,
            1.0 - CGFloat(warm) * 0.16,
            1.0 - CGFloat(warm) * 0.02,
            alpha
        ))
        context.fillEllipse(in: CGRect(
            x: x * s - radius, y: y * s - radius,
            width: radius * 2, height: radius * 2
        ))
    }

    // 5. Hero star with four diffraction spikes, upper right.
    let hero = CGPoint(x: 0.70 * s, y: 0.72 * s)
    let heroGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1, 0.95), color(0.75, 0.85, 1, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        heroGlow, startCenter: hero, startRadius: 0,
        endCenter: hero, endRadius: 0.085 * s, options: []
    )
    // Spikes taper and fade toward their tips: short overlapping segments
    // with decreasing alpha and width.
    context.setLineCap(.round)
    for (dx, dy, length) in [(1, 0, 0.11), (-1, 0, 0.11), (0, 1, 0.145), (0, -1, 0.145)] {
        let segments = 6
        for segment in 0 ..< segments {
            let t0 = CGFloat(segment) / CGFloat(segments)
            let t1 = CGFloat(segment + 1) / CGFloat(segments)
            let fade = 1 - t0
            context.setStrokeColor(color(1, 1, 1, 0.85 * fade * fade))
            context.setLineWidth(s * 0.006 * (0.35 + 0.65 * fade))
            let spike = CGMutablePath()
            spike.move(to: CGPoint(
                x: hero.x + CGFloat(dx) * CGFloat(length) * t0 * s,
                y: hero.y + CGFloat(dy) * CGFloat(length) * t0 * s
            ))
            spike.addLine(to: CGPoint(
                x: hero.x + CGFloat(dx) * CGFloat(length) * t1 * s,
                y: hero.y + CGFloat(dy) * CGFloat(length) * t1 * s
            ))
            context.addPath(spike)
            context.strokePath()
        }
    }
    context.fillEllipse(in: CGRect(
        x: hero.x - 0.014 * s, y: hero.y - 0.014 * s,
        width: 0.028 * s, height: 0.028 * s
    ))

    return context.makeImage()!
}

func resample(_ image: CGImage, to size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("failed to write \(url.path)")
    }
}

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift generate_icons.swift <output-directory>")
    exit(2)
}
let outputRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconset = outputRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let iosIcons = outputRoot.appendingPathComponent("iOS", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iosIcons, withIntermediateDirectories: true)

let master = renderMaster(size: 1024)

// macOS iconset (iconutil naming).
let macEntries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in macEntries {
    writePNG(resample(master, to: size), to: iconset.appendingPathComponent("\(name).png"))
}

// iOS bundle icons (flat CFBundleIcons naming) + marketing size.
let iosEntries: [(String, Int)] = [
    ("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180),
    ("AppIcon76x76@2x", 152), ("AppIcon83.5x83.5@2x", 167),
    ("AppIcon1024", 1024),
]
for (name, size) in iosEntries {
    writePNG(resample(master, to: size), to: iosIcons.appendingPathComponent("\(name).png"))
}

print("Wrote \(macEntries.count) macOS + \(iosEntries.count) iOS icons under \(outputRoot.path)")
