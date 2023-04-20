final class LoadNumber: Operation {
    override var opcode: Opcode { .loadNumber(self) }

    let value: Float64

    init(value: Float64) {
        self.value = value
        super.init(numOutputs: 1, attributes: [.isPure, .isMutable])
    }
}
final class LoadString: Operation {
    override var opcode: Opcode { .loadString(self) }

    let value: String

    init(value: String) {
        self.value = value
        super.init(numOutputs: 1, attributes: [.isPure, .isMutable])
    }
}
final class LoadBoolean: Operation {
    override var opcode: Opcode { .loadBoolean(self) }

    let value: Bool

    init(value: Bool) {
        self.value = value
        super.init(numOutputs: 1, attributes: [.isPure, .isMutable])
    }
}
// The parameters of a FuzzIL subroutine.
public struct Parameters {
    /// The total number of parameters.
    private let numParameters: UInt32


    /// Whether the last parameter is a rest parameter.
    let hasRestParameter: Bool

    /// The total number of parameters. This is equivalent to the number of inner outputs produced from the parameters.
    var count: Int {
        return Int(numParameters)
    }
    init(count: Int, hasRestParameter: Bool = false) {
        self.numParameters = UInt32(count)
        self.hasRestParameter = hasRestParameter
    }
}

final class BeginFunction: Operation{
    override var opcode: Opcode { .beginFunction(self)}
    let parameters: Parameters
    init(parameters: Parameters, attributes: Operation.Attributes = .isBlockStart) {
        self.parameters = parameters
        super.init(numInputs: 0, 
                   numOutputs: 1, 
                   numInnerOutputs: parameters.count, 
                   attributes: attributes,
                   contextOpened: [.script, .subroutine])
    }
}

final class EndFunction: Operation {
    override var opcode: Opcode { .endFunction(self)}
    init(){
        super.init(attributes: [.isBlockEnd])
    }
}

public enum UnaryOperator: String, CaseIterable {
    case LogicalNot = "not"
    case Minus      = "-"
    case Length     = "#"
    static let strop :[UnaryOperator] = [.Length]
    static let numop: [UnaryOperator] = [.Minus]
    static let allop :[UnaryOperator] = [LogicalNot]
    var token: String {
        return self.rawValue.trimmingCharacters(in: [" "])
    }

    var reassignsInput: Bool {
        return false
    }

    var isPostfix: Bool {
        return false
    }
}

final class UnaryOperation: Operation {
    override var opcode: Opcode { .unaryOperation(self) }

    let op: UnaryOperator

    init(_ op: UnaryOperator) {
        self.op = op
        super.init(numInputs: 1, numOutputs: 1, attributes: [.isMutable])
    }
}

public enum BinaryOperator: String, CaseIterable {
    case Add      = "+"
    case Sub      = "-"
    case Mul      = "*"
    case Div      = "/"
    case Mod      = "%"
    case LogicAnd = "and"
    case LogicOr  = "or"
    case Exp      = "^"
    case Concat   = ".."
    case Divisible = "//"
    static let strop :[BinaryOperator] = [.Concat]
    static let numop :[BinaryOperator] = [.Add, .Sub, .Mul, .Div, .Mod, .Divisible]
    static let allop :[BinaryOperator] = [.LogicAnd, .LogicOr]
    var token: String {
        return self.rawValue
    }
}

final class BinaryOperation: Operation {
    override var opcode: Opcode { .binaryOperation(self) }

    let op: BinaryOperator

    init(_ op: BinaryOperator) {
        self.op = op
        super.init(numInputs: 2, numOutputs: 1, attributes: [.isMutable])
    }
}

// This array must be kept in sync with the Comparator Enum in operations.proto
public enum Comparator: String, CaseIterable {
    case equal              = "=="
    case notEqual           = "~="
    case lessThan           = "<"
    case lessThanOrEqual    = "<="
    case greaterThan        = ">"
    case greaterThanOrEqual = ">="
    static let allop :[Comparator] = [.equal, .notEqual]
    static let numop :[Comparator] = [.lessThan, lessThanOrEqual, greaterThan, .greaterThanOrEqual]
    static let strop :[Comparator] = [.lessThan, lessThanOrEqual, greaterThan, .greaterThanOrEqual]
    var token: String {
        return self.rawValue
    }
}

final class Compare: Operation {
    override var opcode: Opcode { .compare(self) }

    let op: Comparator

    init(_ comparator: Comparator) {
        self.op = comparator
        super.init(numInputs: 2, numOutputs: 1, attributes: [.isMutable])
    }
}


final class Return: Operation{
    override var opcode: Opcode { .return(self) }
    var hasReturnValue: Bool {
        return numInputs > 0
    }

    init(numInputs: Int) {
        super.init(numInputs: numInputs, attributes: [.isJump],requiredContext: [.script, .subroutine])
    }
}

final class LoadNil: Operation{
    override var opcode: Opcode { .loadNil(self)}
    init() {
        super.init(numOutputs: 1, attributes: [.isPure])
    }
}

final class CallFunction: Operation {
    override var opcode: Opcode{.callFunction(self)}
    var numArgument: Int{
        return numInputs - 1
    }
    var numReturns: Int{
        return numOutputs
    }
    init(numArguments: Int, numReturns: Int)
    {
        super.init(numInputs:numArguments + 1, numOutputs: numReturns, firstVariadicInput: 1, attributes: [.isVariadic, .isCall])
    }
}

/// Internal operations.
///
/// These can be used for internal fuzzer operations but will not appear in the corpus.
class LuaInternalOperation: Operation {
    init(numInputs: Int) {
        super.init(numInputs: numInputs, attributes: [.isInternal])
    }
}