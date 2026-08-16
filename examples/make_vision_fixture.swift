import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make_vision_fixture.swift <output.jpg>\n".utf8))
    exit(2)
}

let width = 768
let height = 768
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("unable to create bitmap context")
}

context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.setFillColor(CGColor(red: 0.95, green: 0.03, blue: 0.03, alpha: 1))
context.fillEllipse(in: CGRect(x: 104, y: 104, width: 560, height: 560))

guard let image = context.makeImage() else {
    fatalError("unable to create fixture image")
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.jpeg.identifier as CFString, 1, nil
) else {
    fatalError("unable to create JPEG destination")
}

let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
CGImageDestinationAddImage(destination, image, options)
guard CGImageDestinationFinalize(destination) else {
    fatalError("unable to write JPEG fixture")
}

print(output.path)
