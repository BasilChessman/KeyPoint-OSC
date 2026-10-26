import Foundation
import Testing
@testable import KeyPointCore

@Suite struct OSCCodecTests {
    @Test func encodesSpecExample() {
        // From the OSC 1.0 spec: "/oscillator/4/frequency" ,f 440.0
        let data = OSCEncoder.encode(OSCMessage("/oscillator/4/frequency", [.float(440)]))
        let expected: [UInt8] = [
            0x2f, 0x6f, 0x73, 0x63, 0x69, 0x6c, 0x6c, 0x61, 0x74, 0x6f, 0x72, 0x2f,
            0x34, 0x2f, 0x66, 0x72, 0x65, 0x71, 0x75, 0x65, 0x6e, 0x63, 0x79, 0x00,
            0x2c, 0x66, 0x00, 0x00, 0x43, 0xdc, 0x00, 0x00,
        ]
        #expect([UInt8](data) == expected)
    }

    @Test func stringPaddingAlwaysIncludesTerminator() {
        // "/abc" is 4 bytes, so it needs a full 4 bytes of NUL padding.
        let data = OSCEncoder.encode(OSCMessage("/abc"))
        #expect(data.count == 12) // "/abc\0\0\0\0" + ",\0\0\0"
        #expect(data.count % 4 == 0)
    }

    @Test(arguments: [
        OSCMessage("/a"),
        OSCMessage("/oscpoint/goto/slide", [.int(5)]),
        OSCMessage("/x", [.int(-1), .float(1.5), .string("hi"), .bool(true), .bool(false), .null, .impulse]),
        OSCMessage("/x", [.int64(-9_000_000_000), .double(3.25), .timeTag(42)]),
        OSCMessage("/blob", [.blob(Data())]),
        OSCMessage("/blob", [.blob(Data([1])), .blob(Data([1, 2, 3, 4])), .blob(Data([1, 2, 3, 4, 5]))]),
        OSCMessage("/utf8", [.string("ünïcödé ✓")]),
    ])
    func roundTrips(_ message: OSCMessage) throws {
        let decoded = try OSCDecoder.decode(OSCEncoder.encode(message))
        #expect(decoded == .message(message))
    }

    @Test func blobCarriesUTF8Text() throws {
        let text = "Notes — ünïcödé ✓\rline 2"
        let msg = OSCMessage("/oscpoint/slideshow/notes-utf8", [.blob(Data(text.utf8))])
        let decoded = try OSCDecoder.decode(OSCEncoder.encode(msg))
        #expect(decoded.messages.first?.arguments.first?.textValue == text)
    }

    @Test func bundlesRoundTripAndFlatten() throws {
        let inner = OSCPacket.bundle(timeTag: 1, elements: [.message(OSCMessage("/c", [.int(3)]))])
        let packet = OSCPacket.bundle(timeTag: 1, elements: [
            .message(OSCMessage("/a", [.int(1)])),
            .message(OSCMessage("/b", [.string("two")])),
            inner,
        ])
        let decoded = try OSCDecoder.decode(OSCEncoder.encode(packet))
        #expect(decoded == packet)
        #expect(decoded.messages.map(\.address) == ["/a", "/b", "/c"])
    }

    @Test func rejectsTruncatedInput() {
        var data = OSCEncoder.encode(OSCMessage("/x", [.int(7)]))
        data.removeLast()
        #expect(throws: OSCDecodeError.truncated) { try OSCDecoder.decode(data) }
    }

    @Test func rejectsOversizedBundleElement() {
        var data = OSCEncoder.encode(OSCPacket.bundle(timeTag: 1, elements: [.message(OSCMessage("/a"))]))
        data[16..<20] = Data([0, 0, 1, 0]) // claim a 256-byte element
        #expect(throws: OSCDecodeError.truncated) { try OSCDecoder.decode(data) }
    }

    @Test func rejectsDeepNesting() {
        var packet = OSCPacket.message(OSCMessage("/a"))
        for _ in 0..<20 { packet = .bundle(timeTag: 1, elements: [packet]) }
        #expect(throws: OSCDecodeError.nestingTooDeep) { try OSCDecoder.decode(OSCEncoder.encode(packet)) }
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try OSCDecoder.decode(Data([0xff, 0x00, 0x00, 0x00])) }
        #expect(throws: (any Error).self) { try OSCDecoder.decode(Data()) }
    }

    @Test func messageWithoutTypeTagsHasNoArguments() throws {
        let data = Data("/old\0\0\0\0".utf8)
        #expect(try OSCDecoder.decode(data) == .message(OSCMessage("/old")))
    }

    @Test func numericCoercions() {
        #expect(OSCArgument.float(4.6).intValue == 5)
        #expect(OSCArgument.string(" 12 ").intValue == 12)
        #expect(OSCArgument.double(.nan).intValue == nil)
        #expect(OSCArgument.int(3).doubleValue == 3)
        #expect(OSCArgument.blob(Data("abc".utf8)).textValue == "abc")
    }

    @Test func asciiFallback() {
        #expect("Café ✓".oscASCII == "Caf? ?")
    }
}
