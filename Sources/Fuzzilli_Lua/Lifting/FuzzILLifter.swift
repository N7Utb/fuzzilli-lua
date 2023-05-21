// Copyright 2020 Google LLC
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

/// Lifter to convert FuzzIL into its human readable text format
public class FuzzILLifter: Lifter {

    public init() {}

    private func lift(_ v: Variable) -> String {
        return "v\(v.number)"
    }

    private func lift(_ instr : Instruction, with w: inout ScriptWriter) {
        func input(_ n: Int) -> String {
            return lift(instr.input(n))
        }

        func output() -> String {
            return instr.hasOutputs ? lift(instr.output) : ""
        }

        func innerOutput() -> String {
            return lift(instr.innerOutput)
        }
        switch instr.op.opcode {
        
        case .loadNumber(let op):
            w.emit("\(output()) <- LoadFloat '\(op.value)'")

        case .loadString(let op):
            w.emit("\(output()) <- LoadString '\(op.value)'")

        case .loadBoolean(let op):
            w.emit("\(output()) <- LoadBoolean '\(op.value)'")

        case .loadNil:
            w.emit("\(output()) <- LoadNil")

        case .beginTable:
            w.emit("BeginTable")
            w.increaseIndentionLevel()

        case .tableAddProperty(let op):
            w.emit("TableAddProperty `\(op.propertyName)`, \(input(0))")

        case .tableAddElement(let op):
            w.emit("TableAddElement `\(op.index)`, \(input(0))")

        case .beginTableMethod(let op):
            let params = instr.innerOutputs.map(lift).joined(separator: ", ")
            w.emit("BeginTableMethod `\(op.methodName)` -> \(params)")
            w.increaseIndentionLevel()

        case .endTableMethod:
            w.decreaseIndentionLevel()
            w.emit("EndTableMethod")

        case .endTable:
            w.decreaseIndentionLevel()
            w.emit("\(output()) <- EndTable")

        case .createArray:
            let elems = instr.inputs.map(lift).joined(separator: ", ")
            w.emit("\(output()) <- CreateArray [\(elems)]")


        case .loadBuiltin(let op):
            w.emit("\(output()) <- LoadBuiltin '\(op.builtinName)'")

        case .getProperty(let op):
            let guarded =  ""
            w.emit("\(output()) <- GetProperty\(guarded) \(input(0)), '\(op.propertyName)'")

        case .setProperty(let op):
            w.emit("SetProperty \(input(0)), '\(op.propertyName)', \(input(1))")

        case .updateProperty(let op):
            w.emit("UpdateProperty \(input(0)), '\(op.op.token)', \(input(1))")

        case .deleteProperty(let op):
            let guarded =  ""
            w.emit("\(output()) <- DeleteProperty\(guarded) \(input(0)), '\(op.propertyName)'")

        case .getElement(let op):
            let guarded = ""
            w.emit("\(output()) <- GetElement\(guarded) \(input(0)), '\(op.index)'")

        case .setElement(let op):
            w.emit("SetElement \(input(0)), '\(op.index)', \(input(1))")

        case .updateElement(let op):
            w.emit("UpdateElement \(instr.input(0)), '\(op.index)', '\(op.op.token)', \(input(1))")

        case .deleteElement(let op):
            let guarded = ""
            w.emit("\(output()) <- DeleteElement\(guarded) \(input(0)), '\(op.index)'")

        case .beginFunction(let op):
            let params = instr.innerOutputs.map(lift).joined(separator: ", ")
            w.emit("\(output()) <- \(op.name) -> \(params)\("")")
            w.increaseIndentionLevel()

        case .endFunction(let op):
            w.decreaseIndentionLevel()
            w.emit("\(op.name)")

        case .return(let op):
            if op.hasReturnValue {
                w.emit("Return \(input(0))")
            } else {
                w.emit("Return")
            }

        case .callFunction:
            w.emit("\(output()) <- CallFunction \(input(0)), [\(liftCallArguments(instr.variadicInputs))]")

        case .callMethod(let op):
            let guarded = ""
            w.emit("\(output()) <- CallMethod\(guarded) \(input(0)), '\(op.methodName)', [\(liftCallArguments(instr.variadicInputs))]")


        case .unaryOperation(let op):
            if op.op.isPostfix {
                w.emit("\(output()) <- UnaryOperation \(input(0)), '\(op.op.token)'")
            } else {
                w.emit("\(output()) <- UnaryOperation '\(op.op.token)', \(input(0))")
            }

        case .binaryOperation(let op):
            w.emit("\(output()) <- BinaryOperation \(input(0)), '\(op.op.token)', \(input(1))")

        case .reassign:
            w.emit("Reassign \(input(0)), \(input(1))")

        case .update(let op):
            w.emit("Update \(instr.input(0)), '\(op.op.token)', \(input(1))")

        case .compare(let op):
            w.emit("\(output()) <- Compare \(input(0)), '\(op.op.token)', \(input(1))")

        case .nop:
            w.emit("Nop")

        case .beginIf(let op):
            let mode = op.inverted ? "(inverted) " : ""
            w.emit("BeginIf \(mode)\(input(0))")
            w.increaseIndentionLevel()

        case .beginElse:
            w.decreaseIndentionLevel()
            w.emit("BeginElse")
            w.increaseIndentionLevel()

        case .endIf:
            w.decreaseIndentionLevel()
            w.emit("EndIf")


        case .beginWhileLoopHeader:
            w.emit("BeginWhileLoopHeader")
            w.increaseIndentionLevel()

        case .beginWhileLoopBody:
            w.decreaseIndentionLevel()
            w.emit("BeginWhileLoopBody \(input(0))")
            w.increaseIndentionLevel()

        case .endWhileLoop:
            w.decreaseIndentionLevel()
            w.emit("EndWhileLoop")

        case .beginForLoopInitializer:
            w.emit("BeginForLoopInitializer")
            w.increaseIndentionLevel()

        case .beginForLoopCondition(let op):
            w.decreaseIndentionLevel()
            let loopVariables = instr.innerOutputs.map(lift).joined(separator: ", ")
            w.emit("BeginForLoopCondition -> \(loopVariables)")
            w.increaseIndentionLevel()

        case .beginForLoopAfterthought(let op):
            w.decreaseIndentionLevel()
            let loopVariables = instr.innerOutputs.map(lift).joined(separator: ", ")
            w.emit("BeginForLoopAfterthought \(input(0)) -> \(loopVariables)")
            w.increaseIndentionLevel()

        case .beginForLoopBody(let op):
            w.decreaseIndentionLevel()
            let loopVariables = instr.innerOutputs.map(lift).joined(separator: ", ")
            w.emit("BeginForLoopBody -> \(loopVariables)")
  
            w.increaseIndentionLevel()

        case .endForLoop:
            w.decreaseIndentionLevel()
            w.emit("EndForLoop")

        case .beginForInLoop:
            w.emit("BeginForInLoop \(input(0)) -> \(innerOutput())")
            w.increaseIndentionLevel()

        case .endForInLoop:
            w.decreaseIndentionLevel()
            w.emit("EndForInLoop")


        case .beginRepeatLoop(let op):
            if op.exposesLoopCounter {
                w.emit("BeginRepeatLoop '\(op.iterations)' -> \(innerOutput())")
            } else {
                w.emit("BeginRepeatLoop '\(op.iterations)'")
            }
            w.increaseIndentionLevel()

        case .endRepeatLoop:
            w.decreaseIndentionLevel()
            w.emit("EndRepeatLoop")

        case .loopBreak:
            w.emit("Break")
        case .label(let op):
            w.emit("Label '\(op.name)'")
        case .goto(let op):
            w.emit("Goto '\(op.name)'")
        case .loadPair(_):
            w.emit("LoadPair")
}

    }

    public func lift(_ program: Program, withOptions options: LiftingOptions) -> String {
        var w = ScriptWriter()

        if options.contains(.includeComments), let header = program.comments.at(.header) {
            w.emitComment(header)
        }

        for instr in program.code {
            if options.contains(.includeComments), let comment = program.comments.at(.instruction(instr.index)) {
                w.emitComment(comment)
            }

            lift(instr, with: &w)
        }

        if options.contains(.includeComments), let footer = program.comments.at(.footer) {
            w.emitComment(footer)
        }

        return w.code
    }

    public func lift(_ code: Code) -> String {
        var w = ScriptWriter()

        for instr in code {
            lift(instr, with: &w)
        }

        return w.code
    }

    private func liftCallArguments(_ args: ArraySlice<Variable>, spreading spreads: [Bool] = []) -> String {
        var arguments = [String]()
        for (i, v) in args.enumerated() {
            if spreads.count > i && spreads[i] {
                arguments.append("...\(lift(v))")
            } else {
                arguments.append(lift(v))
            }
        }
        return arguments.joined(separator: ", ")
    }

    private func liftArrayDestructPattern(indices: [Int64], outputs: [String], hasRestElement: Bool) -> String {
        assert(indices.count == outputs.count)

        var arrayPattern = ""
        var lastIndex = 0
        for (index64, output) in zip(indices, outputs) {
            let index = Int(index64)
            let skipped = index - lastIndex
            lastIndex = index
            let dots = index == indices.last! && hasRestElement ? "..." : ""
            arrayPattern += String(repeating: ",", count: skipped) + dots + output
        }

        return arrayPattern
    }

    private func liftObjectDestructPattern(properties: [String], outputs: [String], hasRestElement: Bool) -> String {
        assert(outputs.count == properties.count + (hasRestElement ? 1 : 0))

        var objectPattern = ""
        for (property, output) in zip(properties, outputs) {
            objectPattern += "\(property):\(output),"
        }
        if hasRestElement {
            objectPattern += "...\(outputs.last!)"
        }

        return objectPattern
    }
}