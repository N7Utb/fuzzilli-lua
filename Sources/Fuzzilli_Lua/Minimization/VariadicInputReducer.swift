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

/// Reducer to remove inputs from variadic operations.
struct VariadicInputReducer: Reducer {
    func reduce(_ code: inout Code, with helper: MinimizationHelper) {
        for instr in code {
            guard instr.isVariadic else { continue }
            let index = instr.index

            var instr = instr
            repeat {
                assert(instr.isVariadic)
                // Remove the last variadic input (if it exists)
                guard instr.numInputs > instr.firstVariadicInput else { break }

                let newOp: Operation
                switch instr.op.opcode {
                case .createArray(let op):
                    newOp = CreateArray(numInitialValues: op.numInitialValues - 1)
                case .callFunction(let op):
                    newOp = CallFunction(numArguments: op.numArguments - 1, numReturns: op.numReturns)
                case .callMethod(let op):
                    newOp = CallMethod(methodName: op.methodName, numArguments: op.numArguments - 1, numReturns: op.numReturns)
                default:
                    fatalError("Unknown variadic operation \(instr.op)")
                }

                let inouts = instr.inputs.dropLast() + instr.outputs + instr.innerOutputs
                instr = Instruction(newOp, inouts: inouts)
            } while helper.tryReplacing(instructionAt: index, with: instr, in: &code)
        }
    }
}
