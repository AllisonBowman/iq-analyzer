import Testing
import CoreGraphics
import Foundation
@testable import IQCoach

struct ClippingMaskTests {
    /// A 4x4 sRGB image from RGBA pixels given in reading order (top-left first).
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> CGImage {
        precondition(pixels.count == 16)
        var bytes: [UInt8] = []
        for p in pixels { bytes += [p.0, p.1, p.2, 255] }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// RGBA8 bytes of a mask image, read back through a context.
    private func bytes(_ m: ClippingMask) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: m.width * m.height * 4)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: m.width, height: m.height, bitsPerComponent: 8, bytesPerRow: m.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(m.image, in: CGRect(x: 0, y: 0, width: m.width, height: m.height))
        }
        return out
    }

    @Test func flagsExactlyOneWhiteAndOneBlackPixel() throws {
        var px = [(UInt8, UInt8, UInt8)](repeating: (128, 128, 128), count: 16)
        px[1] = (255, 255, 255)
        px[14] = (0, 0, 0)
        let m = try #require(ClippingMask.make(from: image(px)))
        #expect(m.highCount == 1)
        #expect(m.lowCount == 1)
        let b = bytes(m)
        for i in 0..<16 {
            let rgba = Array(b[(i * 4)..<(i * 4 + 4)])
            switch i {
            case 1: #expect(rgba == [255, 0, 0, 255], "white pixel is tinted red")
            case 14: #expect(rgba == [0, 0, 255, 255], "black pixel is tinted blue")
            default: #expect(rgba[3] == 0, "pixel \(i) is not clipped, so it stays clear")
            }
        }
    }

    @Test func thresholdsAreAny254ForHighAndAllUnder2ForLow() throws {
        var px = [(UInt8, UInt8, UInt8)](repeating: (128, 128, 128), count: 16)
        px[0] = (254, 10, 10)     // one channel at 254: blown
        px[1] = (10, 255, 10)     // blown
        px[2] = (253, 253, 253)   // just under: not blown
        px[3] = (1, 1, 1)         // all at 1: crushed
        px[4] = (2, 0, 0)         // one channel at 2: not crushed
        px[5] = (0, 0, 1)         // crushed
        px[6] = (0, 0, 200)       // only two channels dark: not crushed
        let m = try #require(ClippingMask.make(from: image(px)))
        #expect(m.highCount == 2)
        #expect(m.lowCount == 2)
        let b = bytes(m)
        let flagged = (0..<16).filter { b[$0 * 4 + 3] != 0 }
        #expect(flagged == [0, 1, 3, 5])
    }

    @Test func aPlainGreyImageHasNoClipping() throws {
        let m = try #require(ClippingMask.make(from: image([(UInt8, UInt8, UInt8)](repeating: (120, 120, 120), count: 16))))
        #expect(m.highCount == 0 && m.lowCount == 0)
    }
}
