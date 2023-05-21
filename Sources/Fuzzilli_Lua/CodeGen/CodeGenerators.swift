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
    // We don't treat this as a ValueGenerator since it doesn't create a new value, it only accesses an existing one.
    CodeGenerator("BuiltinGenerator") { b in
        b.loadBuiltin(b.randomBuiltin())
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

    RecursiveCodeGenerator("TableGenerator") {b in 
        b.buildTable(){ obj in
            b.buildRecursive()
        }
    },

    CodeGenerator("TablePropertyGenerator", inContext: .objectLiteral){ b in
        assert(b.context.contains(.objectLiteral) && !b.context.contains(.script))

        // Try to find a property that hasn't already been added to this literal.
        var propertyName: String
        var attempts = 0

        repeat {
            guard attempts < 10 else { return }
            propertyName = b.randomCustomPropertyName()
            attempts += 1
        } while b.currentTableDefinition.properties.contains(propertyName)

        b.currentTableDefinition.addTableProperty(propertyName, value: b.randomVariable())

    },

    CodeGenerator("TableElementGenerator", inContext: .objectLiteral, input: .anything){ b, v in
        assert(b.context.contains(.objectLiteral) && !b.context.contains(.script))

        // Select an element that hasn't already been added to this literal.
        var index = b.randomIndex()
        while b.currentTableDefinition.elements.contains(index) {
            // We allow integer overflows here since we could get Int64.max as index, and its not clear what should happen instead in that case.
            index &+= 1
        }

        b.currentTableDefinition.addTableElement(index, value: v)
    },

    RecursiveCodeGenerator("TableMethodGenerator", inContext: .objectLiteral){ b in
        assert(b.context.contains(.objectLiteral) && !b.context.contains(.script))

        // Try to find a method that hasn't already been added to this literal.
        var methodName: String
        var attempts = 0
        repeat {
            guard attempts < 10 else { return }
            methodName = b.randomCustomMethodName()
            attempts += 1
        } while b.currentTableDefinition.methods.contains(methodName)

        b.currentTableDefinition.addMethod(methodName, with: b.randomParameters()) { args in
            b.buildRecursive()
            b.doReturn(b.randomReturns())
        }
    
    },
    RecursiveCodeGenerator("FunctionGenerator") { b in
        let f = b.buildFunction(with: b.randomParameters()) { _ in
            b.buildRecursive()
            b.doReturn(b.randomReturns())
        }
        b.callFunction(f, withArgs: b.randomArguments(forCalling: f), numReturns: b.getFunctionNumReturns(forCalling: f))
    },
    CodeGenerator("LabelGenerator"){ b in
        b.buildLabel(b.nextLabel())
    },  

    CodeGenerator("FunctionCallGenerator", input: .function()) { b, f in
        let arguments = b.randomArguments(forCalling: f)
        if b.type(of: f).Is(.function()) {
            b.callFunction(f, withArgs: arguments, numReturns: b.getFunctionNumReturns(forCalling: f))
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
            b.unary(chooseUniform(from: UnaryOperator.numop + UnaryOperator.allop), val)
        case .string:
            b.unary(chooseUniform(from: UnaryOperator.strop + UnaryOperator.allop), val)
        default:
            b.unary(chooseUniform(from: UnaryOperator.allop), val)
        }
        

    },

    CodeGenerator("BinaryOperationGenerator", inputs: (.anything, .anything)) { b, lhs, rhs in
        b.binary(lhs, rhs, with: BinaryOperator.chooseOperation(lhs: b.type(of: lhs), rhs: b.type(of: rhs)))
    },

    CodeGenerator("UpdateGenerator", input: .anything) { b, v in
        guard let newValue = b.randomVariable(forUseAs: b.type(of: v)) else { return }
        b.reassign(newValue, to: v, with: BinaryOperator.chooseOperation(lhs: b.type(of: v), rhs: b.type(of: newValue)))
    },

    CodeGenerator("ReassignmentGenerator", input: .anything) { b, v in
        guard let newValue = b.randomVariable(forUseAs: b.type(of: v)) else { return }
        guard newValue != v else { return }
        b.reassign(newValue, to: v)
    },

    CodeGenerator("ComparisonGenerator", inputs: (.anything, .anything)) { b, lhs, rhs in
        switch (b.type(of: lhs), b.type(of: rhs)) {
        case (.number, .number):
            b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.numop + Comparator.allop))
        case (.string, .string):
            b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.strop + Comparator.allop))
        default:
            b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.allop))
        }
    },

    RecursiveCodeGenerator("IfElseGenerator", input: .boolean) { b, cond in
        b.buildIfElse(cond, ifBody: {
            b.buildRecursive(block: 1, of: 2)
        }, elseBody: {
            b.buildRecursive(block: 2, of: 2)
        })
    },

    RecursiveCodeGenerator("CompareWithIfElseGenerator", inputs: (.anything, .anything)) { b, lhs, rhs in
        var cond: Variable
        switch (b.type(of: lhs), b.type(of: rhs)) {
        case (.number, .number):
            cond = b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.numop + Comparator.allop))
        case (.string, .string):
            cond = b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.strop + Comparator.allop))
        default:
            cond = b.compare(lhs, with: rhs, using: chooseUniform(from: Comparator.allop))
        }
        b.buildIfElse(cond, ifBody: {
            b.buildRecursive(block: 1, of: 2)
        }, elseBody: {
            b.buildRecursive(block: 2, of: 2)
        })
    },
    RecursiveCodeGenerator("WhileLoopGenerator") { b in
        let loopVar = b.loadNumber(0)
        b.buildWhileLoop({ b.compare(loopVar, with: b.loadNumber(Float64.random(in: 1...10)), using: .lessThan) }) {
            b.buildRecursive()
            b.reassign(loopVar, to: b.loadNumber(1), with: BinaryOperator.Add)
        }
    },

    RecursiveCodeGenerator("SimpleForLoopGenerator") { b in
        b.buildForLoop(i: { b.loadNumber(0) }, { b.loadNumber(Float64.random(in: 10...20))}, {b.loadNumber(1)}) { _ in
            b.buildRecursive()
        }
    },
    RecursiveCodeGenerator("ForInLoopGenerator", input: .iterable + .function()) { b, obj in
        b.buildForInLoop(obj) { _ in
            b.buildRecursive()
        }
    },
    
    RecursiveCodeGenerator("RepeatLoopGenerator") { b in
        let numIterations = Int.random(in: 2...100)
        b.buildRepeatLoop(n: numIterations) { _ in
            b.buildRecursive()
        }
    },

    CodeGenerator("LoopBreakGenerator", inContext: .loop) { b in
        b.loopBreak()
    },

    CodeGenerator("PairGenerator", input: .table()) { b, obj in
        b.buildPair(obj)
    },
    RecursiveCodeGenerator("GotoGenerator"){ b in
        /// to avoid dead code
        let label = b.nextLabel()
        b.buildForLoop(i: { b.loadNumber(0) }, { b.loadNumber(Float64.random(in: 10...20))}, {b.loadNumber(1)}) { loopVar in
            b.buildIf(b.compare(loopVar, with: b.loadNumber(5), using: .greaterThan)){
                b.buildGoto(label)
            }
            b.buildRecursive()
            
        }
        b.buildLabel(label)
    },  
    /// TODO: more complex for loop Generator
    CodeGenerator("MethodCallGenerator", input: .table()) { b, obj in
        // print(b.type(of: objP))
        if let methodName = b.type(of: obj).randomMethod() {
            // TODO: here and below, if we aren't finding arguments of compatible types, we probably still need a try-catch guard.
            let arguments = b.randomArguments(forCallingMethod: methodName, on: obj)
            b.callMethod(methodName, on: obj, withArgs: arguments, numReturns: b.getMethodNumReturns(of: methodName, on: obj))
        }
    },

    CodeGenerator("NumberComputationGenerator") { b in
            // Generate a sequence of 3-7 random number computations on a couple of existing variables and some newly created constants.
        let numComputations = Int.random(in: 3...7)

        // Common mathematical operations are exposed through the Math builtin in JavaScript.
        let Math = b.loadBuiltin("math")
        b.hide(Math)        // Following code generators should use the numbers generated below, not the Math object.

        var values = b.randomVariables(upTo: Int.random(in: 1...3))
        for _ in 0..<Int.random(in: 1...2) {
            values.append(b.loadNumber(b.randomFloat()))
        }
        for _ in 0..<Int.random(in: 0...1) {
            values.append(b.loadNumber(b.randomFloat()))
        }

        for _ in 0..<numComputations {
            withEqualProbability({
                values.append(b.binary(chooseUniform(from: values), chooseUniform(from: values), with: chooseUniform(from: BinaryOperator.allCases)))
            }, {
                values.append(b.unary(chooseUniform(from: UnaryOperator.allCases), chooseUniform(from: values)))
            }, {
                // This can fail in tests, which lack the full JavaScriptEnvironment
                guard let method = b.type(of: Math).randomMethod() else { return }
                var args = [Variable]()
                for _ in 0..<b.methodSignature(of: method, on: Math).numParameters {
                    args.append(chooseUniform(from: values))
                }
                b.callMethod(method, on: Math, withArgs: args)
            })
        }
    },

    CodeGenerator("PropertyRetrievalGenerator", input: .table()) { b, obj in
        let propertyName = b.type(of: obj).randomProperty() ?? b.randomCustomPropertyName()
        b.getProperty(propertyName, of: obj)
    },
 
    CodeGenerator("PropertyAssignmentGenerator", input: .table()) { b, obj in
        let propertyName: String
        // Either change an existing property or define a new one
        if probability(0.5) {
            propertyName = b.type(of: obj).randomProperty() ?? b.randomCustomPropertyName()
        } else {
            propertyName = b.randomCustomPropertyName()
        }

        // If this is an existing property with a specific type, try to find a variable with a matching type.
        var propertyType = b.type(ofProperty: propertyName, on: obj)
        assert(propertyType == .anything || b.type(of: obj).properties.contains(propertyName))
        guard let value = b.randomVariable(forUseAs: propertyType) else { return }

        // TODO: (here and below) maybe wrap in try catch if obj may be nullish?
        b.setProperty(propertyName, of: obj, to: value)
    },

    CodeGenerator("PropertyUpdateGenerator", input: .table()) { b, obj in
        let propertyName: String
        // Change an existing property
        propertyName = b.type(of: obj).randomProperty() ?? b.randomCustomPropertyName()

        // TODO: for now we simply look for numbers, since those probably make the most sense for binary operations. But we may also want BigInts or strings sometimes.
        let rhs = b.randomVariable(forUseAs: .number) ?? b.randomVariable()
        b.updateProperty(propertyName, of: obj, with: rhs, using: BinaryOperator.chooseOperation(lhs: b.type(ofProperty: propertyName, on: obj), rhs: b.type(of: rhs)))
    },

    CodeGenerator("PropertyRemovalGenerator", input: .table()) { b, obj in
        let propertyName = b.type(of: obj).randomProperty() ?? b.randomCustomPropertyName()
        b.deleteProperty(propertyName, of: obj)
    },

    CodeGenerator("ElementRetrievalGenerator", input: .table()) { b, obj in
        let index = b.randomIndex()
        b.getElement(index, of: obj)
    },

    CodeGenerator("ElementAssignmentGenerator", input: .table()) { b, obj in
        let index = b.randomIndex()
        let value = b.randomVariable()
        b.setElement(index, of: obj, to: value)
    },

    CodeGenerator("ElementUpdateGenerator", input: .table()) { b, obj in
        let index = b.randomIndex()
        // TODO: for now we simply look for numbers, since those probably make the most sense for binary operations. But we may also want BigInts or strings sometimes.
        let rhs = b.randomVariable(forUseAs: .number) ?? b.randomVariable()
        b.updateElement(index, of: obj, with: rhs, using: BinaryOperator.chooseOperation(lhs: b.type(of: obj).arraytype[Int(index)] ?? .undefined, rhs: b.type(of: rhs)))
    },

    CodeGenerator("ElementRemovalGenerator", input: .table()) { b, obj in
        let index = b.randomIndex()
        b.deleteElement(index, of: obj)
    }
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
