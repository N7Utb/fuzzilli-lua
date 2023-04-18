
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

/// Builds programs.
///
/// This provides methods for constructing and appending random
/// instances of the different kinds of operations in a program.
/// 
public class ProgramBuilder {
    /// The fuzzer instance for which this builder is active.
    public let fuzzer: Fuzzer

    /// The code and type information of the program that is being constructed.
    private var code = Code()

    /// Comments for the program that is being constructed.
    private var comments = ProgramComments()

    /// Every code generator that contributed to the current program.
    private var contributors = Contributors()

    /// The parent program for the program being constructed.
    private let parent: Program?    

    private var typeanaylzer:TypeAnaylzer

    /// If true, the variables containing a function is hidden inside the function's body.
    ///
    /// For example, in
    ///
    ///     let f = b.buildPlainFunction(with: .parameters(n: 2) { args in
    ///         // ...
    ///     }
    ///     b.callFunction(f, withArgs: b.randomArguments(forCalling: f))
    ///
    /// The variable f would *not* be visible inside the body of the plain function during building
    /// when this is enabled. However, the variable will be visible during future mutations, it is only
    /// hidden when the function is initially created.
    ///
    /// The same is done for class definitions, which may also cause trivial recursion in the constructor,
    /// but where usage of the output inside the class definition's body may also cause other problems,
    /// for example since `class C { [C] = 42; }` is invalid.
    ///
    /// This can make sense for a number of reasons. First, it prevents trivial recursion where a
    /// function directly calls itself. Second, it prevents weird code like for example the following:
    ///
    ///     function f1() {
    ///         let o6 = { x: foo + foo, y() { return foo; } };
    ///     }
    ///
    /// From being generated, which can happen quite frequently during prefix generation as
    /// the number of visible variables may be quite small.
    public let enableRecursionGuard = true

    /// Counter to quickly determine the next free variable.
    private var numVariables = 0

    /// Visible variables management.
    /// The `scopes` stack contains one entry per currently open scope containing all local variables created in that scope.
    private var scopes = Stack<[Variable]>([[]])
    /// The `variablesInScope` array simply contains all variables that are currently in scope. It is effectively the `scopes` stack flattened.
    private var variablesInScope = [Variable]()
    /// The `globalvariables` array simply contains all global variables 
    private var globalvariable = [Variable]()

    /// Keeps track of variables that have explicitly been hidden and so should not be
    /// returned from e.g. `randomVariable()`. See `hide()` for more details.
    private var hiddenVariables = VariableSet()
    private var numberOfHiddenVariables = 0
    
    /// All currently visible variables.
    public var visibleVariables: [Variable] {
        if numberOfHiddenVariables == 0 {
            // Fast path for the common case.
            return variablesInScope
        } else {
            return variablesInScope.filter({ !hiddenVariables.contains($0) })
        }
    }

    /// Constructs a new program builder for the given fuzzer.
    init(for fuzzer: Fuzzer, parent: Program?) {
        self.fuzzer = fuzzer
        self.typeanaylzer = TypeAnaylzer()
        self.parent = parent
    }
    /// Resets this builder.
    public func reset() {
        code.removeAll()
        comments.removeAll()
        // contributors.removeAll()
        // numVariables = 0
        // scopes = Stack([[]])
        // variablesInScope.removeAll()
        // hiddenVariables.removeAll()
        // numberOfHiddenVariables = 0
        // contextAnalyzer = ContextAnalyzer()
        typeanaylzer.reset()
        // activeObjectLiterals.removeAll()
        // activeClassDefinitions.removeAll()
    }

    /// Finalizes and returns the constructed program, then resets this builder so it can be reused for building another program.
    public func finalize() -> Program {
        let program = Program(code: code, parent: parent, comments: comments, contributors: contributors)
        reset()
        return program
    }

    /// Hide the specified variable, preventing it from being used as input by subsequent code.
    ///
    /// Hiding a variable prevents it from being returned from `randomVariable()` and related functions, which
    /// in turn prevents it from being used as input for later instructins, unless the hidden variable is explicitly specified
    /// as input, which is still allowed.
    ///
    /// This can be useful for example if a CodeGenerator needs to create temporary values that should not be used
    /// by any following code. It is also used to prevent trivial recursion by hiding the function variable inside its body.
    public func hide(_ variable: Variable) {
        assert(!hiddenVariables.contains(variable))
        assert(visibleVariables.contains(variable))

        hiddenVariables.insert(variable)
        numberOfHiddenVariables += 1
    }

    /// Unhide the specified variable so that it can again be used as input by subsequent code.
    ///
    /// The variable must have previously been hidden using `hide(variable:)` above.
    public func unhide(_ variable: Variable) {
        assert(numberOfHiddenVariables > 0)
        assert(hiddenVariables.contains(variable))
        assert(variablesInScope.contains(variable))
        assert(!visibleVariables.contains(variable))

        hiddenVariables.remove(variable)
        numberOfHiddenVariables -= 1
    }

    /// Returns the next free variable.
    func nextVariable(_ isLocal:Bool = false) -> Variable {
        assert(numVariables < Code.maxNumberOfVariables, "Too many variables")
        numVariables += 1
        return Variable(number: numVariables - 1,isLocal: isLocal)
    }

    @discardableResult
    private func internalAppend(_ instr: Instruction) -> Instruction {
        // Basic integrity checking
        assert(!instr.inouts.contains(where: { $0.number >= numVariables }))
        // Context Checking
        /// TODO: Context
        // assert(instr.op.requiredContext.isSubset(of: contextAnalyzer.context))

        // The returned instruction will also contain its index in the program. Use that so the analyzers have access to the index.
        let instr = code.append(instr)
        analyze(instr)

        return instr
    }

    /// Set the parameter types for the next function, method, or constructor, which must be the the start of a function or method definition.
    /// Parameter types (and signatures in general) are only valid for the duration of the program generation, as they cannot be preserved across mutations.
    /// As such, the parameter types are linked to their instruction through the index of the instruction in the program.
    private func setParameterTypesForNextSubroutine(_ parameterTypes: ParameterList) {
        typeanaylzer.setParameters(forSubroutineStartingAt: code.count, to: parameterTypes)
    }

    /// Analyze the given instruction. Should be called directly after appending the instruction to the code.
    private func analyze(_ instr: Instruction) {
        //! DEBUG
        print(instr)
        assert(code.lastInstruction.op === instr.op)
        updateVariableAnalysis(instr)
        // contextAnalyzer.analyze(instr)
        // updateObjectAndClassLiteralState(instr)
        typeanaylzer.analyze(instr)
    }
    private func updateVariableAnalysis(_ instr: Instruction) {
        // Scope management (1).
        if instr.isBlockEnd {
            /// TODO: Block Analyze
            assert(scopes.count > 0, "Trying to close a scope that was never opened")
            let current = scopes.pop()
            // Hidden variables that go out of scope need to be unhidden.
            for v in current where hiddenVariables.contains(v) {
                unhide(v)
            }
            variablesInScope.removeLast(current.count)
        }
        for v in instr.outputs {
            if v.isLocal(){
                scopes.top.append(v)
            }
            else {
                globalvariable.append(v)
            }
        }
        variablesInScope.append(contentsOf: instr.outputs)

        // Scope management (2). Happens here since e.g. function definitions create a variable in the outer scope.
        if instr.isBlockStart {
            scopes.push([])
        }

        scopes.top.append(contentsOf: instr.innerOutputs)
        variablesInScope.append(contentsOf: instr.innerOutputs)

        //! DEBUG
        print("scopes: ", scopes)
        print("globalv: ", globalvariable)
    }
    //
    // Low-level instruction constructors.
    //
    // These create an instruction with the provided values and append it to the program at the current position.
    // If the instruction produces a new variable, that variable is returned to the caller.
    // Each class implementing the Operation protocol will have a constructor here.
    //

    @discardableResult
    private func emit(_ op: Operation, withInputs inputs: [Variable] = []) -> Instruction {
        var inouts = inputs
        for _ in 0..<op.numOutputs {
            inouts.append(nextVariable())
        }
        for _ in 0..<op.numInnerOutputs {
            inouts.append(nextVariable())
        }

        return internalAppend(Instruction(op, inouts: inouts))
    }

    @discardableResult
    private func emit(_ op: Operation, isLocal: Bool = false, withInputs inputs: [Variable] = []) -> Instruction {
        var inouts = inputs
        for _ in 0..<op.numOutputs {
            inouts.append(nextVariable(isLocal))
        }
        for _ in 0..<op.numInnerOutputs {
            inouts.append(nextVariable())
        }

        return internalAppend(Instruction(op, inouts: inouts))
    }

    @discardableResult
    public func loadNumber(_ value: Float64, isLocal: Bool = false) -> Variable {
        return emit(LoadNumber(value: value),isLocal:isLocal).output
    }

    @discardableResult
    public func loadString(_ value: String, isLocal: Bool = false) -> Variable {
        return emit(LoadString(value: value),isLocal:isLocal).output
    }
    // Helper struct to describe subroutine definitions.
    // This allows defining functions by just specifying the number of parameters or by specifying the types of the individual parameters.
    // Note however that parameter types are not associated with the generated operations and will therefore just be valid for the lifetime
    // of this ProgramBuilder. The reason for this behaviour is that it is generally not possible to preserve the type information across program
    // mutations: a mutator may change the callsite of a function or modify the uses of a parameter, effectively invalidating the parameter types.
    // Parameter types are therefore only valid when a function is first created.
    public struct SubroutineDescriptor {
        // The parameter "structure", i.e. the number of parameters and whether there is a rest parameter, etc.
        // Currently, this information is also fully contained in the parameterTypes member. However, if we ever
        // add support for features such as parameter destructuring, this would no longer be the case.
        public let parameters: Parameters
        // Type information for every parameter. If no type information is specified, the parameters will all use .anything as type.
        public let parameterTypes: ParameterList

        public var count: Int {
            return parameters.count
        }



        public static func parameters(numParameters: Int, numReturns: Int, hasRestParameter: Bool = false) -> SubroutineDescriptor {
            return SubroutineDescriptor(withParameters: Parameters(count:numParameters, hasRestParameter: hasRestParameter))
        }

        public static func parameters(params: Parameter..., rets: Parameter...) -> SubroutineDescriptor {
            return parameters(ParameterList(params),ParameterList(rets))
        }

        public static func parameters(_ parameterTypes: ParameterList, _ returnTypes: ParameterList) -> SubroutineDescriptor {
            let parameters = Parameters(count:parameterTypes.count, hasRestParameter: parameterTypes.hasRestParameter)
            return SubroutineDescriptor(withParameters: parameters, ofParaTypes: parameterTypes, ofRetTypes: returnTypes)
        }

        private init(withParameters parameters: Parameters, ofParaTypes parameterTypes: ParameterList? = nil, ofRetTypes retTypes: ParameterList? = nil) {
            if let types = parameterTypes {
                assert(types.areValid())
                assert(types.count == parameters.count)
                assert(types.hasRestParameter == parameters.hasRestParameter)
                self.parameterTypes = types
            } else {
                self.parameterTypes = ParameterList(numParameters: parameters.count, hasRestParam: parameters.hasRestParameter)
                assert(self.parameterTypes.allSatisfy({ $0 == .plain(.anything) || $0 == .rest(.anything) }))
            }

            self.parameters = parameters

        }
    }

    @discardableResult
    public func buildFunction(with descriptor: SubroutineDescriptor, _ body: ([Variable]) -> ()) -> Variable{
        setParameterTypesForNextSubroutine(descriptor.parameterTypes)
        let instr = emit(BeginFunction(parameters: descriptor.parameters))
        if enableRecursionGuard { hide(instr.output) }
        body(Array(instr.innerOutputs))
        if enableRecursionGuard { unhide(instr.output) }
        emit(EndFunction())
        return instr.output
    }

    public func doReturn(_ value: [Variable]? = nil) {
        if let returnValue = value {
            emit(Return(numInputs: returnValue.count), withInputs: returnValue)
        } else {
            emit(Return(numInputs: 0))
        }
    }


    @discardableResult
    public func unary(_ op: UnaryOperator, _ input: Variable) -> Variable {
        return emit(UnaryOperation(op), withInputs: [input]).output
    }

    @discardableResult
    public func binary(_ lhs: Variable, _ rhs: Variable, with op: BinaryOperator) -> Variable {
        return emit(BinaryOperation(op), withInputs: [lhs, rhs]).output
    }

    @discardableResult
    public func compare(_ lhs: Variable, with rhs: Variable, using comparator: Comparator) -> Variable {
        return emit(Compare(comparator), withInputs: [lhs, rhs]).output
    }

    @discardableResult
    public func callFunction(_ function: Variable, withArgs arguments: [Variable] = [], numReturns: Int = 0) -> [Variable] {
        return Array(emit(CallFunction(numArguments: arguments.count, numReturns: numReturns), withInputs: [function] + arguments).outputs)
    }

}