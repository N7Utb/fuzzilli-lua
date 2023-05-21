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

extension Program: ProtobufConvertible {
    public typealias ProtobufType = FuzzilliLua_Protobuf_Program

    func asProtobuf(opCache: OperationCache? = nil) -> ProtobufType {
        return ProtobufType.with {
            $0.uuid = id.uuidData
            $0.code = code.map({ $0.asProtobuf(with: opCache) })

            if !comments.isEmpty {
                $0.comments = comments.asProtobuf()
            }

            if let parent = parent {
                $0.parent = parent.asProtobuf(opCache: opCache)
            }
        }
    }

    public func asProtobuf() -> ProtobufType {
        return asProtobuf(opCache: nil)
    }

    convenience init(from proto: ProtobufType, opCache: OperationCache? = nil) throws {
        var code = Code()
        for (i, protoInstr) in proto.code.enumerated() {
            do {
                code.append(try Instruction(from: protoInstr, with: opCache))
            } catch FuzzilliError.instructionDecodingError(let reason) {
                throw FuzzilliError.programDecodingError("could not decode instruction #\(i): \(reason)")
            }
        }

        do {
            try code.check()
        } catch FuzzilliError.codeVerificationError(let reason) {
            throw FuzzilliError.programDecodingError("decoded code is not statically valid: \(reason)")
        }

        self.init(code: code)

        if let uuid = UUID(uuidData: proto.uuid) {
            self.id = uuid
        }

        self.comments = ProgramComments(from: proto.comments)

        if proto.hasParent {
            self.parent = try Program(from: proto.parent, opCache: opCache)
        }
    }

    public convenience init(from proto: ProtobufType) throws {
        try self.init(from: proto, opCache: nil)
    }
}
