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

final class LoadBuiltin: Operation {
    override var opcode: Opcode { .loadBuiltin(self) }

    let builtinName: String

    init(builtinName: String) {
        self.builtinName = builtinName
        super.init(numOutputs: 1, attributes: [.isMutable])
    }
}

final class BeginTable: Operation{
    override var opcode: Opcode { .beginTable(self) }

    init() {
        super.init(attributes: .isBlockStart, contextOpened: .objectLiteral)
    }
}

/// TODO: context class Definition
final class EndTable: Operation {
    override var opcode: Opcode { .endTable(self) }

    init() {
        super.init(numOutputs: 1, attributes: .isBlockEnd, requiredContext: .objectLiteral)
    }
}

final class TableAddProperty: Operation {
    override var opcode: Opcode { .tableAddProperty(self) }

    let propertyName: String

    var hasValue: Bool {
        return numInputs == 1
    }

    init(propertyName: String, hasValue: Bool) {
        self.propertyName = propertyName
        super.init(numInputs: hasValue ? 1 : 0, attributes: .isMutable, requiredContext: .objectLiteral)
    }
}

final class TableAddElement: Operation {
    override var opcode: Opcode { .tableAddElement(self) }

    let index: Int64

    init(index: Int64) {
        self.index = index
        super.init(numInputs: 1, attributes: .isMutable, requiredContext: .objectLiteral)
    }
}

// A method, for example `someMethod(a3, a4) {`
final class BeginTableMethod: Operation {
    override var opcode: Opcode { .beginTableMethod(self) }

    let methodName: String
    let parameters: Parameters

    init(methodName: String, parameters: Parameters) {
        self.methodName = methodName
        self.parameters = parameters
        // First inner output is the explicit |this| parameter
        super.init(numInnerOutputs: parameters.count, attributes: [.isBlockStart, .isMutable], requiredContext: .objectLiteral, contextOpened: [.script, .subroutine, .method])
    }
}

final class EndTableMethod: Operation {
    override var opcode: Opcode { .endTableMethod(self) }

    init() {
        super.init(attributes: [.isBlockEnd])
    }
}

final class GetProperty: Operation{
    override var opcode: Opcode { .getProperty(self) }

    let propertyName: String

    init(propertyName: String) {
        self.propertyName = propertyName
        super.init(numInputs: 1, numOutputs: 1, attributes: [.isMutable])
    }    
}

final class GetElement: Operation {
    override var opcode: Opcode { .getElement(self) }

    let index: Int64

    init(index: Int64) {
        self.index = index
        super.init(numInputs: 1, numOutputs: 1, attributes: [.isMutable])
    }
}

final class SetElement: Operation {
    override var opcode: Opcode { .setElement(self) }

    let index: Int64

    init(index: Int64) {
        self.index = index
        super.init(numInputs: 2, attributes: [.isMutable])
    }
}

final class UpdateElement: Operation {
    override var opcode: Opcode { .updateElement(self) }

    let index: Int64
    let op: BinaryOperator

    init(index: Int64, operator op: BinaryOperator) {
        self.index = index
        self.op = op
        super.init(numInputs: 2, attributes: [.isMutable])
    }
}

final class DeleteElement: Operation {
    override var opcode: Opcode { .deleteElement(self) }

    let index: Int64

    init(index: Int64) {
        self.index = index
        super.init(numInputs: 1, attributes: [.isMutable])
    }
}


final class SetProperty: Operation {
    override var opcode: Opcode { .setProperty(self) }

    let propertyName: String

    init(propertyName: String) {
        self.propertyName = propertyName
        super.init(numInputs: 2, attributes: [.isMutable])
    }
}

final class UpdateProperty: Operation {
    override var opcode: Opcode { .updateProperty(self) }

    let propertyName: String
    let op: BinaryOperator

    init(propertyName: String, operator op: BinaryOperator) {
        self.propertyName = propertyName
        self.op = op
        super.init(numInputs: 2, attributes: [.isMutable])
    }
}

final class DeleteProperty: Operation {
    override var opcode: Opcode { .deleteProperty(self) }

    let propertyName: String

    init(propertyName: String) {
        self.propertyName = propertyName
        super.init(numInputs: 1, attributes: [.isMutable])
    }
}


final class LoadPair: Operation {
    override var opcode: Opcode { .loadPair(self) }
    init() {
        super.init(numInputs: 1, numOutputs: 1, attributes: [.isMutable])
    }
}

// final class SetMetaTable: Operation{
//     override var opcode: Opcode {.setMetaTable(self) }
//     init() {
//         super.init(numInputs: 2)
//     }
// }

final class CallMethod: Operation {
    override var opcode: Opcode { .callMethod(self) }

    let methodName: String

    var numArguments: Int {
        return numInputs - 1
    }

    var numReturns: Int{
        return numOutputs
    }
    init(methodName: String, numArguments: Int, numReturns: Int) {
        self.methodName = methodName
        // reference object is the first input
        super.init(numInputs: numArguments + 1, numOutputs: numReturns, firstVariadicInput: 1, attributes: [.isMutable, .isVariadic, .isCall])
    }
}

final class CreateArray: Operation {
    override var opcode: Opcode { .createArray(self) }

    var numInitialValues: Int {
        return numInputs
    }

    init(numInitialValues: Int) {
        super.init(numInputs: numInitialValues, numOutputs: 1, firstVariadicInput: 0, attributes: [.isVariadic])
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
    static func chooseOperation(lhs: LuaType, rhs: LuaType) -> BinaryOperator{
        switch (lhs, rhs) {
        case (.number, .number):
            return chooseUniform(from: BinaryOperator.numop + BinaryOperator.allop)
        case (.string, .string):
            return chooseUniform(from: BinaryOperator.strop + BinaryOperator.allop)
        default:
            return chooseUniform(from: BinaryOperator.allop)
        }
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

/// Reassigns an existing variable, essentially doing `input1 = input2;`
final class Reassign: Operation {
    override var opcode: Opcode { .reassign(self) }

    init() {
        super.init(numInputs: 2)
    }
}

/// Updates a variable by applying a binary operation to it and another variable.
final class Update: Operation {
    override var opcode: Opcode { .update(self) }

    let op: BinaryOperator

    init(_ op: BinaryOperator) {
        self.op = op
        super.init(numInputs: 2)
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
    var numArguments: Int{
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

final class BeginIf: Operation{
    override var opcode: Opcode { .beginIf(self) }

    // If true, the condition for this if block will be negated.
    let inverted: Bool

    init(inverted: Bool) {
        self.inverted = inverted
        super.init(numInputs: 1, attributes: [.isBlockStart, .isMutable, .propagatesSurroundingContext], contextOpened: .script)
    }
}

final class BeginElse: Operation {
    override var opcode: Opcode { .beginElse(self) }

    init() {
        super.init(attributes: [.isBlockEnd, .isBlockStart, .propagatesSurroundingContext], contextOpened: .script)
    }
}

final class EndIf: Operation {
    override var opcode: Opcode { .endIf(self) }

    init() {
        super.init(attributes: .isBlockEnd)
    }
}

///
/// Loops.
///
/// Loops in FuzzIL generally have the following format:
///
///     BeginLoopHeader
///        v7 <- Compare v1, v2, '<'
///     BeginLoopBody <- v7
///        ...
///     EndLoop
///
/// Which would be lifted to something like
///
///     loop(v1 < v2) {
///       // body
///     }
///
/// As such, it is possible to perform arbitrary computations in the loop header, as it is in JavaScript.
/// JavaScript only allows a single expression inside a loop header. However, this is purely a syntactical
/// restriction, and can be overcome for example by declaring and invoking an arrow function in the
/// header if necessary:
///
///     BeginLoopHeader
///         foo
///     BeginLoopBody
///         ...
///     EndLoopBody
///
/// Can be lifted to
///
///     loop((() => { foo })()) {
///         // body
///     }
///
/// For simpler cases that only involve expressions, the header can also be lifted to
///
///     loop(foo(), bar(), baz()) {
///         // body
///     }
///

final class BeginWhileLoopHeader: Operation {
    override var opcode: Opcode { .beginWhileLoopHeader(self) }

    init() {
        super.init(attributes: [.isBlockStart, .propagatesSurroundingContext], contextOpened: .script)
    }
}

// The input is the loop condition. This also prevents empty loop headers which are forbidden by the language.
final class BeginWhileLoopBody: Operation {
    override var opcode: Opcode { .beginWhileLoopBody(self) }

    init() {
        super.init(numInputs: 1, attributes: [.isBlockStart, .isBlockEnd, .propagatesSurroundingContext], contextOpened: [.script, .loop])
    }
}

final class EndWhileLoop: Operation {
    override var opcode: Opcode { .endWhileLoop(self) }

    init() {
        super.init(attributes: .isBlockEnd)
    }
}
///
/// For loops.
///
/// For loops have the following shape:
///
///     BeginForLoopInitializer
///         // ...
///         // v0 = initial value of the (single) loop variable
///     BeginForLoopCondition v0 -> v1
///         // v1 = current value of the (single) loop variable
///         // ...
///     BeginForLoopAfterthought -> v2
///         // v2 = current value of the (single) loop variable
///         // ...
///     BeginForLoopBody -> v3
///         // v3 = current value of the (single) loop variable
///         // ...
///     EndForLoop
///
/// This would be lifted to:
///
///     for (let vX = init; cond; afterthought) {
///         body
///     }
///
/// This format allows arbitrary computations to be performed in every part of the loop header. It also
/// allows zero, one, or multiple loop variables to be declared, which correspond to the inner outputs
/// of the blocks. During lifting, all the inner outputs are expected to lift to the same identifier (vX in
/// the example above).
/// Similar to while- and do-while loops, the code in the header blocks may be lifted to arrow functions
/// if it requires more than one expression.
///
final class BeginForLoopInitializer: Operation {
    override var opcode: Opcode { .beginForLoopInitializer(self) }

    init() {
        super.init(attributes: [.isBlockStart, .propagatesSurroundingContext], contextOpened: .script)
    }
}

final class BeginForLoopCondition: Operation {
    override var opcode: Opcode { .beginForLoopCondition(self) }

    init() {
        super.init(numInputs: 1, numInnerOutputs: 1, attributes: [.isBlockStart, .isBlockEnd, .propagatesSurroundingContext], contextOpened: .script)
    }
}

final class BeginForLoopAfterthought: Operation {
    override var opcode: Opcode { .beginForLoopAfterthought(self) }

    init() {
        super.init(numInputs: 1, numInnerOutputs: 1, attributes: [.isBlockStart, .isBlockEnd, .propagatesSurroundingContext], contextOpened: .script)
    }
}

final class BeginForLoopBody: Operation {
    override var opcode: Opcode { .beginForLoopBody(self) }

    init(numInputs: Int) {
        super.init(numInputs: numInputs, numInnerOutputs: 1, attributes: [.isBlockStart, .isBlockEnd, .propagatesSurroundingContext], contextOpened: [.script, .loop])
    }
}

final class EndForLoop: Operation {
    override var opcode: Opcode { .endForLoop(self) }

    init() {
        super.init(attributes: .isBlockEnd)
    }
}

final class BeginForInLoop: Operation {
    override var opcode: Opcode { .beginForInLoop(self) }

    init(numInnerOutputs: Int) {
        super.init(numInputs: 1, numInnerOutputs: numInnerOutputs, attributes: [.isBlockStart, .propagatesSurroundingContext], contextOpened: [.script, .loop])
    }
}

final class EndForInLoop: Operation {
    override var opcode: Opcode { .endForInLoop(self) }

    init() {
        super.init(attributes: .isBlockEnd)
    }
}

// A loop that simply runs N times and is therefore always guaranteed to terminate.
// Useful for example to force JIT compilation without creating more complex loops, which can often quickly end up turning into infinite loops due to mutations.
// These could be lifted simply as `for (let i = 0; i < N; i++) { body() }`
final class BeginRepeatLoop: Operation {
    override var opcode: Opcode { .beginRepeatLoop(self) }

    let iterations: Int

    // Whether the current iteration number is exposed as an inner output variable.
    var exposesLoopCounter: Bool {
        assert(numInnerOutputs == 0 || numInnerOutputs == 1)
        return numInnerOutputs == 1
    }

    init(iterations: Int, exposesLoopCounter: Bool = true) {
        self.iterations = iterations
        super.init(numInnerOutputs: exposesLoopCounter ? 1 : 0, attributes: [.isBlockStart, .propagatesSurroundingContext], contextOpened: [.script, .loop])
    }
}

final class EndRepeatLoop: Operation {
    override var opcode: Opcode { .endRepeatLoop(self) }

    init() {
        super.init(attributes: .isBlockEnd)
    }
}


final class LoopBreak: Operation {
    override var opcode: Opcode { .loopBreak(self) }

    init() {
        super.init(attributes: [.isJump], requiredContext: [.script, .loop])
    }
}

final class Label: Operation{
    override var opcode: Opcode { .label(self) }
    let value: String
    init(_ name: String) {
        value = name
        super.init( requiredContext: [.script])
    }
}

final class Goto: Operation{
    override var opcode: Opcode { .goto(self) }
    let value: String
    init(_ name: String) {
        value = name
        super.init(attributes: [.isJump], requiredContext: [.script])
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

/// Turn the input value into a probe that records the actions performed on it.
/// Used by the ProbingMutator.
// final class Probe: LuaInternalOperation {
//     override var opcode: Opcode { .probe(self) }

//     let id: String

//     init(id: String) {
//         self.id = id
//         super.init(numInputs: 1)
//     }
// }
