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

/// A mutator that mutates the Operations in the given program.
public class OperationMutator: BaseInstructionMutator {
    public init() {
        super.init(maxSimultaneousMutations: defaultMaxSimultaneousMutations)
    }

    public override func canMutate(_ instr: Instruction) -> Bool {
        // The OperationMutator handles both mutable and variadic operations since both require
        // modifying the operation and both types of mutations are approximately equally "useful",
        // so there's no need for a dedicated "VariadicOperationMutator".
        return instr.isOperationMutable || instr.isVariadic
    }

    public override func mutate(_ instr: Instruction, _ b: ProgramBuilder) {
        b.trace("Mutating next operation")

        let newInstr: Instruction
        if instr.isOperationMutable && instr.isVariadic {
            newInstr = probability(0.5) ? mutateOperation(instr, b) : extendVariadicOperation(instr, b)
        } else if instr.isOperationMutable {
            newInstr = mutateOperation(instr, b)
        } else {
            assert(instr.isVariadic)
            newInstr = extendVariadicOperation(instr, b)
        }

        b.adopt(newInstr)
    }

    private func mutateOperation(_ instr: Instruction, _ b: ProgramBuilder) -> Instruction {
        let newOp: Operation
        switch instr.op.opcode {
        /// TODO: More Operations
        case .loadBuiltin(_):
            newOp = LoadBuiltin(builtinName: b.randomBuiltin())
        case .loadNumber(_):
            newOp = LoadNumber(value: b.randomFloat())
        case .loadString(_):
            newOp = LoadString(value: b.randomString())
        case .loadBoolean(let op):
            newOp = LoadBoolean(value: !op.value)
        case .unaryOperation(_):
            newOp = UnaryOperation(chooseUniform(from: UnaryOperator.allCases))
        case .binaryOperation(_):
            newOp = BinaryOperation(chooseUniform(from: BinaryOperator.allCases))
        case .compare(_):
            newOp = Compare(chooseUniform(from: Comparator.allCases))
        case .beginIf(let op):
            newOp = BeginIf(inverted: !op.inverted)
        case .update(_):
            newOp = Update(chooseUniform(from: BinaryOperator.allCases))
        case .callMethod(let op):
            // Selecting a random method has a high chance of causing a runtime exception, so try to select an existing one.
            let methodName = b.type(of: instr.input(0)).randomMethod() ?? b.randomMethodName()
            newOp = CallMethod(methodName: methodName, numArguments: op.numArguments,numReturns: op.numReturns)
        case .loadPair:
            newOp = LoadPair()
        case .getProperty:
            newOp = GetProperty(propertyName: b.randomPropertyName())
        case .setProperty(_):
            newOp = SetProperty(propertyName: b.randomPropertyName())
        case .updateProperty(_):
            newOp = UpdateProperty(propertyName: b.randomPropertyName(), operator: chooseUniform(from: BinaryOperator.allCases))
        case .deleteProperty(_):
            newOp = DeleteProperty(propertyName: b.randomPropertyName())
        case .getElement(_):
            newOp = GetElement(index: b.randomIndex())
        case .setElement(_):
            newOp = SetElement(index: b.randomIndex())
        case .updateElement(_):
            newOp = UpdateElement(index: b.randomIndex(), operator: chooseUniform(from: BinaryOperator.allCases))
        case .deleteElement(_):
            newOp = DeleteElement(index: b.randomIndex())
        case .tableAddProperty(let op):
            newOp = TableAddProperty(propertyName: b.randomPropertyName(), hasValue: op.hasValue)
        case .tableAddElement(_):
            newOp = TableAddElement(index: b.randomIndex())
        case .beginTableMethod(let op):
            newOp = BeginTableMethod(methodName: b.randomMethodName(), parameters: op.parameters)
        default:
            fatalError("Unhandled Operation: \(type(of: instr.op))")
        }

        return Instruction(newOp, inouts: instr.inouts)
    }

    private func extendVariadicOperation(_ instr: Instruction, _ b: ProgramBuilder) -> Instruction {
        var instr = instr
        let numInputsToAdd = Int.random(in: 1...3)
        for _ in 0..<numInputsToAdd {
            instr = extendVariadicOperationByOneInput(instr, b)
        }
        return instr
    }

    private func extendVariadicOperationByOneInput(_ instr: Instruction, _ b: ProgramBuilder) -> Instruction {
        // Without visible variables, we can't add a new input to this instruction.
        // This should happen rarely, so just skip this mutation.
        guard b.hasVisibleVariables else { return instr }

        let newOp: Operation
        var inputs = instr.inputs

        switch instr.op.opcode {
        case .callFunction(let op):
            inputs.append(b.randomVariable())
            newOp = CallFunction(numArguments: op.numArguments + 1, numReturns: op.numReturns)
        case .callMethod(let op):
            inputs.append(b.randomVariable())
            newOp = CallMethod(methodName: op.methodName, numArguments: op.numArguments + 1, numReturns: op.numReturns)

        default:
            fatalError("Unhandled Operation: \(type(of: instr.op))")
        }
        assert(inputs.count != instr.inputs.count)
        let inouts = inputs + instr.outputs + instr.innerOutputs
        return Instruction(newOp, inouts: inouts)
    }

    private func replaceRandomElement<T: Comparable>(in elements: inout Array<T>, generatingRandomValuesWith generator: () -> T) {
        // Pick a random index to replace.
        guard let index = elements.indices.randomElement() else { return }

        // Try to find a replacement value that does not already exist.
        for _ in 0...5 {
            let newElem = generator()
            // Ensure that we neither add an element that already exists nor add one that we just removed
            if !elements.contains(newElem) {
                elements[index] = newElem
                return
            }
        }

        // Failed to find a replacement value, so just leave the array unmodified.
    }
}
