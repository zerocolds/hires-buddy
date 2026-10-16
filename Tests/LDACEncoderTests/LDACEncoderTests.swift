import Foundation
import XCTest
@testable import LDACEncoder

final class LDACEncoderTests: XCTestCase {
    private func sineBlock() -> [Float] {
        var sine = [Float](repeating: 0, count: 256)
        for i in 0..<128 {
            let v = sinf(Float(i) * 0.1)
            sine[2 * i] = v
            sine[2 * i + 1] = v
        }
        return sine
    }

    /// Encodes `blocks` blocks, returns (bytes, frames).
    private func run(_ enc: LDACEncoder, blocks: Int) throws -> (Int, Int) {
        let sine = sineBlock()
        var total = 0, frames = 0
        for _ in 0..<blocks {
            if let p = try sine.withUnsafeBufferPointer({ try enc.encode($0) }) {
                total += p.bytes.count
                frames += p.frames
            }
        }
        return (total, frames)
    }

    func testEncoderProducesPacketsAtNominalBitrate() throws {
        let enc = try LDACEncoder(sampleRate: .hz48000, quality: .hq)
        let (total, frames) = try run(enc, blocks: 2000)
        XCTAssertEqual(enc.samplesPerFrame, 128)
        let seconds = Double(frames * 128) / 48000
        let kbps = Double(total * 8) / seconds / 1000
        XCTAssert((900...1000).contains(kbps), "\(kbps)")
    }

    func testQualityChangeMidStreamChangesBitrate() throws {
        let enc = try LDACEncoder(sampleRate: .hz48000, quality: .hq)
        let (hqBytes, hqFrames) = try run(enc, blocks: 500)
        enc.quality = .mq
        XCTAssertEqual(enc.quality, .mq)
        _ = try run(enc, blocks: 50) // let the switch settle
        let (mqBytes, mqFrames) = try run(enc, blocks: 500)
        let hq = Double(hqBytes * 8) / (Double(hqFrames * 128) / 48000) / 1000
        let mq = Double(mqBytes * 8) / (Double(mqFrames * 128) / 48000) / 1000
        XCTAssert(hq > 800, "hq \(hq)")
        XCTAssert(mq < 400, "mq \(mq)")
    }

    func testNominalBitrateTable() {
        XCTAssertEqual(LDACEncoder.nominalBitrate(quality: .hq, sampleRate: .hz48000), 990)
        XCTAssertEqual(LDACEncoder.nominalBitrate(quality: .hq, sampleRate: .hz44100), 909)
        XCTAssertEqual(LDACEncoder.nominalBitrate(quality: .sq, sampleRate: .hz96000), 660)
        XCTAssertEqual(LDACEncoder.nominalBitrate(quality: .mq, sampleRate: .hz44100), 303)
        XCTAssertEqual(LDACEncoder.nominalBitrate(quality: .sq, sampleRate: .hz88200), 606)
        XCTAssertEqual(LDACEncoder.nominalBitrate(quality: .mq, sampleRate: .hz48000), 330)
    }

    func testRejectsWrongBlockSize() throws {
        let enc = try LDACEncoder(sampleRate: .hz44100, quality: .sq)
        let short = [Float](repeating: 0, count: 200) // 100 frames
        XCTAssertThrowsError(try short.withUnsafeBufferPointer { try enc.encode($0) })
    }

    func testSamplesPerFrameAndAvdtpBits() throws {
        XCTAssertEqual(try LDACEncoder(sampleRate: .hz44100, quality: .hq).samplesPerFrame, 128)
        XCTAssertEqual(try LDACEncoder(sampleRate: .hz88200, quality: .hq).samplesPerFrame, 256)
        XCTAssertEqual(try LDACEncoder(sampleRate: .hz96000, quality: .hq).samplesPerFrame, 256)
        XCTAssertEqual(LDACSampleRate.hz44100.avdtpBit, 0x20)
        XCTAssertEqual(LDACSampleRate.hz48000.avdtpBit, 0x10)
        XCTAssertEqual(LDACSampleRate.hz88200.avdtpBit, 0x08)
        XCTAssertEqual(LDACSampleRate.hz96000.avdtpBit, 0x04)
    }
}
