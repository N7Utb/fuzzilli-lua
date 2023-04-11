import Foundation
public final class Program {
    /// The immutable code of this program.
    public let code: Code


    /// The parent program that was used to construct this program.
    /// This is mostly only used when inspection mode is enabled to reconstruct
    /// the "history" of a program.
    public private(set) var parent: Program? = nil

    /// Constructs an empty program.
    public init() {
        self.code = Code()
        self.parent = nil
    }

    /// Constructs a program with the given code. The code must be statically valid.
    public init(with code: Code) {
        assert(code.isStaticallyValid())
        self.code = code
    }
}