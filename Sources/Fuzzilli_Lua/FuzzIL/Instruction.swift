// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// The building blocks of FuzzIL code.
///
/// An instruction is an operation together with in- and output variables.
public struct Instruction {
    /// The operation performed by this instruction.
    public let op: Operation

    /// The input and output variables of this instruction.
    ///
    /// Format:
    ///      First numInputs Variables: inputs
    ///      Next numOutputs Variables: outputs visible in the outer scope
    ///      Next numInnerOutputs Variables: outputs only visible in the inner scope created by this instruction
    ///      Final value, if present: the index of this instruction in the code object it belongs to
    private let inouts_: [Variable]


    /// The number of input variables of this instruction.
    public var numInputs: Int {
        return op.numInputs
    }

    /// The number of output variables of this instruction.
    public var numOutputs: Int {
        return op.numOutputs
    }

    /// The number of output variables of this instruction that are visible in the inner scope (if this is a block begin).
    public var numInnerOutputs: Int {
        return op.numInnerOutputs
    }

    /// The total number of inputs and outputs of this instruction.
    public var numInouts: Int {
        return numInputs + numOutputs + numInnerOutputs
    }

    /// Whether this instruction has any inputs.
    public var hasInputs: Bool {
        return numInputs > 0
    }

    /// Returns the ith input variable.
    public func input(_ i: Int) -> Variable {
        assert(i < numInputs)
        return inouts_[i]
    }

    /// The input variables of this instruction.
    public var inputs: ArraySlice<Variable> {
        return inouts_[..<numInputs]
    }

    /// All variadic inputs of this instruction.
    public var variadicInputs: ArraySlice<Variable> {
        return inouts_[firstVariadicInput..<numInputs]
    }

    /// The index of the first variadic input of this instruction.
    public var firstVariadicInput: Int {
        return op.firstVariadicInput
    }

    /// Whether this instruction has any variadic inputs.
    public var hasAnyVariadicInputs: Bool {
        return firstVariadicInput < numInputs
    }

    /// Whether this instruction has any outputs.
    public var hasOutputs: Bool {
        return numOutputs + numInnerOutputs > 0
    }

    /// Whether this instruction has exaclty one output.
    public var hasOneOutput: Bool {
        return numOutputs == 1
    }

    /// Convenience getter for simple operations that produce a single output variable.
    public var output: Variable {
        assert(hasOneOutput)
        return inouts_[numInputs]
    }

    /// Convenience getter for simple operations that produce a single inner output variable.
    public var innerOutput: Variable {
        assert(numInnerOutputs == 1)
        return inouts_[numInputs + numOutputs]
    }

    /// The output variables of this instruction in the surrounding scope.
    public var outputs: ArraySlice<Variable> {
        return inouts_[numInputs ..< numInputs + numOutputs]
    }

    /// The output variables of this instruction that are only visible in the inner scope.
    public var innerOutputs: ArraySlice<Variable> {
        return inouts_[numInputs + numOutputs ..< numInouts]
    }

    public func innerOutput(_ i: Int) -> Variable {
        return inouts_[numInputs + numOutputs + i]
    }

    public func innerOutputs(_ r: PartialRangeFrom<Int>) -> ArraySlice<Variable> {
        return inouts_[numInputs + numOutputs + r.lowerBound ..< numInouts]
    }

    /// The inner and outer output variables of this instruction combined.
    public var allOutputs: ArraySlice<Variable> {
        return inouts_[numInputs ..< numInouts]
    }

    /// All inputs and outputs of this instruction combined.
    public var inouts: ArraySlice<Variable> {
        return inouts_[..<numInouts]
    }

    /// Whether this instruction contains its index in the code it belongs to.
    public var hasIndex: Bool {
        // If the index is present, it is the last value in inouts. See comment in index getter.
        return inouts_.count == numInouts + 1
    }

    /// The index of this instruction in the Code it belongs to.
    public var index: Int {
        // We store the index in the internal inouts array for memory efficiency reasons.
        // In practice, this does not limit the size of programs/code since that's already
        // limited by the fact that variables are UInt16 internally.
        assert(hasIndex)
        return Int(inouts_.last!.number)
    }

    ///
    /// Flag accessors.
    ///

    /// A pure operation returns the same value given the same inputs and has no side effects.
    public var isPure: Bool {
        return op.attributes.contains(.isPure)
    }

    /// True if the operation of this instruction be mutated in a meaningful way.
    /// An instruction with inputs is always mutable. This only indicates whether the operation can be mutated.
    /// See Operation.Attributes.isMutable
    public var isOperationMutable: Bool {
        return op.attributes.contains(.isMutable)
    }

    /// A simple instruction is not a block instruction.
    public var isSimple: Bool {
        return !isBlock
    }

    /// An instruction that performs a procedure call.
    /// See Operation.Attributes.isCall
    public var isCall: Bool {
        return op.attributes.contains(.isCall)
    }

    /// An operation is variadic if it can have a variable number of inputs.
    /// See Operation.Attributes.isVariadic
    public var isVariadic: Bool {
        return op.attributes.contains(.isVariadic)
    }

    /// A block instruction is part of a block in the program.
    public var isBlock: Bool {
        return isBlockStart || isBlockEnd
    }

    /// Whether this instruction is the start of a block.
    /// See Operation.Attributes.isBlockStart.
    public var isBlockStart: Bool {
        return op.attributes.contains(.isBlockStart)
    }

    /// Whether this instruction is the end of a block.
    /// See Operation.Attributes.isBlockEnd.
    public var isBlockEnd: Bool {
        return op.attributes.contains(.isBlockEnd)
    }

    /// Whether this instruction is the start of a block group (so a block start but not a block end).
    public var isBlockGroupStart: Bool {
        return isBlockStart && !isBlockEnd
    }

    /// Whether this instruction is the end of a block group (so a block end but not also a block start).
    public var isBlockGroupEnd: Bool {
        return isBlockEnd && !isBlockStart
    }

    /// Whether this instruction is a jump.
    /// See See Operation.Attributes.isJump.
    public var isJump: Bool {
        return op.attributes.contains(.isJump)
    }

    /// Whether this block start instruction propagates the outer context into the newly started block.
    /// See Operation.Attributes.propagatesSurroundingContext.
    public var propagatesSurroundingContext: Bool {
        assert(isBlockStart)
        return op.attributes.contains(.propagatesSurroundingContext)
    }

    /// Whether this instruction skips the last context and resumes the
    /// ContextAnalysis from the second last context stack, this is useful for
    /// BeginSwitch/EndSwitch Blocks. See BeginSwitchCase.
    public var skipsSurroundingContext: Bool {
        assert(isBlockStart)
        return op.attributes.contains(.resumesSurroundingContext)
    }

    /// Whether this instruction is an internal instruction that should not "leak" into
    /// the corpus or generally out of the component that generated it.
    public var isInternal: Bool {
        return op.attributes.contains(.isInternal)
    }


    public init<Variables: Collection>(_ op: Operation, inouts: Variables, index: Int? = nil) where Variables.Element == Variable {
        assert(op.numInputs + op.numOutputs + op.numInnerOutputs == inouts.count)
        self.op = op
        var inouts_ = Array(inouts)
        if let idx = index {
            inouts_.append(Variable(number: idx))
        }
        self.inouts_ = inouts_
    }

    public init(_ op: Operation, output: Variable) {
        assert(op.numInputs == 0 && op.numOutputs == 1 && op.numInnerOutputs == 0)
        self.init(op, inouts: [output])
    }

    public init(_ op: Operation, output: Variable, inputs: [Variable]) {
        assert(op.numOutputs == 1)
        assert(op.numInnerOutputs == 0)
        assert(op.numInputs == inputs.count)
        self.init(op, inouts: inputs + [output])
    }

    public init(_ op: Operation, inputs: [Variable]) {
        assert(op.numOutputs + op.numInnerOutputs == 0)
        assert(op.numInputs == inputs.count)
        self.init(op, inouts: inputs)
    }

    public init(_ op: Operation, innerOutput: Variable) {
        assert(op.numInnerOutputs == 1)
        assert(op.numOutputs == 0)
        assert(op.numInputs == 0)
        self.init(op, inouts: [innerOutput])
    }

    public init(_ op: Operation) {
        assert(op.numOutputs + op.numInnerOutputs == 0)
        assert(op.numInputs == 0)
        self.init(op, inouts: [])
    }
}

// Protobuf support.
//
// The protobuf conversion for operations is implemented here. The main reason for
// that is that operations cannot generally be decoded without knowledge of the
// instruction they occur in, as the number of in/outputs is only encoded once,
// in the instruction. For example, the CreateArray protobuf does not contain the
// number of initial array elements - that infomation is only captured once, in the
// inouts of the owning instruction.
extension Instruction: ProtobufConvertible {
    typealias ProtobufType = FuzzilliLua_Protobuf_Instruction

    func asProtobuf(with opCache: OperationCache?) -> ProtobufType {
        func convertEnum<S: Equatable, P: RawRepresentable>(_ s: S, _ allValues: [S]) -> P where P.RawValue == Int {
            return P(rawValue: allValues.firstIndex(of: s)!)!
        }

        func convertParameters(_ parameters: Parameters) -> FuzzilliLua_Protobuf_Parameters {
            return FuzzilliLua_Protobuf_Parameters.with {
                $0.count = UInt32(parameters.count)
                $0.hasRest_p = parameters.hasRestParameter
            }
        }

        let result = ProtobufType.with {
            $0.inouts = inouts.map({ UInt32($0.number) })
            $0.numinputs = UInt32(inputs.count)
            $0.numoutputs = UInt32(outputs.count)
            $0.numinneroutputs = UInt32(innerOutputs.count)
            // First see if we can use the cache.
            if let idx = opCache?.get(op) {
                $0.opIdx = UInt32(idx)
                return
            }

            // Otherwise, encode the operation.
            switch op.opcode {
            case .nop:
                $0.nop = FuzzilliLua_Protobuf_Nop()
            case .loadNumber(let op):
                $0.loadNumber = FuzzilliLua_Protobuf_LoadNumber.with { $0.value = op.value }
            case .loadString(let op):
                $0.loadString = FuzzilliLua_Protobuf_LoadString.with { $0.value = op.value }
            case .loadBoolean(let op):
                $0.loadBoolean = FuzzilliLua_Protobuf_LoadBoolean.with { $0.value = op.value }
            case .loadNil:
                $0.loadNil = FuzzilliLua_Protobuf_LoadNil()
            case .beginTable:
                $0.beginTable = FuzzilliLua_Protobuf_BeginTable()
            case .tableAddProperty(let op):
                $0.tableAddProperty = FuzzilliLua_Protobuf_TableAddProperty.with { $0.propertyName = op.propertyName; $0.hasValue_p = op.hasValue}
            case .tableAddElement(let op):
                $0.tableAddElement = FuzzilliLua_Protobuf_TableAddElement.with { $0.index = op.index }
            case .beginTableMethod(let op):
                $0.beginTableMethod = FuzzilliLua_Protobuf_BeginTableMethod.with {
                    $0.methodName = op.methodName
                    $0.parameters = convertParameters(op.parameters)
                }
            case .endTableMethod:
                $0.endTableMethod = FuzzilliLua_Protobuf_EndTableMethod()
            case .endTable:
                $0.endTable = FuzzilliLua_Protobuf_EndTable()
            case .createArray:
                $0.createArray = FuzzilliLua_Protobuf_CreateArray()
            case .loadBuiltin(let op):
                $0.loadBuiltin = FuzzilliLua_Protobuf_LoadBuiltin.with { $0.builtinName = op.builtinName }
            case .getProperty(let op):
                $0.getProperty = FuzzilliLua_Protobuf_GetProperty.with {
                    $0.propertyName = op.propertyName
                }
            case .setProperty(let op):
                $0.setProperty = FuzzilliLua_Protobuf_SetProperty.with { $0.propertyName = op.propertyName }
            case .updateProperty(let op):
                $0.updateProperty = FuzzilliLua_Protobuf_UpdateProperty.with {
                    $0.propertyName = op.propertyName
                    $0.op = convertEnum(op.op, BinaryOperator.allCases)
                }
            case .deleteProperty(let op):
                $0.deleteProperty = FuzzilliLua_Protobuf_DeleteProperty.with {
                    $0.propertyName = op.propertyName
                }
            case .getElement(let op):
                $0.getElement = FuzzilliLua_Protobuf_GetElement.with {
                    $0.index = op.index
                }
            case .setElement(let op):
                $0.setElement = FuzzilliLua_Protobuf_SetElement.with { $0.index = op.index }
            case .updateElement(let op):
                $0.updateElement = FuzzilliLua_Protobuf_UpdateElement.with {
                    $0.index = op.index
                    $0.op = convertEnum(op.op, BinaryOperator.allCases)
                }
            case .deleteElement(let op):
                $0.deleteElement = FuzzilliLua_Protobuf_DeleteElement.with {
                    $0.index = op.index
                }

            case .beginFunction(let op):
                $0.beginFunction = FuzzilliLua_Protobuf_BeginFunction.with {
                    $0.parameters = convertParameters(op.parameters)
                }
            case .endFunction:
                $0.endFunction = FuzzilliLua_Protobuf_EndFunction()
            case .return:
                $0.return = FuzzilliLua_Protobuf_Return()
            case .callFunction:
                $0.callFunction = FuzzilliLua_Protobuf_CallFunction()
            case .callMethod(let op):
                $0.callMethod = FuzzilliLua_Protobuf_CallMethod.with {
                    $0.methodName = op.methodName
                }
            case .unaryOperation(let op):
                $0.unaryOperation = FuzzilliLua_Protobuf_UnaryOperation.with { $0.op = convertEnum(op.op, UnaryOperator.allCases) }
            case .binaryOperation(let op):
                $0.binaryOperation = FuzzilliLua_Protobuf_BinaryOperation.with { $0.op = convertEnum(op.op, BinaryOperator.allCases) }
            case .reassign:
                $0.reassign = FuzzilliLua_Protobuf_Reassign()
            case .update(let op):
                $0.update = FuzzilliLua_Protobuf_Update.with { $0.op = convertEnum(op.op, BinaryOperator.allCases) }
            case .compare(let op):
                $0.compare = FuzzilliLua_Protobuf_Compare.with { $0.op = convertEnum(op.op, Comparator.allCases) }
            case .beginIf(let op):
                $0.beginIf = FuzzilliLua_Protobuf_BeginIf.with {
                    $0.inverted = op.inverted
                }
            case .beginElse:
                $0.beginElse = FuzzilliLua_Protobuf_BeginElse()
            case .endIf:
                $0.endIf = FuzzilliLua_Protobuf_EndIf()
            case .beginWhileLoopHeader:
                $0.beginWhileLoopHeader = FuzzilliLua_Protobuf_BeginWhileLoopHeader()
            case .beginWhileLoopBody:
                $0.beginWhileLoopBody = FuzzilliLua_Protobuf_BeginWhileLoopBody()
            case .endWhileLoop:
                $0.endWhileLoop = FuzzilliLua_Protobuf_EndWhileLoop()
            case .beginForLoopInitializer:
                $0.beginForLoopInitializer = FuzzilliLua_Protobuf_BeginForLoopInitializer()
            case .beginForLoopCondition:
                $0.beginForLoopCondition = FuzzilliLua_Protobuf_BeginForLoopCondition()
            case .beginForLoopAfterthought:
                $0.beginForLoopAfterthought = FuzzilliLua_Protobuf_BeginForLoopAfterthought()
            case .beginForLoopBody:
                $0.beginForLoopBody = FuzzilliLua_Protobuf_BeginForLoopBody()
            case .endForLoop:
                $0.endForLoop = FuzzilliLua_Protobuf_EndForLoop()
            case .beginForInLoop:
                $0.beginForInLoop = FuzzilliLua_Protobuf_BeginForInLoop()
            case .endForInLoop:
                $0.endForInLoop = FuzzilliLua_Protobuf_EndForInLoop()
            case .beginRepeatLoop(let op):
                $0.beginRepeatLoop = FuzzilliLua_Protobuf_BeginRepeatLoop.with {
                    $0.iterations = Int64(op.iterations)
                    $0.exposesLoopCounter = op.exposesLoopCounter
                }
            case .endRepeatLoop:
                $0.endRepeatLoop = FuzzilliLua_Protobuf_EndRepeatLoop()
            case .loopBreak:
                $0.loopBreak = FuzzilliLua_Protobuf_LoopBreak()
            case .label(let op):
                $0.label = FuzzilliLua_Protobuf_Label.with{$0.labelname = op.value}
            case .goto(let op):
                $0.goto = FuzzilliLua_Protobuf_Goto.with{$0.labelname = op.value}
            case .loadPair(_):
                $0.loadPair = FuzzilliLua_Protobuf_LoadPair()
}
        }

        opCache?.add(op)
        return result
    }

    func asProtobuf() -> ProtobufType {
        return asProtobuf(with: nil)
    }

    init(from proto: ProtobufType, with opCache: OperationCache?) throws {
        guard proto.inouts.allSatisfy({ Variable.isValidVariableNumber(Int(clamping: $0)) }) else {
            throw FuzzilliError.instructionDecodingError("invalid variables in instruction")
        }
        let inouts = proto.inouts.map({ Variable(number: Int($0)) })
        let numinputs = Int(proto.numinputs)
        let numoutputs = Int(proto.numoutputs)
        let numinneroutputs = Int(proto.numinneroutputs)
        // Helper function to convert between the Swift and Protobuf enums.
        func convertEnum<S: Equatable, P: RawRepresentable>(_ p: P, _ allValues: [S]) throws -> S where P.RawValue == Int {
            guard allValues.indices.contains(p.rawValue) else {
                throw FuzzilliError.instructionDecodingError("invalid enum value \(p.rawValue) for type \(S.self)")
            }
            return allValues[p.rawValue]
        }

        func convertParameters(_ parameters: FuzzilliLua_Protobuf_Parameters) -> Parameters {
            return Parameters(count: Int(parameters.count), hasRestParameter: parameters.hasRest_p)
        }

        guard let operation = proto.operation else {
            throw FuzzilliError.instructionDecodingError("missing operation for instruction")
        }

        let op: Operation
        switch operation {
        case .opIdx(let idx):
            guard let cachedOp = opCache?.get(Int(idx)) else {
                throw FuzzilliError.instructionDecodingError("invalid operation index or no decoding context available")
            }
            op = cachedOp
        case .loadNumber(let p):
            op = LoadNumber(value: p.value)
        case .loadString(let p):
            op = LoadString(value: p.value)
        case .loadBoolean(let p):
            op = LoadBoolean(value: p.value)
        case .loadNil(_): 
            op = LoadNil()
        case .loadPair(_): 
            op = LoadPair()
        case .beginTable:
            op = BeginTable()
        case .tableAddProperty(let p):
            op = TableAddProperty(propertyName: p.propertyName, hasValue: p.hasValue_p)
        case .tableAddElement(let p):
            op = TableAddElement(index: p.index)
        case .beginTableMethod(let p):
            op = BeginTableMethod(methodName: p.methodName, parameters: convertParameters(p.parameters))
        case .endTableMethod:
            op = EndTableMethod()
        case .endTable:
            op = EndTable()
        case .createArray:
            op = CreateArray(numInitialValues: inouts.count - 1)
        case .loadBuiltin(let p):
            op = LoadBuiltin(builtinName: p.builtinName)
        case .getProperty(let p):
            op = GetProperty(propertyName: p.propertyName)
        case .setProperty(let p):
            op = SetProperty(propertyName: p.propertyName)
        case .updateProperty(let p):
            op = UpdateProperty(propertyName: p.propertyName, operator: try convertEnum(p.op, BinaryOperator.allCases))
        case .deleteProperty(let p):
            op = DeleteProperty(propertyName: p.propertyName)
        case .getElement(let p):
            op = GetElement(index: p.index)
        case .setElement(let p):
            op = SetElement(index: p.index)
        case .updateElement(let p):
            op = UpdateElement(index: p.index, operator: try convertEnum(p.op, BinaryOperator.allCases))
        case .deleteElement(let p):
            op = DeleteElement(index: p.index)

        case .beginFunction(let p):
            let parameters = convertParameters(p.parameters)
            op = BeginFunction(parameters: parameters)
        case .endFunction:
            op = EndFunction()
        case .return:
            op = Return(numInputs: numinputs)
        case .callFunction:
            op = CallFunction(numArguments: numinputs - 1, numReturns: numoutputs)
        case .callMethod(let p):
            op = CallMethod(methodName: p.methodName, numArguments: numinputs - 1, numReturns: numoutputs)
        case .unaryOperation(let p):
            op = UnaryOperation(try convertEnum(p.op, UnaryOperator.allCases))
        case .binaryOperation(let p):
            op = BinaryOperation(try convertEnum(p.op, BinaryOperator.allCases))
        case .update(let p):
            op = Update(try convertEnum(p.op, BinaryOperator.allCases))
        case .reassign:
            op = Reassign()
        case .compare(let p):
            op = Compare(try convertEnum(p.op, Comparator.allCases))
        case .beginIf(let p):
            op = BeginIf(inverted: p.inverted)
        case .beginElse:
            op = BeginElse()
        case .endIf:
            op = EndIf()
        case .beginWhileLoopHeader:
            op = BeginWhileLoopHeader()
        case .beginWhileLoopBody:
            op = BeginWhileLoopBody()
        case .endWhileLoop:
            op = EndWhileLoop()
        case .beginForLoopInitializer:
            op = BeginForLoopInitializer()
        case .beginForLoopCondition:
            assert(inouts.count % 2 == 0)
            op = BeginForLoopCondition()
        case .beginForLoopAfterthought:
            // First input is the condition
            op = BeginForLoopAfterthought()
        case .beginForLoopBody:
            op = BeginForLoopBody(numInputs: numinputs)
        case .endForLoop:
            op = EndForLoop()
        case .beginForInLoop:
            op = BeginForInLoop(numInnerOutputs: numinneroutputs)
        case .endForInLoop:
            op = EndForInLoop()
        case .beginRepeatLoop(let p):
            op = BeginRepeatLoop(iterations: Int(p.iterations), exposesLoopCounter: p.exposesLoopCounter)
        case .endRepeatLoop:
            op = EndRepeatLoop()
        case .loopBreak:
            op = LoopBreak()

        case .nop:
            op = Nop()
        case .goto(let p):
            op = Goto(p.labelname)
        case .label(let p): 
            op = Label(p.labelname)
        
       
        }

        guard op.numInputs + op.numOutputs + op.numInnerOutputs == inouts.count else {
            throw FuzzilliError.instructionDecodingError("incorrect number of in- and outputs of \(op)")
        }

        opCache?.add(op)

        self.init(op, inouts: inouts)
    }

    init(from proto: ProtobufType) throws {
        try self.init(from: proto, with: nil)
    }
}
