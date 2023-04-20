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

//
// Code generators.
//
// These insert one or more instructions into a program.
//
public let CodeGenerators: [CodeGenerator] = [
    //
    // Value Generators: Code Generators that generate one or more new values.
    //
    // These behave like any other CodeGenerator in that they will be randomly chosen to generate code
    // and have a weight assigned to them to determine how frequently they are selected, but in addition
    // ValueGenerators are also used to "bootstrap" code generation by creating some initial variables
    // that following code can then operate on.
    //
    // These:
    //  - Must be able to run when there are no visible variables.
    //  - Together should cover all "interesting" types that generated programs should operate on.
    //  - Must only generate values whose types can be inferred statically.
    //  - Should generate |n| different values of the same type, but may generate fewer.
    //  - May be recursive, for example to fill bodies of newly created blocks.
    //
    ValueGenerator("NumberGenerator") { b, n in
        for _ in 0..<n {
            b.loadNumber(b.randomFloat(),isLocal: Bool.random())
        }
    },
    ValueGenerator("StringGenerator") { b, n in
        for _ in 0..<n {
            b.loadString(b.randomString(), isLocal: Bool.random())
        }
    },
    ValueGenerator("BooleanGenerator") { b, n in
        for _ in 0..<n {
            b.loadBoolean(Bool.random(), isLocal: Bool.random())
        }
    },
    ValueGenerator("NilGenerator") { b, n in
        // There is only one 'null' value, so don't generate it multiple times.
        b.loadNil(isLocal: Bool.random())
    },
    ValueGenerator("TrivialFunctionGenerator") { b, n in
        // Generating more than one function has a fairly high probability of generating
        // essentially identical functions, so we just generate one.
        let maybeReturnValue = b.hasVisibleVariables ? b.randomVariable() : nil
        b.buildFunction(with: .parameters(n: 0)) { _ in
            if let returnValue = maybeReturnValue {
                b.doReturn([returnValue])
            }
        }
    },
    RecursiveCodeGenerator("FunctionGenerator") { b in
        let f = b.buildFunction(with: b.randomParameters()) { _ in
            b.buildRecursive()
            b.doReturn(b.randomReturns())
        }
        b.callFunction(f, withArgs: b.randomArguments(forCalling: f))
    },

    CodeGenerator("FunctionCallGenerator", input: .function()) { b, f in
        let arguments = b.randomArguments(forCalling: f)
        if b.type(of: f).Is(.function()) {
            b.callFunction(f, withArgs: arguments)
        }
    },
    CodeGenerator("SubroutineReturnGenerator", inContext: .subroutine) { b in
        assert(b.context.contains(.subroutine))
        if probability(0.9) {
            b.doReturn(b.randomReturns())
        } else {
            b.doReturn([])
        }
    },
    CodeGenerator("UnaryOperationGenerator", input: .anything) { b, val in
        switch b.type(of: val){
        case .number:
            b.unary(chooseUniform(from: UnaryOperator.numop), val)
        case .string:
            b.unary(chooseUniform(from: UnaryOperator.strop), val)
        default:
            b.unary(chooseUniform(from: UnaryOperator.allop), val)
        }
        

    },

    CodeGenerator("BinaryOperationGenerator", inputs: (.anything, .anything)) { b, lhs, rhs in
        switch (b.type(of: lhs), b.type(of: rhs)) {
        case (.number, .number):
            b.binary(lhs, rhs, with: chooseUniform(from: BinaryOperator.numop))
        case (.string, .string):
            b.binary(lhs, rhs, with: chooseUniform(from: BinaryOperator.strop))
        default:
            b.binary(lhs, rhs, with: chooseUniform(from: BinaryOperator.allop))
        }
    },

    CodeGenerator("ComparisonGenerator", inputs: (.anything, .anything)) { b, lhs, rhs in
        switch (b.type(of: lhs), b.type(of: rhs)) {
        case (.number, .number):
            b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.numop))
        case (.string, .string):
            b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.strop))
        default:
            b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.allop))
        }
    },

]

extension Array where Element == CodeGenerator {
    public func get(_ name: String) -> CodeGenerator {
        for generator in self {
            if generator.name == name {
                return generator
            }
        }
        fatalError("Unknown code generator \(name)")
    }
}
