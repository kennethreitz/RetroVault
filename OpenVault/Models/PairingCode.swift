import Foundation

/// A short-lived RomM client-token pairing code.
struct PairingCode: Equatable, Sendable {
    let value: String

    init(_ input: String) throws {
        let isValid = input.count == 8
            && input.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber)
            }

        guard isValid else {
            throw PairingCodeError.invalid
        }

        value = input
    }
}

enum PairingCodeError: LocalizedError, Equatable {
    case invalid

    var errorDescription: String? {
        "Enter the eight-character pairing code shown by RomM."
    }
}
