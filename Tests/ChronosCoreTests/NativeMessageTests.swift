import ChronosCore
import Foundation
import Testing

struct NativeMessageTests {
    @Test func aFramedMessageReadsBack() {
        var buffer = NativeMessage.frame(#"{"domain":"github.com"}"#)

        #expect(NativeMessage.next(from: &buffer) == #"{"domain":"github.com"}"#)
        #expect(buffer.isEmpty)
    }

    @Test func theLengthComesFirstInTheMachinesByteOrder() {
        let data = NativeMessage.frame("{}")

        #expect(Array(data) == [2, 0, 0, 0, UInt8(ascii: "{"), UInt8(ascii: "}")])
    }

    @Test func waitsForAWholeMessage() {
        let whole = NativeMessage.frame(#"{"domain":"github.com"}"#)
        var buffer = whole.prefix(10)

        #expect(NativeMessage.next(from: &buffer) == nil)
        buffer.append(whole.dropFirst(10))
        #expect(NativeMessage.next(from: &buffer) == #"{"domain":"github.com"}"#)
    }

    @Test func readsMessagesOneAtATime() {
        var buffer = NativeMessage.frame(#"{"domain":"a.com"}"#) + NativeMessage.frame(#"{"domain":"b.com"}"#)

        #expect(NativeMessage.next(from: &buffer) == #"{"domain":"a.com"}"#)
        #expect(NativeMessage.next(from: &buffer) == #"{"domain":"b.com"}"#)
        #expect(NativeMessage.next(from: &buffer) == nil)
    }

    @Test func dropsAStreamClaimingAnImpossibleLength() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0x7F]) + Data("garbage".utf8)

        #expect(NativeMessage.next(from: &buffer) == nil)
        #expect(buffer.isEmpty)
    }
}
