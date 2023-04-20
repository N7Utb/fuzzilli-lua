import Foundation
public final class Program {
    /// The immutable code of this program.
    public let code: Code

    /// The parent program that was used to construct this program.
    /// This is mostly only used when inspection mode is enabled to reconstruct
    /// the "history" of a program.
    public private(set) var parent: Program? = nil

    /// Comments attached to this program.
    public var comments = ProgramComments()

    /// Everything that contributed to this program. This is not preserved across protobuf serialization.
    public var contributors = Contributors()

    /// Each program has a unique ID to identify it even accross different fuzzer instances.
    public private(set) lazy var id = UUID()
    
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

    /// Construct a program with the given code and type information.
    public convenience init(code: Code, parent: Program? = nil, comments: ProgramComments = ProgramComments(), contributors: Contributors = Contributors()) {
        self.init(with: code)
        self.comments = comments
        self.contributors = contributors
        self.parent = parent
    }
    /// The number of instructions in this program.
    public var size: Int {
        return code.count
    }

    /// Indicates whether this program is empty.
    public var isEmpty: Bool {
        return size == 0
    }

    public func clearParent() {
        parent = nil
    }


}