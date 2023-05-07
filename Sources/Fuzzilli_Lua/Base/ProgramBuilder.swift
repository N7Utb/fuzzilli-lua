
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

    /// Stack of active object literals.
    ///
    /// This needs to be a stack as object literals can be nested, for example if an object
    /// literals is created inside a method/getter/setter of another object literals.
    private var activeTableDefinitions = Stack<TableDefinition>()

    /// When building object literals, the state for the current literal is exposed through this member and
    /// can be used to add fields to the literal or to determine if some field already exists.
    public var currentTableDefinition: TableDefinition {
        return activeTableDefinitions.top
    }

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

    /// Context analyzer to keep track of the currently active IL context.
    private var contextAnalyzer = ContextAnalyzer()

    public var context: Context {
        return contextAnalyzer.context
    }
    
    /// Counter to quickly determine the next free variable.
    private var numVariables = 0

    /// Counter to quickly determine the next free label names.
    private var numLabels = 0

    /// Visible variables management.
    /// The `scopes` stack contains one entry per currently open scope containing all local variables created in that scope.
    private var scopes = Stack<[Variable]>([[]])
    /// The `variablesInScope` array simply contains all variables that are currently in scope. It is effectively the `scopes` stack flattened.
    private var variablesInScope: [Variable] {
        scopes.buffer.flatMap({$0})
    }

    /// Keeps track of variables that have explicitly been hidden and so should not be
    /// returned from e.g. `randomVariable()`. See `hide()` for more details.
    private var hiddenVariables = VariableSet()
    private var numberOfHiddenVariables = 0

    /// How many variables are currently in scope.
    public var numberOfVisibleVariables: Int {
        assert(numberOfHiddenVariables <= variablesInScope.count)
        return variablesInScope.count - numberOfHiddenVariables
    }

    /// Whether there are any variables currently in scope.
    public var hasVisibleVariables: Bool {
        return numberOfVisibleVariables > 0
    }

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
        self.typeanaylzer = TypeAnaylzer(for: fuzzer.environment)
        self.parent = parent
    }
    /// Resets this builder.
    public func reset() {
        code.removeAll()
        comments.removeAll()
        contributors.removeAll()
        numVariables = 0
        scopes = Stack([[]])
        hiddenVariables.removeAll()
        numberOfHiddenVariables = 0
        contextAnalyzer = ContextAnalyzer()
        typeanaylzer.reset()
        activeTableDefinitions.removeAll()

    }

    public func check() -> Bool{
        return code.isStaticallyValid()
    }

    /// Finalizes and returns the constructed program, then resets this builder so it can be reused for building another program.
    public func finalize() -> Program {
        let program = Program(code: code, parent: parent, comments: comments, contributors: contributors)
        reset()
        return program
    }

    /// Returns the current number of instructions of the program we're building.
    public var currentNumberOfInstructions: Int {
        return code.count
    }

    /// Returns the index of the next instruction added to the program. This is equal to the current size of the program.
    public func indexOfNextInstruction() -> Int {
        return currentNumberOfInstructions
    }

    /// Add a trace comment to the currently generated program at the current position.
    /// This is only done if inspection is enabled.
    public func trace(_ commentGenerator: @autoclosure () -> String) {
        if fuzzer.config.enableInspection {
            // Use an autoclosure here so that template strings are only evaluated when they are needed.
            comments.add(commentGenerator(), at: .instruction(code.count))
        }
    }
    
    /// Add a trace comment at the start of the currently generated program.
    /// This is only done if history inspection is enabled.
    public func traceHeader(_ commentGenerator: @autoclosure () -> String) {
        if fuzzer.config.enableInspection {
            comments.add(commentGenerator(), at: .header)
        }
    }

    /// Returns a random integer value suitable as size of for example an array.
    /// The returned value is guaranteed to be positive.
    public func randomSize(upTo maximum: Int64 = 0x100000000) -> Int64 {
        assert(maximum >= 0x1000)
        if probability(0.5) {
            return chooseUniform(from: fuzzer.environment.interestingIntegers.filter({ $0 >= 0 && $0 <= maximum }))
        } else {
            return withEqualProbability({
                Int64.random(in: 0...0x10)
            }, {
                Int64.random(in: 0...0x100)
            }, {
                Int64.random(in: 0...0x1000)
            }, {
                Int64.random(in: 0...maximum)
            })
        }
    }

    /// Returns a random integer value suitable as index.
    public func randomIndex() -> Int64 {
        // Prefer small, (usually) positive, indices.
        if probability(0.33) {
            return Int64.random(in: -2...10)
        } else {
            return randomSize()
        }
    }

    /// Returns a random floating point value.
    public func randomFloat() -> Double {
        if probability(0.5) {
            return chooseUniform(from: fuzzer.environment.interestingFloats)
        } else {
            return withEqualProbability({
                Double.random(in: 0.0...1.0)
            }, {
                Double.random(in: -10.0...10.0)
            }, {
                Double.random(in: -1000.0...1000.0)
            }, {
                Double.random(in: -1000000.0...1000000.0)
            }, {
                // We cannot do Double.random(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude) here,
                // presumably because that range is larger than what doubles can represent? So split the range in two.
                if probability(0.5) {
                    return Double.random(in: -Double.greatestFiniteMagnitude...0)
                } else {
                    return Double.random(in: 0...Double.greatestFiniteMagnitude)
                }
            })
        }
    }

    /// Returns a random string value.
    public func randomString() -> String {
        return withEqualProbability({
        //     self.randomPropertyName()
        // }, {
        //     self.randomMethodName()
        // }, {
        //     chooseUniform(from: self.fuzzer.environment.interestingStrings)
        // }, {
            String(self.randomFloat())
        }, {
            String.random(ofLength: Int.random(in: 2...10))
        }, {
            String.random(ofLength: 1)
        })
    }

    /// Returns the name of a random builtin.
    public func randomBuiltin() -> String {
        return chooseUniform(from: fuzzer.environment.builtins)
    }   

    /// Returns a random builtin property name.
    ///
    /// This will return a random name from the environment's list of builtin property names,
    /// i.e. a property that exists on (at least) one builtin object type.
    func randomBuiltinPropertyName() -> String {
        return chooseUniform(from: fuzzer.environment.builtinProperties)
    }

    /// Returns a random custom property name.
    ///
    /// This will select a random property from a (usually relatively small) set of custom property names defined by the environment.
    ///
    /// This should generally be used in one of two situations:
    ///   1. If a new property is added to an object.
    ///     In that case, we prefer to add properties with custom names (e.g. ".a", ".b") instead of properties
    ///     with names that exist in the environment (e.g. ".length", ".prototype"). This way, in the resulting code
    ///     it will be fairly clear when a builtin property is accessed vs. a custom one. It also increases the chances
    ///     of selecting an existing property when choosing a random property to access, see the next point.
    ///   2. If we have no static type information about the object we're accessing.
    ///     In that case there is a higher chance of success when using the small set of custom property names
    ///     instead of the much larger set of all property names that exist in the environment (or something else).
    public func randomCustomPropertyName() -> String {
        return chooseUniform(from: fuzzer.environment.customProperties)
    }

    /// Returns either a builtin or a custom property name, with equal probability.
    public func randomPropertyName() -> String {
        return probability(0.5) ? randomBuiltinPropertyName() : randomCustomPropertyName()
    }

    /// Returns a random builtin method name.
    ///
    /// This will return a random name from the environment's list of builtin method names,
    /// i.e. a method that exists on (at least) one builtin object type.
    public func randomBuiltinMethodName() -> String {
        return chooseUniform(from: fuzzer.environment.builtinMethods)
    }


    /// Returns a random custom method name.
    ///
    /// This will select a random method from a (usually relatively small) set of custom method names defined by the environment.
    ///
    /// See the comment for randomCustomPropertyName() for when this should be used.
    public func randomCustomMethodName() -> String {
        return chooseUniform(from: fuzzer.environment.customMethods)
    }
    
    /// Returns either a builtin or a custom method name, with equal probability.
    public func randomMethodName() -> String {
        return probability(0.5) ? randomBuiltinMethodName() : randomCustomMethodName()
    }

    /// Returns a random visible label
    public func randomLabel() -> String? {
        return !label_stack.top.isEmpty ? chooseUniform(from: label_stack.top) : nil
    }
    
    // Settings and constants controlling the behavior of randomParameters() below.
    // This determines how many variables of a given type need to be visible before
    // that type is considered a candidate for a parameter type. For example, if this
    // is three, then we need at least three visible .integer variables before creating
    // parameters of type .integer.
    private let thresholdForUseAsParameter = 3

    // The probability of using .anything as parameter type even though we have more specific alternatives.
    // Doing this sometimes is probably beneficial so that completely random values are passed to the function.
    // Future mutations, such as the ExplorationMutator can then figure out what to do with the parameters.
    // Writable so it can be changed for tests.
    var probabilityOfUsingAnythingAsParameterTypeIfAvoidable = 0.20


    // Generate random parameters for a subroutine.
    //
    // This will attempt to find a parameter types for which at least a few variables of a compatible types are
    // currently available to (potentially) later be used as arguments for calling the generated subroutine.
    public func randomParameters(n wantedNumberOfParameters: Int? = nil) -> SubroutineDescriptor {
        assert(probabilityOfUsingAnythingAsParameterTypeIfAvoidable >= 0 && probabilityOfUsingAnythingAsParameterTypeIfAvoidable <= 1)

        // If the caller didn't specify how many parameters to generated, find an appropriate
        // number of parameters based on how many variables are currently visible (and can
        // therefore later be used as arguments for calling the new function).
        let n: Int
        if let requestedN = wantedNumberOfParameters {
            assert(requestedN > 0)
            n = requestedN
        } else {
            switch numberOfVisibleVariables {
            case 0...1:
                n = 0
            case 2...5:
                n = Int.random(in: 1...2)
            default:
                n = Int.random(in: 2...4)
            }
        }

        // Find all types of which we currently have at least a few visible variables that we could later use as arguments.
        // TODO: improve this code by using some kind of cache? That could then also be used for randomVariable(ofType:) etc.
        var availableVariablesByType = [LuaType: Int]()
        for v in visibleVariables {
            let t = type(of: v)
            // TODO: should we also add this values to the buckets for supertypes (without this becoming O(n^2))?
            // TODO: alternatively just check for some common union types, e.g. .number, .primitive, as long as these can be used meaningfully?
            availableVariablesByType[t] = (availableVariablesByType[t] ?? 0) + 1
        }

        var candidates = Array(availableVariablesByType.filter({ k, v in v >= thresholdForUseAsParameter }).keys)
        if candidates.isEmpty {
            candidates.append(.anything)
        }

        var params = ParameterList()
        for _ in 0..<n {
            if probability(probabilityOfUsingAnythingAsParameterTypeIfAvoidable) {
                params.append(.anything)
            } else {
                params.append(.plain(chooseUniform(from: candidates)))
            }
        }

        // TODO: also generate rest parameters and maybe even optional ones sometimes?

        return .parameters(params)
    }
    public func randomReturns(n wantedNumberOfParameters: Int? = nil) -> [Variable] {
        // If the caller didn't specify how many parameters to generated, find an appropriate
        // number of parameters based on how many variables are currently visible (and can
        // therefore later be used as arguments for calling the new function).
        let n: Int
        if let requestedN = wantedNumberOfParameters {
            assert(requestedN > 0)
            n = requestedN
        } else {
            switch numberOfVisibleVariables {
            case 0...1:
                n = 0
            case 2...5:
                n = Int.random(in: 1...2)
            default:
                n = Int.random(in: 2...4)
            }
        }
        return randomVariables(upTo: n)
    }

    ///
    /// Access to variables.
    ///

    /// Returns a random variable.
    public func randomVariable() -> Variable {
        assert(hasVisibleVariables)
        return randomVariableInternal()!
    }

    /// Returns up to N (different) random variables.
    /// This method will only return fewer than N variables if the number of currently visible variables is less than N.
    public func randomVariables(upTo n: Int) -> [Variable] {
        guard hasVisibleVariables else { return [] }

        var variables = [Variable]()
        while variables.count < n {
            guard let newVar = randomVariableInternal(filter: { !variables.contains($0) }) else {
                break
            }
            variables.append(newVar)
        }
        return variables
    }

    /// Returns a random variable to be used as the given type.
    ///
    /// This function may return variables of a different type, or variables that may have the requested type, but could also have a different type.
    /// For example, when requesting a .integer, this function may also return a variable of type .number, .primitive, or even .anything as all of these
    /// types may be an integer (but aren't guaranteed to be). In this way, this function ensures that variables for which no exact type could be statically
    /// determined will also be used as inputs for following code.
    ///
    /// It's the caller's responsibility to check the type of the returned variable to avoid runtime exceptions if necessary. For example, if performing a
    /// property access, the returned variable should be checked if it `MayBe(.nullish)` in which case a property access would result in a
    /// runtime exception and so should be appropriately guarded against that.
    ///
    /// If the variable must be of the specified type, use `randomVariable(ofType:)` instead.
    ///
    /// TODO: consider allowing this function to also return a completely random variable if no MayBe compatible variable is found since the
    /// caller anyway needs to check for compatibility. In practice it probably doesn't matter too much since MayBe already includes .anything.
    public func randomVariable(forUseAs type: LuaType) -> Variable? {
        assert(type != .nothing)

        // TODO: we could add some logic here to ensure more diverse variable selection. For example,
        // if there are fewer than N (e.g. 3) visible variables  that satisfy the given constraint
        // (but in total we have more than M, say 10, visible variables) then return nil with a
        // probability of 50% or so and let the caller deal with that appropriately, for example by
        // then picking a random variable and guarding against incorrect types.

        // return randomVariableInternal(filter: { self.type(of: $0).MayBe(type) })
        return randomVariableInternal(filter: { self.type(of: $0).Is(type) })
    }

    /// Returns a random variable that is known to have the given type.
    ///
    /// This will return a variable for which `b.type(of: v).Is(type)` is true, i.e. for which our type inference
    /// could prove that it will have the specified type. If no such variable is found, this function returns nil.
    public func randomVariable(ofType type: LuaType) -> Variable? {
        assert(type != .nothing)
        return randomVariableInternal(filter: { self.type(of: $0).Is(type) })
    }

    /// Returns a random variable satisfying the given constraints or nil if none is found.
    func randomVariableInternal(filter maybeFilter: ((Variable) -> Bool)? = nil) -> Variable? {
        assert(hasVisibleVariables)

        // Also filter out any hidden variables.
        var isIncluded = maybeFilter
        if numberOfHiddenVariables != 0 {
            isIncluded = { !self.hiddenVariables.contains($0) && (maybeFilter?($0) ?? true) }
        }

        var candidates = [Variable]()

        // Prefer the outputs of the last instruction to build longer data-flow chains.
        if probability(0.15) {
            candidates = Array(code.lastInstruction.allOutputs)
            if let f = isIncluded {
                candidates = candidates.filter(f)
            }
        }

        // Prefer inner scopes if we're not anyway using one of the newest variables.
        let scopes = scopes
        if candidates.isEmpty && probability(0.75) {
            candidates = chooseBiased(from: scopes.elementsStartingAtBottom(), factor: 1.25)
            if let f = isIncluded {
                candidates = candidates.filter(f)
            }
        }

        // If we haven't found any candidates yet, take all visible variables into account.
        if candidates.isEmpty {
            let visibleVariables = variablesInScope
            if let f = isIncluded {
                candidates = visibleVariables.filter(f)
            } else {
                candidates = visibleVariables
            }
        }

        if candidates.isEmpty {
            return nil
        }

        return chooseUniform(from: candidates)
    }

    /// Find random variables to use as arguments for calling the specified function.
    ///
    /// This function will attempt to find variables that are compatible with the functions parameter types (if any). However,
    /// if no matching variables can be found for a parameter, this function will fall back to using a random variable. It is
    /// then the caller's responsibility to determine whether the function call can still be performed without raising a runtime
    /// exception or if it needs to be guarded against that.
    /// In this way, functions/methods for which no matching arguments currently exist can still be called (but potentially
    /// wrapped in a try-catch), which then gives future mutations (in particular Mutators such as the ProbingMutator) the
    /// chance to find appropriate arguments for the function.
    public func randomArguments(forCalling function: Variable) -> [Variable] {
        let signature = type(of: function).signature ?? Signature.forUnknownFunction
        return randomArguments(forCallingFunctionOfSignature: signature)
    }

    /// Find random variables to use as arguments for calling a function with the specified signature.
    ///
    /// See the comment above `randomArguments(forCalling function: Variable)` for caveats.
    public func randomArguments(forCallingFunctionOfSignature signature: Signature) -> [Variable] {
        assert(signature.numParameters == 0 || hasVisibleVariables)
        let parameterTypes = prepareArgumentTypes(forSignature: signature)
        let arguments = parameterTypes.map({ randomVariable(forUseAs: $0) ?? randomVariable() })
        return arguments
    }

    /// Find random variables to use as arguments for calling the specified method.
    ///
    /// See the comment above `randomArguments(forCalling function: Variable)` for caveats.
    public func randomArguments(forCallingMethod methodName: String, on object: Variable) -> [Variable] {
        let signature = methodSignature(of: methodName, on: object)
        return randomArguments(forCallingFunctionOfSignature: signature)
    }

    /// Find random variables to use as arguments for calling the specified method.
    ///
    /// See the comment above `randomArguments(forCalling function: Variable)` for caveats.
    public func randomArguments(forCallingMethod methodName: String, on objType: LuaType) -> [Variable] {
        let signature = methodSignature(of: methodName, on: objType)
        return randomArguments(forCallingFunctionOfSignature: signature)
    }

    /// Find the function rnum of rets
    public func getFunctionNumReturns(forCalling function: Variable) -> Int{
        let signature = type(of: function).signature ?? Signature.forUnknownFunction
        return signature.rets.count
    }

    /// Find the function rnum of rets
    public func getMethodNumReturns(of methodName: String, on object: Variable) -> Int{
        // let signature = type(of: function).signature ?? Signature.forUnknownFunction
        let signature = typeanaylzer.inferMethodSignature(of: methodName, on: object)
        return signature.rets.count
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
        assert(!visibleVariables.contains(variable))

        hiddenVariables.remove(variable)
        numberOfHiddenVariables -= 1
    }

    // This expands and collects types for arguments in function signatures.
    private func prepareArgumentTypes(forSignature signature: Signature) -> [LuaType] {
        var argumentTypes = [LuaType]()

        for param in signature.parameters {
            switch param {
            case .rest(let t):
                // "Unroll" the rest parameter
                for _ in 0..<Int.random(in: 0...5) {
                    argumentTypes.append(t)
                }
            case .opt(let t):
                // It's an optional argument, so stop here in some cases
                if probability(0.25) {
                    return argumentTypes
                }
                fallthrough
            case .plain(let t):
                argumentTypes.append(t)
            }
        }

        return argumentTypes
    }

    /// Type information access.
    public func type(of v: Variable) -> LuaType {
        return typeanaylzer.type(of: v)
    }

    public func type(ofProperty property: String, on v: Variable) -> LuaType {
        return typeanaylzer.inferPropertyType(of: property, on: v)
    }

    public func methodSignature(of methodName: String, on object: Variable) -> Signature {
        return typeanaylzer.inferMethodSignature(of: methodName, on: object)
    }

    public func methodSignature(of methodName: String, on objType: LuaType) -> Signature {
        return typeanaylzer.inferMethodSignature(of: methodName, on: objType)
    }

    ///
    /// Adoption of variables from a different program.
    /// Required when copying instructions between program.
    ///
    private var varMaps = [VariableMap<Variable>]()

    /// Prepare for adoption of variables from the given program.
    ///
    /// This sets up a mapping for variables from the given program to the
    /// currently constructed one to avoid collision of variable names.
    public func beginAdoption(from program: Program) {
        varMaps.append(VariableMap())
    }

    /// Finishes the most recently started adoption.
    public func endAdoption() {
        varMaps.removeLast()
    }

    /// Executes the given block after preparing for adoption from the provided program.
    public func adopting(from program: Program, _ block: () -> Void) {
        beginAdoption(from: program)
        block()
        endAdoption()
    }

    /// Maps a variable from the program that is currently configured for adoption into the program being constructed.
    public func adopt(_ variable: Variable) -> Variable {
        if !varMaps.last!.contains(variable) {
            varMaps[varMaps.count - 1][variable] = nextVariable()
        }

        return varMaps.last![variable]!
    }

    /// Maps a list of variables from the program that is currently configured for adoption into the program being constructed.
    public func adopt<Variables: Collection>(_ variables: Variables) -> [Variable] where Variables.Element == Variable {
        return variables.map(adopt)
    }

    /// Adopts an instruction from the program that is currently configured for adoption into the program being constructed.
    public func adopt(_ instr: Instruction) {
        internalAppend(Instruction(instr.op, inouts: adopt(instr.inouts)))
    }

    /// Append an instruction at the current position.
    public func append(_ instr: Instruction) {
        for v in instr.allOutputs {
            numVariables = max(v.number + 1, numVariables)
        }
        internalAppend(instr)
    }

    /// Append a program at the current position.
    ///
    /// This also renames any variable used in the given program so all variables
    /// from the appended program refer to the same values in the current program.
    public func append(_ program: Program) {
        adopting(from: program) {
            for instr in program.code {
                adopt(instr)
            }
        }
    }

    // Probabilities of remapping variables to host variables during splicing. These are writable so they can be reconfigured for testing.
    // We use different probabilities for outer and for inner outputs: while we rarely want to replace outer outputs, we frequently want to replace inner outputs
    // (e.g. function parameters) to avoid splicing function definitions that may then not be used at all. Instead, we prefer to splice only the body of such functions.
    var probabilityOfRemappingAnInstructionsOutputsDuringSplicing = 0.10
    var probabilityOfRemappingAnInstructionsInnerOutputsDuringSplicing = 0.75
    // The probability of including an instruction that may mutate a variable required by the slice (but does not itself produce a required variable).
    var probabilityOfIncludingAnInstructionThatMayMutateARequiredVariable = 0.5


    /// Splice code from the given program into the current program.
    ///
    /// Splicing computes a set of dependend (through dataflow) instructions in one program (called a "slice") and inserts it at the current position in this program.
    ///
    /// If the optional index is specified, the slice starting at that instruction is used. Otherwise, a random slice is computed.
    /// If mergeDataFlow is true, the dataflows of the two programs are potentially integrated by replacing some variables in the slice with "compatible" variables in the host program.
    /// Returns true on success (if at least one instruction has been spliced), false otherwise.
    @discardableResult
    public func splice(from program: Program, at specifiedIndex: Int? = nil, mergeDataFlow: Bool = true) -> Bool {
        // Splicing:
        //
        // Invariants:
        //  - A block is included in a slice in full (including its entire body) or not at all
        //  - An instruction can only be included if its required context is a subset of the current context
        //    OR if one or more of its surrounding blocks are included and all missing contexts are opened by them
        //  - An instruction can only be included if all its data-flow dependencies are included
        //    OR if the required variables have been remapped to existing variables in the host program
        //
        // Algorithm:
        //  1. Iterate over the program from start to end and compute for every block:
        //       - the inputs required by this block. This is the set of variables that are used as input
        //         for one or more instructions in the block's body, but are not created by instructions in the block
        //       - the context required by this block. This is the union of all contexts required by instructions
        //         in the block's body and subracting the context opened by the block itself
        //     In essence, this step allows treating every block start as a single instruction, which simplifies step 2.
        //  2. Iterate over the program from start to end and check which instructions can be inserted at the current
        //     position given the current context and the instruction's required context as well as the set of available
        //     variables and the variables required as inputs for the instruction. When deciding whether a block can be
        //     included, this will use the information computed in step 1 to treat the block as a single instruction
        //     (which it effectively is, as it will always be included in full). If an instruction can be included, its
        //     outputs are available for other instructions to use. If an instruction cannot be included, try to remap its
        //     outputs to existing and "compatible" variables in the host program so other instructions that depend on these
        //     variables can still be included. Also randomly remap some other variables to connect the dataflows of the two
        //     programs if that is enabled.
        //  3. Pick a random instruction from all instructions computed in step (2) or use the provided start index.
        //  4. Iterate over the program in reverse order and compute the slice: every instruction that creates an
        //     output needed as input for another instruction in the slice must be included as well. Step 2 guarantees that
        //     any such instruction can be part of the slice. Optionally, this step can also include instructions that may
        //     mutate variables required by the slice, for example property stores or method calls.
        //  5. Iterate over the program from start to end and add every instruction that is part of the slice into
        //     the current program, while also taking care of remapping the inouts, either to existing variables
        //     (if the variables were remapped in step (2)), or newly allocated variables.

        // Helper class to store various bits of information associated with a block.
        // This is a class so that each instruction belonging to the same block can have a reference to the same object.
        class Block {
            let startIndex: Int
            var endIndex = 0

            // Currently opened context. Updated at each block instruction.
            var currentlyOpenedContext: Context
            var requiredContext: Context

            var providedInputs = VariableSet()
            var requiredInputs = VariableSet()

            init(startedBy head: Instruction) {
                self.startIndex = head.index
                self.currentlyOpenedContext = head.op.contextOpened
                self.requiredContext = head.op.requiredContext
                self.requiredInputs.formUnion(head.inputs)
                self.providedInputs.formUnion(head.allOutputs)
            }
        }

        //
        // Step (1): compute the context- and data-flow dependencies of every block.
        //
        var blocks = [Int: Block]()

        // Helper functions for step (1).
        var activeBlocks = [Block]()
        func updateBlockDependencies(_ requiredContext: Context, _ requiredInputs: VariableSet) {
            guard let current = activeBlocks.last else { return }
            current.requiredContext.formUnion(requiredContext.subtracting(current.currentlyOpenedContext))
            current.requiredInputs.formUnion(requiredInputs.subtracting(current.providedInputs))
        }
        func updateBlockProvidedVariables(_ vars: ArraySlice<Variable>) {
            guard let current = activeBlocks.last else { return }
            current.providedInputs.formUnion(vars)
        }

        for instr in program.code {
            updateBlockDependencies(instr.op.requiredContext, VariableSet(instr.inputs))
            updateBlockProvidedVariables(instr.outputs)

            if instr.isBlockGroupStart {
                let block = Block(startedBy: instr)
                blocks[instr.index] = block
                activeBlocks.append(block)
            } else if instr.isBlockGroupEnd {
                let current = activeBlocks.removeLast()
                current.endIndex = instr.index
                blocks[instr.index] = current
                // Merge requirements into parent block (if any)
                updateBlockDependencies(current.requiredContext, current.requiredInputs)
                // If the block end instruction has any outputs, they need to be added to the surrounding block.
                updateBlockProvidedVariables(instr.outputs)
            } else if instr.isBlock {
                // We currently assume that inner block instructions cannot have outputs.
                // If they ever do, they'll need to be added to the surrounding block.
                assert(instr.numOutputs == 0)
                blocks[instr.index] = activeBlocks.last!

                // Inner block instructions change the execution context. Consider BeginWhileLoopBody as an example.
                activeBlocks.last?.currentlyOpenedContext = instr.op.contextOpened
            }

            updateBlockProvidedVariables(instr.innerOutputs)
        }

        //
        // Step (2): determine which instructions can be part of the slice and attempt to find replacement variables for the outputs of instructions that cannot be included.
        //
        // We need a typer to be able to find compatible replacement variables if we are merging the dataflows of the two programs.
        var typer = TypeAnaylzer(for: fuzzer.environment)
        // The set of variables that are available for a slice. A variable is available either because the instruction that outputs
        // it can be part of the slice or because the variable has been remapped to a host variable.
        var availableVariables = VariableSet()
        // Variables in the program that have been remapped to host variables.
        var remappedVariables = VariableMap<Variable>()
        // All instructions that can be included in the slice.
        var candidates = Set<Int>()

        // Helper functions for step (2).
        func tryRemapVariables(_ variables: ArraySlice<Variable>, of instr: Instruction) {
            guard mergeDataFlow else { return }
            guard hasVisibleVariables else { return }

            for v in variables {
                let type = typer.type(of: v)
                // For subroutines, the return type is only available once the subroutine has been fully processed.
                // Prior to that, it is assumed to be .anything. This may lead to incompatible functions being selected
                // as replacements (e.g. if the following code assumes that the return value must be of type X), but
                // is probably fine in practice.
                /// TODO: maybe improper
                // assert(!instr.hasOneOutput || v != instr.output || !(instr.op is BeginFunction) || (type.signature?.outputType ?? .anything) == .anything)
                // Try to find a compatible variable in the host program.
                if let replacement = randomVariable(forUseAs: type) {
                    remappedVariables[v] = replacement
                    availableVariables.insert(v)
                }
            }
        }
        func maybeRemapVariables(_ variables: ArraySlice<Variable>, of instr: Instruction, withProbability remapProbability: Double) {
            assert(remapProbability >= 0.0 && remapProbability <= 1.0)
            if probability(remapProbability) {
                tryRemapVariables(variables, of: instr)
            }
        }
        func getRequirements(of instr: Instruction) -> (requiredContext: Context, requiredInputs: VariableSet) {
            if let state = blocks[instr.index] {
                assert(instr.isBlock)
                return (state.requiredContext, state.requiredInputs)
            } else {
                return (instr.op.requiredContext, VariableSet(instr.inputs))
            }
        }
        func canSpliceOperation(of instr: Instruction) -> Bool {
            // Switch default cases cannot be spliced as there must only be one of them in a switch, and there is no
            // way to determine if the switch being spliced into has a default case or not.
            // Similarly, there must only be a single constructor in a class definition.
            // TODO: consider adding an Operation.Attribute for instructions that must only occur once if there are more such cases in the future.
            var instr = instr
            if let block = blocks[instr.index] {
                instr = program.code[block.startIndex]
            }
            return true
        }

        for instr in program.code {
            // Compute variable types to be able to find compatible replacement variables in the host program if necessary.
            typer.analyze(instr)

            // Maybe remap the outputs of this instruction to existing and "compatible" (because of their type) variables in the host program.
            maybeRemapVariables(instr.outputs, of: instr, withProbability: probabilityOfRemappingAnInstructionsOutputsDuringSplicing)
            maybeRemapVariables(instr.innerOutputs, of: instr, withProbability: probabilityOfRemappingAnInstructionsInnerOutputsDuringSplicing)

            // For the purpose of this step, blocks are treated as a single instruction with all the context and input requirements of the
            // instructions in their body. This is done through the getRequirements function which uses the data computed in step (1).
            let (requiredContext, requiredInputs) = getRequirements(of: instr)

            if requiredContext.isSubset(of: context) && requiredInputs.isSubset(of: availableVariables) && canSpliceOperation(of: instr) {
                candidates.insert(instr.index)
                // This instruction is available, and so are its outputs...
                availableVariables.formUnion(instr.allOutputs)
            } else {
                // While we cannot include this instruction, we may still be able to replace its outputs with existing variables in the host program
                // which will allow other instructions that depend on these outputs to be included.
                tryRemapVariables(instr.allOutputs, of: instr)
            }
        }

        //
        // Step (3): select the "root" instruction of the slice or use the provided one if any.
        //
        // Simple optimization: avoid splicing data-flow "roots", i.e. simple instructions that don't have any inputs, as this will
        // most of the time result in fairly uninteresting splices that for example just copy a literal from another program.
        // The exception to this are special instructions that exist outside of JavaScript context, for example instructions that add fields to classes.
        let rootCandidates = candidates.filter({ !program.code[$0].isSimple || program.code[$0].numInputs > 0 || !program.code[$0].op.requiredContext.contains(.script) })
        guard !rootCandidates.isEmpty else { return false }
        let rootIndex = specifiedIndex ?? chooseUniform(from: rootCandidates)
        guard rootCandidates.contains(rootIndex) else { return false }
        trace("Splicing instruction \(rootIndex) (\(program.code[rootIndex].op.name)) from \(program.id)")

        //
        // Step (4): compute the slice.
        //
        var slice = Set<Int>()
        var requiredVariables = VariableSet()
        var shouldIncludeCurrentBlock = false
        var startOfCurrentBlock = -1
        var index = rootIndex
        while index >= 0 {
            let instr = program.code[index]

            var includeCurrentInstruction = false
            if index == rootIndex {
                // This is the root of the slice, so include it.
                includeCurrentInstruction = true
                assert(candidates.contains(index))
            } else if shouldIncludeCurrentBlock {
                // This instruction is part of the slice because one of its surrounding blocks is included.
                includeCurrentInstruction = true
                // In this case, the instruction isn't necessarily a candidate (but at least one of its surrounding blocks is).
            } else if !requiredVariables.isDisjoint(with: instr.allOutputs) {
                // This instruction is part of the slice because at least one of its outputs is required.
                includeCurrentInstruction = true
                assert(candidates.contains(index))
            } else {
                // Also (potentially) include instructions that can modify one of the required variables if they can be included in the slice.
                if probability(probabilityOfIncludingAnInstructionThatMayMutateARequiredVariable) {
                    if candidates.contains(index) && instr.mayMutate(anyOf: requiredVariables) {
                        includeCurrentInstruction = true
                    }
                }
            }

            if includeCurrentInstruction {
                slice.insert(instr.index)

                // Only those inputs that we haven't picked replacements for are now also required.
                let newlyRequiredVariables = instr.inputs.filter({ !remappedVariables.contains($0) })
                requiredVariables.formUnion(newlyRequiredVariables)

                if !shouldIncludeCurrentBlock && instr.isBlock {
                    // We're including a block instruction due to its outputs. We now need to ensure that we include the full block with it.
                    shouldIncludeCurrentBlock = true
                    let block = blocks[index]!
                    startOfCurrentBlock = block.startIndex
                    index = block.endIndex + 1
                }
            }

            if index == startOfCurrentBlock {
                assert(instr.isBlockGroupStart)
                shouldIncludeCurrentBlock = false
                startOfCurrentBlock = -1
            }

            index -= 1
        }

        //
        // Step (5): insert the final slice into the current program while also remapping any missing variables to their replacements selected in step (2).
        //
        var variableMap = remappedVariables
        for instr in program.code where slice.contains(instr.index) {
            for output in instr.allOutputs {
                variableMap[output] = nextVariable()
            }
            let inouts = instr.inouts.map({ variableMap[$0]! })
            append(Instruction(instr.op, inouts: inouts))
        }

        trace("Splicing done")
        return true
    }


    // Code Building Algorithm:
    //
    // In theory, the basic building algorithm is simply:
    //
    //   var remainingBudget = initialBudget
    //   while remainingBudget > 0 {
    //       if probability(0.5) {
    //           remainingBudget -= runRandomCodeGenerator()
    //       } else {
    //           remainingBudget -= performSplicing()
    //       }
    //   }
    //
    // In practice, things become a little more complicated because code generators can be recursive: a function
    // generator will emit the function start and end and recursively call into the code building machinery to fill the
    // body of the function. The size of the recursively generated blocks is determined as a fraction of the parent's
    // *initial budget*. This ensures that the sizes of recursively generated blocks roughly follow the same
    // distribution. However, it also means that the initial budget can be overshot by quite a bit: we may end up
    // invoking a recursive generator near the end of our budget, which may then for example generate another 0.5x
    // initialBudget instructions. However, the benefit of this approach is that there are really only two "knobs" that
    // determine the "shape" of the generated code: the factor that determines the recursive budget relative to the
    // parent budget and the (absolute) threshold for recursive code generation.
    //

    /// The first "knob": this mainly determines the shape of generated code as it determines how large block bodies are relative to their surrounding code.
    /// This also influences the nesting depth of the generated code, as recursive code generators are only invoked if enough "budget" is still available.
    /// These are writable so they can be reconfigured in tests.
    var minRecursiveBudgetRelativeToParentBudget = 0.05
    var maxRecursiveBudgetRelativeToParentBudget = 0.50

    /// The second "knob": the minimum budget required to be able to invoke recursive code generators.
    public static let minBudgetForRecursiveCodeGeneration = 5

    /// Possible building modes. These are used as argument for build() and determine how the new code is produced.
    public enum BuildingMode {
        // Generate code by running CodeGenerators.
        case generating
        // Splice code from other random programs in the corpus.
        case splicing
        // Do all of the above.
        case generatingAndSplicing
    }

    // Keeps track of the state of one buildInternal() invocation. These are tracked in a stack, one entry for each recursive call.
    // This is a class so that updating the currently active state is possible without push/pop.
    private class BuildingState {
        let initialBudget: Int
        let mode: BuildingMode
        var recursiveBuildingAllowed = true
        var nextRecursiveBlockOfCurrentGenerator = 1
        var totalRecursiveBlocksOfCurrentGenerator: Int? = nil
        // An optional budget for recursive building.
        var recursiveBudget: Int? = nil

        init(initialBudget: Int, mode: BuildingMode) {
            assert(initialBudget > 0)
            self.initialBudget = initialBudget
            self.mode = mode
        }
    }
    private var buildStack = Stack<BuildingState>()

    /// Build random code at the current position in the program.
    ///
    /// The first parameter controls the number of emitted instructions: as soon as more than that number of instructions have been emitted, building stops.
    /// This parameter is only a rough estimate as recursive code generators may lead to significantly more code being generated.
    /// Typically, the actual number of generated instructions will be somewhere between n and 2x n.
    ///
    /// Building code requires that there are visible variables available as inputs for CodeGenerators or as replacement variables for splicing.
    /// When building new programs, `buildPrefix()` can be used to generate some initial variables. `build()` purposely does not call
    /// `buildPrefix()` itself so that the budget isn't accidentally spent just on prefix code (which is probably less interesting).
    public func build(n: Int = 1, by mode: BuildingMode = .generatingAndSplicing) {
        assert(buildStack.isEmpty)
        buildInternal(initialBuildingBudget: n, mode: mode)
        assert(buildStack.isEmpty)
    }

    /// Recursive code building. Used by CodeGenerators for example to fill the bodies of generated blocks.
    public func buildRecursive(block: Int = 1, of numBlocks: Int = 1, n optionalBudget: Int? = nil) {
        assert(!buildStack.isEmpty)
        let parentState = buildStack.top

        assert(parentState.mode != .splicing)
        assert(parentState.recursiveBuildingAllowed)        // If this fails, a recursive CodeGenerator is probably not marked as recursive.
        assert(numBlocks >= 1)
        assert(block >= 1 && block <= numBlocks)
        assert(parentState.nextRecursiveBlockOfCurrentGenerator == block)
        assert((parentState.totalRecursiveBlocksOfCurrentGenerator ?? numBlocks) == numBlocks)

        parentState.nextRecursiveBlockOfCurrentGenerator = block + 1
        parentState.totalRecursiveBlocksOfCurrentGenerator = numBlocks

        // Determine the budget for this recursive call as a fraction of the parent's initial budget.
        var recursiveBudget: Double
        if let specifiedBudget = parentState.recursiveBudget {
            assert(specifiedBudget > 0)
            recursiveBudget = Double(specifiedBudget)
        } else {
            let factor = Double.random(in: minRecursiveBudgetRelativeToParentBudget...maxRecursiveBudgetRelativeToParentBudget)
            assert(factor > 0.0 && factor < 1.0)
            let parentBudget = parentState.initialBudget
            recursiveBudget = Double(parentBudget) * factor
        }

        // Now split the budget between all sibling blocks.
        recursiveBudget /= Double(numBlocks)
        recursiveBudget.round(.up)
        assert(recursiveBudget >= 1.0)

        // Finally, if a custom budget was requested, choose the smaller of the two values.
        if let requestedBudget = optionalBudget {
            assert(requestedBudget > 0)
            recursiveBudget = min(recursiveBudget, Double(requestedBudget))
        }

        buildInternal(initialBuildingBudget: Int(recursiveBudget), mode: parentState.mode)
    }

    private func buildInternal(initialBuildingBudget: Int, mode: BuildingMode) {
        assert(hasVisibleVariables, "CodeGenerators and our splicing implementation assume that there are visible variables to use. Use buildPrefix() to generate some initial variables in a new program")
        assert(initialBuildingBudget > 0)

        // Both splicing and code generation can sometimes fail, for example if no other program with the necessary features exists.
        // To avoid infinite loops, we bail out after a certain number of consecutive failures.
        var consecutiveFailures = 0

        let state = BuildingState(initialBudget: initialBuildingBudget, mode: mode)
        buildStack.push(state)
        defer { buildStack.pop() }
        var remainingBudget = initialBuildingBudget

        // Unless we are only splicing, find all generators that have the required context. We must always have at least one suitable code generator.
        let origContext = context
        var availableGenerators = WeightedList<CodeGenerator>()
        if state.mode != .splicing {
            availableGenerators = fuzzer.codeGenerators.filter({ $0.requiredContext.isSubset(of: origContext) })
            assert(!availableGenerators.isEmpty)
        }
        
        while remainingBudget > 0 {
            assert(context == origContext, "Code generation or splicing must not change the current context")

            if state.recursiveBuildingAllowed &&
                remainingBudget < ProgramBuilder.minBudgetForRecursiveCodeGeneration &&
                availableGenerators.contains(where: { !$0.isRecursive }) {
                // No more recursion at this point since the remaining budget is too small.
                state.recursiveBuildingAllowed = false
                availableGenerators = availableGenerators.filter({ !$0.isRecursive })
                assert(state.mode == .splicing || !availableGenerators.isEmpty)
            }

            var mode = state.mode
            if mode == .generatingAndSplicing {
                mode = chooseUniform(from: [.generating, .splicing])
            }

            let codeSizeBefore = code.count
            
            switch mode {
            case .generating:
                assert(hasVisibleVariables)

                // Reset the code generator specific part of the state.
                state.nextRecursiveBlockOfCurrentGenerator = 1
                state.totalRecursiveBlocksOfCurrentGenerator = nil

                // Select a random generator and run it.
                let generator = availableGenerators.randomElement()
                run(generator)

            case .splicing:
                let program = fuzzer.corpus.randomElementForSplicing()
                splice(from: program)

            default:
                fatalError("Unknown ProgramBuildingMode \(mode)")
            }
            let codeSizeAfter = code.count
            let emittedInstructions = codeSizeAfter - codeSizeBefore
            remainingBudget -= emittedInstructions
            if emittedInstructions > 0 {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                guard consecutiveFailures < 10 else {
                    // This should happen very rarely, for example if we're splicing into a restricted context and don't find
                    // another sample with instructions that can be copied over, or if we get very unlucky with the code generators.
                    return
                }
            }
        }
    }

    /// Returns the next free label names
    public func nextLabel() -> String{
        numLabels += 1;
        return "l\(numLabels - 1)"
    }

    /// Returns the next free variable.
    func nextVariable(_ isLocal:Bool = false) -> Variable {
        assert(numVariables < Code.maxNumberOfVariables, "Too many variables")
        numVariables += 1
        return Variable(number: numVariables - 1,isLocal: isLocal)
    }

    /// Run ValueGenerators until we have created at least N new variables.
    /// Returns both the number of generated instructions and of newly created variables.
    @discardableResult
    public func buildValues(_ n: Int) -> (generatedInstructions: Int, generatedVariables: Int) {
        assert(buildStack.isEmpty)
        assert(context.contains(.script))

        let valueGenerators = fuzzer.codeGenerators.filter({ $0.isValueGenerator })
        assert(!valueGenerators.isEmpty)
        let previousNumberOfVisibleVariables = numberOfVisibleVariables
        var totalNumberOfGeneratedInstructions = 0

        // ValueGenerators can be recursive.
        // Here we create a builder stack entry for that case which gives each generator a fixed recursive
        // budget and allows us to run code generators or splice when building recursively.
        // The `initialBudget` isn't really used (since we specify a `recursiveBudget`), so can be an arbitrary value.
        let state = BuildingState(initialBudget: 2 * n, mode: fuzzer.corpus.isEmpty ? .generating : .generatingAndSplicing)
        state.recursiveBudget = n
        buildStack.push(state)
        defer { buildStack.pop() }

        while numberOfVisibleVariables - previousNumberOfVisibleVariables < n {
            let generator = valueGenerators.randomElement()
            assert(generator.requiredContext == .script && generator.inputTypes.isEmpty)

            state.nextRecursiveBlockOfCurrentGenerator = 1
            state.totalRecursiveBlocksOfCurrentGenerator = nil
            let numberOfGeneratedInstructions = run(generator)

            assert(numberOfGeneratedInstructions > 0, "ValueGenerators must always succeed")
            totalNumberOfGeneratedInstructions += numberOfGeneratedInstructions
        }
        return (totalNumberOfGeneratedInstructions, numberOfVisibleVariables - previousNumberOfVisibleVariables)
    }


    /// Bootstrap program building by creating some variables with statically known types.
    ///
    /// The `build()` method for generating new code or splicing from existing code can
    /// only be used once there are visible variables. This method can be used to generate some.
    ///
    /// Internally, this uses the ValueGenerators to generate some code. As such, the "shape"
    /// of prefix code is controlled in the same way as other generated code through the
    /// generator's respective weights.
    public func buildPrefix() {
        trace("Start of prefix code")
        buildValues(Int.random(in: 5...10))
        assert(numberOfVisibleVariables >= 5)
        trace("End of prefix code. \(numberOfVisibleVariables) variables are now visible")
    }

    /// Runs a code generator in the current context and returns the number of generated instructions.
    @discardableResult
    public func run(_ generator: CodeGenerator) -> Int {
        assert(generator.requiredContext.isSubset(of: context))

        var inputs: [Variable] = []
        for type in generator.inputTypes {
            guard let val = randomVariable(forUseAs: type) else { return 0 }
            inputs.append(val)
        }

        trace("Executing code generator \(generator.name)")
        let numGeneratedInstructions = generator.run(in: self, with: inputs)
        trace("Code generator finished")

        if numGeneratedInstructions > 0 {
            contributors.insert(generator)
            generator.addedInstructions(numGeneratedInstructions)
        }
        return numGeneratedInstructions
    }

    @discardableResult
    private func internalAppend(_ instr: Instruction) -> Instruction {
        // Basic integrity checking
        assert(!instr.inouts.contains(where: { $0.number >= numVariables }))
        // Context Checking
        assert(instr.op.requiredContext.isSubset(of: contextAnalyzer.context))

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
        assert(code.lastInstruction.op === instr.op)

        // print("\(instr.op), \(instr.outputs), \(instr.innerOutputs), \(instr.inputs)")
        // print("before \(scopes)")

        updateVariableAnalysis(instr)
        contextAnalyzer.analyze(instr)
        updateTableState(instr)
        typeanaylzer.analyze(instr)

        // print("after \(scopes)")
    }
    
    private var subroutine_stack = Stack<Subroutine>()
    private var r_stack = Stack<[String]>()
    private var t_stack = Stack<Int>()
    private var table_count = 0
    private var global_map = [Subroutine:[Variable]]()
    enum Subroutine: Hashable{
        case function(Variable)
        case tmp_method(String, Int)
        case method(String, Variable)
    }

    private var label_stack = Stack<[String]>([[]])
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
            label_stack.pop()
        }

        var outputs = instr.outputs
        switch instr.op.opcode{
        case .callFunction:
            outputs += global_map[.function(instr.input(0))] ?? []
        case .callMethod(let op):
            outputs += global_map[.method(op.methodName,instr.input(0))] ?? []
        default:
            break
        }

        if !subroutine_stack.isEmpty {
            scopes.top.append(contentsOf: outputs)
            outputs.forEach({
                if !$0.isLocal() { global_map[subroutine_stack.top]?.append($0)}
            })
        } else {
            scopes.bottom.append(contentsOf: outputs.filter({!$0.isLocal()}))
            scopes.top.append(contentsOf: outputs.filter({$0.isLocal()}))
        }

        switch instr.op.opcode {
        case .beginFunction:
            subroutine_stack.push(.function(instr.output))
            global_map[.function(instr.output)] = []
        case .endFunction:
            let _ = subroutine_stack.pop()
        case .beginTable:
            r_stack.push([])
            t_stack.push(table_count)
            table_count += 1
        case .endTable:
            let r = r_stack.pop()
            let t = t_stack.pop()
            for subroutine in r{
                global_map[.method(subroutine, instr.output)] = global_map[.tmp_method(subroutine,t)]
                global_map.removeValue(forKey: .tmp_method(subroutine, t))
            }
        case .beginTableMethod(let op):
            subroutine_stack.push(.tmp_method(op.methodName, t_stack.top))
            global_map[.tmp_method(op.methodName, t_stack.top)] = []
        case .endTableMethod:
            switch subroutine_stack.pop() {
            case .tmp_method(let s,_):
                r_stack.top.append(s)
            default:
                fatalError("miss match on beginTableMethod and endTableMethod")
            }
        case .label(let op):
            label_stack.top.append(op.value)
        default:
            break
            
        }
        // Scope management (2). Happens here since e.g. function definitions create a variable in the outer scope.
        if instr.isBlockStart {
            scopes.push([])
            label_stack.push([])
        }

        scopes.top.append(contentsOf: instr.innerOutputs)
    }

    private func updateTableState(_ instr: Instruction){
        switch instr.op.opcode{
        case .beginTable:
            activeTableDefinitions.push(TableDefinition(in: self))
        case .tableAddProperty(let op):
            currentTableDefinition.properties.append(op.propertyName)
        case .tableAddElement(let op):
            currentTableDefinition.elements.append(op.index)
        case .beginTableMethod(let op):
            currentTableDefinition.methods.append(op.methodName)
        case .endTableMethod:
            break
        case .endTable:
            activeTableDefinitions.pop()
        default:
            assert(!instr.op.requiredContext.contains(.objectLiteral))
            break
        }
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

    @discardableResult
    public func loadBoolean(_ value: Bool, isLocal: Bool = false) -> Variable {
        return emit(LoadBoolean(value: value),isLocal:isLocal).output
    }

    @discardableResult
    public func loadNil(isLocal: Bool = false) -> Variable {
        return emit(LoadNil(),isLocal:isLocal).output
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

        public static func parameters(n: Int, hasRestParameter: Bool = false) -> SubroutineDescriptor {
            return SubroutineDescriptor(withParameters: Parameters(count:n, hasRestParameter: hasRestParameter))
        }

        public static func parameters(params: Parameter...) -> SubroutineDescriptor {
            return parameters(ParameterList(params))
        }

        public static func parameters(_ parameterTypes: ParameterList) -> SubroutineDescriptor {
            let parameters = Parameters(count:parameterTypes.count, hasRestParameter: parameterTypes.hasRestParameter)
            return SubroutineDescriptor(withParameters: parameters, ofParaTypes: parameterTypes)
        }

        private init(withParameters parameters: Parameters, ofParaTypes parameterTypes: ParameterList? = nil) {
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

    public func doReturn(_ value: [Variable]) {
        emit(Return(numInputs: value.count), withInputs: value)
    }


    @discardableResult
    public func unary(_ op: UnaryOperator, _ input: Variable) -> Variable {
        return emit(UnaryOperation(op), withInputs: [input]).output
    }

    @discardableResult
    public func binary(_ lhs: Variable, _ rhs: Variable, with op: BinaryOperator) -> Variable {
        return emit(BinaryOperation(op), withInputs: [lhs, rhs]).output
    }

    public func reassign(_ output: Variable, to input: Variable, with op: BinaryOperator) {
        emit(Update(op), withInputs: [output, input])
    }

    public func reassign(_ output: Variable, to input: Variable) {
        emit(Reassign(), withInputs: [output, input])
    }

    @discardableResult
    public func compare(_ lhs: Variable, with rhs: Variable, using comparator: Comparator) -> Variable {
        return emit(Compare(comparator), withInputs: [lhs, rhs]).output
    }

    @discardableResult
    public func callFunction(_ function: Variable, withArgs arguments: [Variable] = [], numReturns: Int = 0) -> [Variable] {
        return Array(emit(CallFunction(numArguments: arguments.count, numReturns: numReturns), withInputs: [function] + arguments).outputs)
    }

    @discardableResult
    public func createArray(with initialValues: [Variable]) -> Variable {
        return emit(CreateArray(numInitialValues: initialValues.count), withInputs: initialValues).output
    }

    @discardableResult
    public func loadBuiltin(_ name: String) -> Variable {
        return emit(LoadBuiltin(builtinName: name)).output
    }

    @discardableResult
    public func getProperty(_ name: String, of object: Variable) -> Variable {
        return emit(GetProperty(propertyName: name), withInputs: [object]).output
    }

    public func setProperty(_ name: String, of object: Variable, to value: Variable) {
        emit(SetProperty(propertyName: name), withInputs: [object, value])
    }

    public func updateProperty(_ name: String, of object: Variable, with value: Variable, using op: BinaryOperator) {
        emit(UpdateProperty(propertyName: name, operator: op), withInputs: [object, value])
    }

    public func deleteProperty(_ name: String, of object: Variable) {
        emit(DeleteProperty(propertyName: name), withInputs: [object])
    }

    @discardableResult
    public func getElement(_ index: Int64, of array: Variable) -> Variable {
        return emit(GetElement(index: index), withInputs: [array]).output
    }

    public func setElement(_ index: Int64, of array: Variable, to value: Variable) {
        emit(SetElement(index: index), withInputs: [array, value])
    }

    public func updateElement(_ index: Int64, of array: Variable, with value: Variable, using op: BinaryOperator) {
        emit(UpdateElement(index: index, operator: op), withInputs: [array, value])
    }

    public func deleteElement(_ index: Int64, of array: Variable) {
        emit(DeleteElement(index: index), withInputs: [array])
    }

    @discardableResult
    public func callMethod(_ name: String, on object: Variable, withArgs arguments: [Variable] = [], numReturns: Int = 0, guard isGuarded: Bool = false) -> [Variable] {
        return Array(emit(CallMethod(methodName: name, numArguments: arguments.count, numReturns: numReturns), withInputs: [object] + arguments).outputs)
    }

    @discardableResult
    public func buildPair(_ obj: Variable) -> Variable{
        return emit(LoadPair(), withInputs: [obj]).output
    }

    public func buildIf(_ condition: Variable, ifBody: () -> Void) {
        emit(BeginIf(inverted: false), withInputs: [condition])
        ifBody()
        emit(EndIf())
    }

    public func buildIfElse(_ condition: Variable, ifBody: () -> Void, elseBody: () -> Void) {
        emit(BeginIf(inverted: false), withInputs: [condition])
        ifBody()
        emit(BeginElse())
        elseBody()
        emit(EndIf())
    }
    public func buildWhileLoop(_ header: () -> Variable, _ body: () -> Void) {
        emit(BeginWhileLoopHeader())
        let cond = header()
        emit(BeginWhileLoopBody(), withInputs: [cond])
        body()
        emit(EndWhileLoop())
    }

    // Build a simple for loop that declares one loop variable.
    public func buildForLoop(i initializer: () -> Variable, _ cond: () -> Variable, _ afterthought: (() -> Variable)? = nil, _ body: (Variable) -> ()) {
        emit(BeginForLoopInitializer())
        let initialValue = initializer()
        var loopVar = emit(BeginForLoopCondition(), withInputs: [initialValue]).innerOutput
        let cond = cond()
        loopVar = emit(BeginForLoopAfterthought(), withInputs: [cond]).innerOutput
        if let afterthought =  afterthought?() {
            loopVar = emit(BeginForLoopBody(numInputs: 1), withInputs: [afterthought]).innerOutput
        }
        else{
            loopVar = emit(BeginForLoopBody(numInputs: 0)).innerOutput
        }
        body(loopVar)
        emit(EndForLoop())
    }

    public func buildForInLoop(_ obj: Variable, _ body: ([Variable]) -> ()) {
        var n = 0;
        if let signature = type(of: obj).functionSignature { n = signature.rets.count}
        let i = emit(BeginForInLoop(numInnerOutputs: n), withInputs: [obj]).innerOutputs
        body(Array(i))
        emit(EndForInLoop())
    }

    public func buildRepeatLoop(n numIterations: Int, _ body: (Variable) -> ()) {
        let i = emit(BeginRepeatLoop(iterations: numIterations)).innerOutput
        body(i)
        emit(EndRepeatLoop())
    }

    public func buildRepeatLoop(n numIterations: Int, _ body: () -> ()) {
        emit(BeginRepeatLoop(iterations: numIterations, exposesLoopCounter: false))
        body()
        emit(EndRepeatLoop())
    }
    
    public func loopBreak() {
        emit(LoopBreak())
    }
    public func buildLabel(_ name: String){
        emit(Label(name))
    }
    public func buildGoto(_ target: String){
        emit(Goto(target))
    }
    /// Represents a currently active class definition. Used to add fields to it and to query which fields already exist.
    public class TableDefinition {
        private let b: ProgramBuilder

        public fileprivate(set) var properties: [String] = []
        public fileprivate(set) var elements: [Int64] = []
        public fileprivate(set) var methods: [String] = []

        fileprivate init(in b: ProgramBuilder) {
            assert(b.context.contains(.objectLiteral))
            self.b = b
        }
        public func addTableProperty(_ name: String, value: Variable? = nil) {
            let inputs = value != nil ? [value!] : []
            b.emit(TableAddProperty(propertyName: name, hasValue: value != nil), withInputs: inputs)
        }

        public func addTableElement(_ index: Int64, value: Variable){
            b.emit(TableAddElement(index: index), withInputs: [value])
        }

        public func addMethod(_ name: String, with descriptor: SubroutineDescriptor, _ body: ([Variable]) -> ()) {
            b.setParameterTypesForNextSubroutine(descriptor.parameterTypes)
            let instr = b.emit(BeginTableMethod(methodName: name, parameters: descriptor.parameters))
            body(Array(instr.innerOutputs))
            b.emit(EndTableMethod())
        }
    }


    @discardableResult
    public func buildTable(_ body: (TableDefinition) -> ()) -> Variable {
        emit(BeginTable())
        body(currentTableDefinition)
        return emit(EndTable()).output
    }

}