public struct TypeAnaylzer: Analyzer {
    // The environment model from which to obtain various pieces of type information.
    private let environment: Environment

    // The current state
    private var state = AnalyzerState()

    // Parameter types for subroutines defined in the analyzed program.
    // These are keyed by the index of the start of the subroutine definition.
    private var signatures = [Int: ParameterList]()

    // Tracks the active function definitions and contains the instruction that started the function.
    private var activeFunctionDefinitions = Stack<Instruction>()    

    // A stack for active for loops containing the types of the loop variables.
    private var activeForLoopVariableTypes = Stack<[LuaType]>()

    // Stack of active object literals. Each entry contains the current type of the object created by the literal.
    // This must be a stack as object literals can be nested (e.g. an object literal inside the method of another one).
    private var activeTables = Stack<LuaType>()

    // The index of the last instruction that was processed. Just used for debug assertions.
    private var indexOfLastInstruction = -1

    init(for environ: Environment) {
        self.environment = environ
    }

    public mutating func reset() {
        indexOfLastInstruction = -1
        state.reset()
        signatures.removeAll()
        assert(activeFunctionDefinitions.isEmpty)
        assert(activeTables.isEmpty)
    }
    // Array for collecting type changes during instruction execution.
    // Not currently used, by could be used for example to validate the analysis by adding these as comments to programs.
    private var typeChanges = [(Variable, LuaType)]()

    /// Analyze the given instruction, thus updating type information.
    public mutating func analyze(_ instr: Instruction) {
        assert(instr.index == indexOfLastInstruction + 1)
        indexOfLastInstruction += 1
        // Reset type changes array before instruction execution.
        typeChanges = []
        processTypeChangesBeforeScopeChanges(instr)

        processScopeChanges(instr)

        processTypeChangesAfterScopeChanges(instr)
        // Sanity checking: every output variable must now have a type.
        assert(instr.allOutputs.allSatisfy(state.hasType))

    }

    /// Sets a program-wide signature for the instruction at the given index, which must be the start of a function or method definition.
    public mutating func setParameters(forSubroutineStartingAt index: Int, to parameterTypes: ParameterList) {
        // Currently we expect this to only be used for the next instruction.
        assert(index == indexOfLastInstruction + 1)
        signatures[index] = parameterTypes
    }

    public func inferMethodSignature(of methodName: String, on objType: LuaType) -> Signature {
        return environment.signature(ofMethod: methodName, on: objType)
    }

    /// Attempts to infer the signature of the given method on the given object type.
    public func inferMethodSignature(of methodName: String, on object: Variable) -> Signature {
        return inferMethodSignature(of: methodName, on: state.type(of: object))
    }
   
    /// Attempts to infer the type of the given property on the given object type.
    public func inferPropertyType(of propertyName: String, on objType: LuaType) -> LuaType {
        return environment.type(ofProperty: propertyName, on: objType)
    }

    /// Attempts to infer the type of the given property on the given object type.
    public func inferPropertyType(of propertyName: String, on object: Variable) -> LuaType {
        return inferPropertyType(of: propertyName, on: state.type(of: object))
    }


    public mutating func setType(of v: Variable, to t: LuaType) {
        assert(t != .nothing)
        state.updateType(of: v, to: t)
    }

    public func type(of v: Variable) -> LuaType {
        return state.type(of: v)
    }

    // Set type to current state and save type change event
    private mutating func set(_ v: Variable, _ t: LuaType) {
        // Record type change if:
        // 1. It is first time we set the type of this variable
        // 2. The type is different from the previous type of that variable
        if !state.hasType(for: v) || state.type(of: v) != t {
            typeChanges.append((v, t))
        }
        setType(of: v, to: t)
    }

    /// Attempts to infer the parameter types of the given subroutine definition.
    /// If parameter types have been added for this function, they are returned, otherwise generic parameter types (i.e. .anything parameters) for the parameters specified in the operation are generated.
    private func inferSubroutineParameterList(of op: BeginFunction, at index: Int) -> ParameterList {
        return signatures[index] ?? ParameterList(numParameters: op.parameters.count, hasRestParam: op.parameters.hasRestParameter)
    }

    /// Attempts to infer the parameter types of the given subroutine definition.
    /// If parameter types have been added for this function, they are returned, otherwise generic parameter types (i.e. .anything parameters) for the parameters specified in the operation are generated.
    private func inferSubroutineParameterList(of op: BeginTableMethod, at index: Int) -> ParameterList {
        return signatures[index] ?? ParameterList(numParameters: op.parameters.count, hasRestParam: op.parameters.hasRestParameter)
    }

    /// Attempts to infer the return value type of the given function.
    private func inferCallResultType(of function: Variable) -> ParameterList {
        if let signature = state.type(of: function).functionSignature {
            return signature.rets
        }
        return []
    }

    private mutating func processTypeChangesBeforeScopeChanges(_ instr: Instruction) {
        switch instr.op.opcode {
        case .beginFunction(let op):
            let paralist = inferSubroutineParameterList(of: op, at: instr.index)
            set(instr.output, .function(paralist => []))
        default:   
            assert(instr.numOutputs == 0 || !instr.isBlockStart)
        }

    }
    private mutating func processScopeChanges(_ instr: Instruction) {
        switch instr.op.opcode {
        case .beginTable,
             .endTable:
            break
        case .beginFunction:
            activeFunctionDefinitions.push(instr)
            state.startSubroutine()
        case .endFunction:
            let begin = activeFunctionDefinitions.pop()
            let returnValueType = state.endSubroutine(typeChanges: &typeChanges, defaultReturnValueType: [])
            if begin.numOutputs == 1 {
                let funcType = state.type(of: begin.output)
                if let signature = funcType.signature{
                    setType(of: begin.output, to:funcType.settingSignature(to: signature.parameters => returnValueType))
                }
            }
        case .beginIf:
            state.startGroupOfConditionallyExecutingBlocks()
            state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
        case .beginElse:
            state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
        case .endIf:
            if !state.currentBlockHasAlternativeBlock {
                // This If doesn't have an Else block, so append an empty block representing the state if the If-body is not executed.
                state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
            }
            state.endGroupOfConditionallyExecutingBlocks(typeChanges: &typeChanges)  
        case .beginForLoopInitializer,
             .beginForLoopCondition:
            // The initializer and the condition of a for-loop's header execute unconditionally.
            break
        case .beginForLoopAfterthought:
            // A for-loop's afterthought and body block execute conditionally.
            state.startGroupOfConditionallyExecutingBlocks()
            // We add an empty block to represent the state when the body and afterthought are never executed.
            state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
            // Then we add a block to represent the state when they are executed.
            state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
        case .beginForLoopBody:
            // We keep using the state for the loop afterthought here.
            // TODO, technically we should execute the body before the afterthought block...
            break
        case .endForLoop:
            state.endGroupOfConditionallyExecutingBlocks(typeChanges: &typeChanges)
        case .beginWhileLoopHeader:
            // Loop headers execute unconditionally (at least once).
            break
        case .beginWhileLoopBody,
             .beginForInLoop,
            //  .beginForOfLoopWithDestruct,
             .beginRepeatLoop:
            //  .beginCodeString:
            state.startGroupOfConditionallyExecutingBlocks()
            // Push an empty state representing the case when the loop body (or code string) is not executed at all
            state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
            // Push a new state tracking the types inside the loop
            state.enterConditionallyExecutingBlock(typeChanges: &typeChanges)
        case .endWhileLoop,
             .endForInLoop,
             .endRepeatLoop:
            //  .endCodeString:
            state.endGroupOfConditionallyExecutingBlocks(typeChanges: &typeChanges)
        case .beginTableMethod:
            activeFunctionDefinitions.push(instr)
            state.startSubroutine()
        case .endTableMethod:
            let begin = activeFunctionDefinitions.pop()
            let returnValueType = state.endSubroutine(typeChanges: &typeChanges, defaultReturnValueType: [])
            switch begin.op.opcode{
            case .beginTableMethod(let op):
                let paramlist = inferSubroutineParameterList(of: op, at: instr.index)
                activeTables.top.add(method:op.methodName, signature: paramlist => returnValueType)
            default:
                fatalError("endTableMethod doesn't match with beginTableMethod")
            }
            
        default:
            assert(instr.isSimple)

        }

    }
    private mutating func processTypeChangesAfterScopeChanges(_ instr: Instruction) {
        func type(ofInput inputIdx: Int) -> LuaType {
            return state.type(of: instr.input(inputIdx))
        }
        // Helper function to process parameters
        func processParameterDeclarations(_ parameterVariables: ArraySlice<Variable>, parameters: ParameterList) {
            let types = computeParameterTypes(from: parameters)
            assert(types.count == parameterVariables.count)
            for (param, type) in zip(parameterVariables, types) {
                set(param, type)
            }
        }


        // Helper function to set output type of binary/reassignment operations
        func analyzeBinaryOperation(operator op: BinaryOperator, withInputs inputs: ArraySlice<Variable>) -> LuaType {
            // switch op {
            // case .Add,
            //      .Sub,
            //      .Mul,
            //      .Exp,
            //      .Div,
            //      .Mod,
            //      .Divisible:
            //     return .number
            // case .LogicAnd:
            //     if state.type(of: inputs[0]) == .boolean || state.type(of: inputs[1]) == .boolean {return .boolean}
            //     else {return state.type(of: inputs[1])}
            // case .LogicOr:
            //     if state.type(of: inputs[0]) == .boolean || state.type(of: inputs[1]) == .boolean {return .boolean}
            //     else {return state.type(of: inputs[0])}            
            // case .Concat:
            //     return environment.stringType
            // }
            analyzeBinaryOperation(operator: op, withInputs: inputs.map({state.type(of: $0)}))
        }

        // Helper function to set output type of binary/reassignment operations
        func analyzeBinaryOperation(operator op: BinaryOperator, withInputs inputsType: [LuaType]) -> LuaType {
            switch op {
            case .Add,
                 .Sub,
                 .Mul,
                 .Exp,
                 .Div,
                 .Mod,
                 .Divisible:
                return .number
            case .LogicAnd:
                if inputsType[0] == .boolean ||  inputsType[1] == .boolean {return .boolean}
                else {return  inputsType[1]}
            case .LogicOr:
                if  inputsType[0] == .boolean ||  inputsType[1] == .boolean {return .boolean}
                else {return  inputsType[0]}            
            case .Concat:
                return environment.stringType
            }
        }
        // Helper function for operations whose results
        // can only be a .bigint if an input to it is
        // a .bigint.
        func maybeBigIntOr(_ t: LuaType) -> LuaType {
            var outputType = t
            var allInputsAreBigint = true
            for i in 0..<instr.numInputs {
                if type(ofInput: i).MayBe(.number) {
                    outputType |= .number
                }
                if !type(ofInput: i).Is(.number) {
                    allInputsAreBigint = false
                }
            }
            return allInputsAreBigint ? .number : outputType
        }
        switch instr.op.opcode {
        case .loadBuiltin(let op):
            set(instr.output, environment.type(ofBuiltin: op.builtinName))
        case .loadNumber:
            set(instr.output, .number)      

        case .loadString:
            set(instr.output, environment.stringType)

        case .loadBoolean:
            set(instr.output, .boolean)

        case .loadNil:
            set(instr.output, .undefined)
        case .loadPair:
            set(instr.output, .iterable + .function([] => [.number, .plain(type(ofInput: 0))]))
        case .reassign:
            set(instr.input(0), type(ofInput: 1))
        case .unaryOperation(let op):
            switch op.op{
                case .Minus,
                     .Length:
                    set(instr.output, .number)
                case .LogicalNot:
                    set(instr.output, .boolean)
            }

        case .binaryOperation(let op):
            set(instr.output,analyzeBinaryOperation(operator: op.op, withInputs: instr.inputs))
        case .update(let op):
            set(instr.input(0), analyzeBinaryOperation(operator: op.op, withInputs: instr.inputs))
        case .compare:
            set(instr.output, .boolean)

        case .beginFunction(let op):
            processParameterDeclarations(instr.innerOutputs, parameters: inferSubroutineParameterList(of: op, at: instr.index))
        case .return(let op):
            if op.hasReturnValue{
                state.updateReturnValueType(to: (0..<op.numInputs).map({.plain(type(ofInput: $0))}))
            }

            // else {
            //     // TODO this isn't correct e.g. for constructors (where the return value would be `this`).
            //     // To fix that, we could for example add a "placeholder" return value that is replaced by
            //     // the default return value at the end of the subroutine.
            //     state.updateReturnValueType(to: [])
            // }

        case .callFunction:
            let output_type = computeParameterTypes(from: inferCallResultType(of: instr.input(0)))
            let n = output_type.count
            for (idx, v) in instr.outputs.enumerated(){
                if idx < n{
                    set(v, output_type[idx])
                }
                else{
                    set(v, .undefined)
                }
            }
        case .callMethod(let op):
            let output_type = computeParameterTypes(from:inferMethodSignature(of: op.methodName, on: instr.input(0)).rets)
            let n = output_type.count
            for (idx, v) in instr.outputs.enumerated(){
                if idx < n{
                    set(v, output_type[idx])
                }
                else{
                    set(v, .undefined)
                }
            }
        case .beginForLoopCondition:
            // For now, we use only the initial type of the loop variables (at the point of the for-loop's initializer block)
            // without tracking any type changes in the other parts of the for loop.
            let inputTypes = instr.inputs.map({ state.type(of: $0) })
            activeForLoopVariableTypes.push(inputTypes)
            assert(inputTypes.count == instr.numInnerOutputs)
            zip(instr.innerOutputs, inputTypes).forEach({ set($0, $1) })

        case .beginForLoopAfterthought:
            let inputTypes = activeForLoopVariableTypes.top
            assert(inputTypes.count == instr.numInnerOutputs)
            zip(instr.innerOutputs, inputTypes).forEach({ set($0, $1) })

        case .beginForLoopBody:
            let inputTypes = activeForLoopVariableTypes.pop()
            assert(inputTypes.count == instr.numInnerOutputs)
            zip(instr.innerOutputs, inputTypes).forEach({ set($0, $1) })
        case .beginForInLoop:
            // set(instr.innerOutput, environment.stringType)
            let output_type = computeParameterTypes(from: inferCallResultType(of: instr.input(0)))
            let n = output_type.count
            for (idx, v) in instr.innerOutputs.enumerated(){
                if idx < n{
                    set(v, output_type[idx])
                }
                else{
                    set(v, .undefined)
                }
            }
        case .beginRepeatLoop(let op):
            if op.exposesLoopCounter {
                set(instr.innerOutput, .number)
            }
        case .createArray:
            set(instr.output,LuaType.table(ofGroup: "table", withArrayType: Dictionary(uniqueKeysWithValues: zip(0...instr.numInputs + 1, [.undefined] + instr.inputs.map({state.type(of: $0)})))))

        case .getProperty(let op):
            set(instr.output, inferPropertyType(of: op.propertyName, on: instr.input(0)))

        case .setProperty(let op):
            set(instr.input(0), type(ofInput: 0).adding(property: op.propertyName, propertyType: type(ofInput: 1)))

        case .updateProperty(let op):
            set(instr.input(0), type(ofInput: 0).adding(property: op.propertyName, propertyType: analyzeBinaryOperation(operator: op.op, withInputs: [inferPropertyType(of: op.propertyName, on: instr.input(0)), type(ofInput: 1)])))

        case .deleteProperty(let op):
            set(instr.input(0), type(ofInput: 0).removing(property: op.propertyName))

        case .getElement(let op):
            set(instr.output, type(ofInput: 0).arraytype[Int(op.index)] ?? .undefined)

        case .setElement(let op):
            set(instr.input(0), type(ofInput: 0).adding(index: Int(op.index), elementType: type(ofInput: 1)))

        case .updateElement(let op):
            set(instr.input(0), type(ofInput: 0).adding(index: Int(op.index), elementType:analyzeBinaryOperation(operator: op.op, withInputs: [type(ofInput: 0).arraytype[Int(op.index)] ?? .undefined, type(ofInput: 1)]) ))
        
        case .deleteElement(let op):
            set(instr.input(0), type(ofInput: 0).removing(index: Int(op.index)))
        case .beginTable:
            activeTables.push(.table())
        case .tableAddProperty(let op):
            activeTables.top.add(property: op.propertyName, propertyType: op.hasValue ? type(ofInput: 0) : .undefined)
        case .tableAddElement(let op):
            activeTables.top.add(index: Int(op.index), elementType: type(ofInput: 0))
        case .beginTableMethod(let op):
            processParameterDeclarations(instr.innerOutputs, parameters: inferSubroutineParameterList(of: op, at: instr.index))
        case .endTable:
            let objectType = activeTables.pop()
            set(instr.output, objectType)
        default:
            // Only simple instructions and block instruction with inner outputs are handled here
            assert(instr.numOutputs == 0 || (instr.isBlock && instr.numInnerOutputs == 0))
        }
    }

    private func computeParameterTypes(from parameters: ParameterList) -> [LuaType] {
        var types: [LuaType] = []
        parameters.forEach { param in
            switch param {
            case .plain(let t):
                types.append(t)
            case .opt(let t):
                types.append(t | .undefined)
            case .rest:
                // A rest parameter will just be an array. Currently, we don't support nested array types (i.e. .iterable(of: .integer)) or so, but once we do, we'd need to update this logic.
                /// TODO: rest
                types.append(environment.tableType)
            }
        }
        return types
    }
    private struct AnalyzerState {
        // Represents the execution state at one point in a CFG.
        //
        // This must be a reference type as it is referred to from
        // member variables as well as being part of the state stack.
        private class State {
            var types = VariableMap<LuaType>()

            // Whether this state represents a subroutine, in which case it also
            // tracks its return value type.
            let isSubroutineState: Bool
            // Holds the current type of the return value. This is also tracked in
            // states that are not subroutines, as one of their parent states may
            // be a subroutine.
            var returnValueType: ParameterList = []
            // Whether all execution paths leading to this state have already returned,
            // in which case the return value type will not be updated again.
            var hasReturned = false

            init(isSubroutineState: Bool = false) {
                self.isSubroutineState = isSubroutineState
            }
        }

        // The current execution state. There is a new level (= array of states)
        // pushed onto this stack for every CFG structure with conditional execution
        // (if-else, loops, ...). Each level then has as many states as there are
        // conditional branches, e.g. if-else has two states, if-elseif-elseif-else
        // would have four and so on.
        //
        // Each state in the stack only stores information that was updated in the
        // corresponding block. As such, there may be a type for a variable in a
        // parent state but not a child state (if the variable's type doesn't change
        // inside the child block). However, there's an invariant that if the active
        // state contains a type (that's not .nothing, see below) for V, then its
        // parent state must also contain a type for V: if the variable is only defined
        // in the child state, it's type in the parent state will be set to .nothing.
        // If the variable is changed in a child state but not its parent state, then
        // the type in the parent state will be the most recent type for V in its parent 
        // states. This invariant is necessary to be able to correctly update types when
        // leaving scopes as that requires knowing the type in the surrounding scope.
        //
        // It would be simpler to have the types of all visible variables in all active
        // states, but this way of implementing state tracking is significantly faster.
        private var states: Stack<[State]>

        // Always points to the active state: the newest state in the top most level of the stack
        private var activeState: State
        // Always points to the parent state: the newest state in the second-to-top level of the stack
        private var parentState: State

        // The full state at the current position. In essence, this is just a cache.
        // The same information could be retrieved by walking the state stack starting
        // from the activeState until there is a value for the queried variable.
        private var overallState: State

        init() {
            activeState = State()
            parentState = State()
            states = Stack([[parentState], [activeState]])
            overallState = State()
        }

        mutating func reset() {
            self = AnalyzerState()
        }

        /// Return the current type of the given variable.
        /// Return .anything for variables not available in this state.
        func type(of variable: Variable) -> LuaType {
            return overallState.types[variable] ?? .anything
        }

        func hasType(for v: Variable) -> Bool {
            return overallState.types[v] != nil
        }

        /// Set the type of the given variable in the current state.
        mutating func updateType(of v: Variable, to newType: LuaType, from oldType: LuaType? = nil) {
            // Basic consistency checking. This seems like a decent
            // place to do this since it executes frequently.
            assert(activeState === states.top.last!)
            assert(parentState === states.secondToTop.last!)
            // If an oldType is specified, it must match the type in the next most recent state
            // (but here we just check that one of the parent states contains it).
            assert(oldType == nil || states.elementsStartingAtTop().contains(where: { $0.last!.types[v] == oldType! }))

            // Set the old type in the parent state if it doesn't yet exist to satisfy "activeState[v] != nil => parentState[v] != nil".
            // Use .nothing to express that the variable is only defined in the child state.
            let oldType = oldType ?? overallState.types[v] ?? .nothing
            if parentState.types[v] == nil {
                parentState.types[v] = oldType
            }
            // Integrity checking: if the type of v hasn't previously been updated in the active
            // state, then the old type must be equal to the type in the parent state.
            /// TODO: maybe improper
            // assert(activeState.types[v] != nil || parentState.types[v] == oldType)

            activeState.types[v] = newType
            overallState.types[v] = newType
        }

        mutating func updateReturnValueType(to t: ParameterList) {
            assert(states.elementsStartingAtTop().contains(where: { $0.last!.isSubroutineState }), "Handling a `return` but neither the active state nor any of its parent states represents a subroutine")
            guard !activeState.hasReturned else {
                // In this case, we have already set the return value in this branch of (conditional)
                // execution and so are executing inside dead code, so don't update the return value.
                return
            }
            activeState.returnValueType = t
            activeState.hasReturned = true
        }

        /// Start a new group of conditionally executing blocks.
        ///
        /// At runtime, exactly one of the blocks in this group (added via `enterConditionallyExecutingBlock`) will be
        /// executed. A group of conditionally executing blocks should consist of at least two blocks, otherwise
        /// the single block will be treated as executing unconditionally.
        /// For example, an if-else would be represented by a group of two blocks, while a group representing
        /// a switch-case may contain many blocks. However, a switch-case consisting only of a default case is a
        /// a legitimate example of a group of blocks consisting of a single block (which then executes unconditionally).
        mutating func startGroupOfConditionallyExecutingBlocks() {
            parentState = activeState
            states.push([])
        }

        /// Enter a new conditionally executing block and append it to the currently active group of such blocks.
        /// As such, either this block or one of its "sibling" blocks in the current group may execute at runtime.
        mutating func enterConditionallyExecutingBlock(typeChanges: inout [(Variable, LuaType)]) {
            assert(states.top.isEmpty || !states.top.last!.isSubroutineState)

            // Reset current state to parent state
            for (v, t) in activeState.types {
                // Do not save type change if
                // 1. Variable does not exist in sibling scope (t == .nothing)
                // 2. Variable is only local in sibling state (parent == .nothing)
                // 3. No type change happened
                if t != .nothing && parentState.types[v] != .nothing && parentState.types[v] != overallState.types[v] {
                    typeChanges.append((v, parentState.types[v]!))
                    overallState.types[v] = parentState.types[v]!
                }
            }

            activeState = State()
            states.top.append(activeState)
        }

        /// Remove the state for the first block in the current group of conditionally executing blocks.
        /// The removed state must be empty. This is for example useful for handling default cases
        /// in switch blocks, see the corresponding handler for an example.
        mutating func removeFirstBlockFromCurrentGroup() {
            let state = states.top.removeFirst()
            assert(state.types.isEmpty)
        }

        /// Finalize the current group of conditionally executing blocks.
        ///
        /// This will compute the new variable types assuming that exactly one of the blocks in the group will be executed
        /// at runtime and will then return to the previously active state.
        mutating func endGroupOfConditionallyExecutingBlocks(typeChanges: inout [(Variable, LuaType)]) {
            let returnValueType = mergeNewestConditionalBlocks(typeChanges: &typeChanges, defaultReturnValueType: [])
            assert(returnValueType.count == 0)
        }

        /// Whether the currently active block has at least one alternative block.
        var currentBlockHasAlternativeBlock: Bool {
            return states.top.count > 1
        }

        /// Start a new subroutine.
        ///
        /// Subroutines are treated as conditionally executing code, in essence similar to
        ///
        ///     if (functionIsCalled) {
        ///         function_body();
        ///     }
        ///
        /// In addition to updating variable types, subroutines also track their return value
        /// type which is returned by `leaveSubroutine()`.
        mutating func startSubroutine() {
            parentState = activeState
            // The empty state represents the execution path where the function is not executed.
            let emptyState = State()
            activeState = State(isSubroutineState: true)
            states.push([emptyState, activeState])
        }

        /// End the current subroutine.
        ///
        /// This behaves similar to `endGroupOfConditionallyExecutingBlocks()` and computes variable type changes assuming that the\
        /// function body may or may not have been executed, but it additionally computes and returns the inferred type for the subroutine's return value.
        mutating func endSubroutine(typeChanges: inout [(Variable, LuaType)], defaultReturnValueType: ParameterList) -> ParameterList {
            return mergeNewestConditionalBlocks(typeChanges: &typeChanges, defaultReturnValueType: defaultReturnValueType)
        }

        /// Merge the current conditional block and all its alternative blocks and compute both variable- and return value type changes.
        ///
        /// This computes the new types assuming that exactly one of the conditional blocks will execute at runtime. If the currently
        /// active state is a subroutine state, this will return the final return value type, otherwise it will return nil.
        private mutating func mergeNewestConditionalBlocks(typeChanges: inout [(Variable, LuaType)], defaultReturnValueType: ParameterList) -> ParameterList{
            let statesToMerge = states.pop()

            let maybeReturnValueType = computeReturnValueType(whenMerging: statesToMerge, defaultReturnValueType: defaultReturnValueType)
            let newTypes = computeVariableTypes(whenMerging: statesToMerge)
            makeParentStateTheActiveStateAndUpdateVariableTypes(to: newTypes, &typeChanges)

            return maybeReturnValueType
        }

        private func computeReturnValueType(whenMerging states: [State], defaultReturnValueType: ParameterList) -> ParameterList{
            assert(states.last === activeState)

            // Need to compute how many sibling states have returned and what their overall return value type is.
            var returnedStates = 0
            var returnValueType:ParameterList = ParameterList([])

            for state in states {
                returnValueType = returnValueType | state.returnValueType
                /// TODO: maybe improper
                
                if state.hasReturned {
                    assert(state.returnValueType.count != 0)
                    returnedStates += 1
                }
            }

            // If the active state represents a subroutine, then we can now compute
            // the final return value type.
            // Otherwise, we may need to merge our return value type with that
            // of our parent state.
            var maybeReturnValue:ParameterList = []
            if activeState.isSubroutineState {
                assert(returnValueType == activeState.returnValueType)
                if !activeState.hasReturned {
                    returnValueType = defaultReturnValueType
                }
                maybeReturnValue = returnValueType
            } else if !parentState.hasReturned {
                parentState.returnValueType = returnValueType | parentState.returnValueType
                if returnedStates == states.count { 
                    // All conditional branches have returned, so the parent state
                    // must also have returned now.
                    parentState.hasReturned = true
                }
            }
            // None of our sibling states can be a subroutine state as that wouldn't make sense semantically.
            assert(states.dropLast().allSatisfy({ !$0.isSubroutineState }))

            return maybeReturnValue
        }

    private func computeVariableTypes(whenMerging states: [State]) -> VariableMap<LuaType> {
            var numUpdatesPerVariable = VariableMap<Int>()
            var newTypes = VariableMap<LuaType>()
            for state in states {
                for (v, t) in state.types {
                    // Skip variable types that are already out of scope (local to a child of the child state)
                    guard t != .nothing else { continue }

                    // Invariant checking: activeState[v] != nil => parentState[v] != nil
                    assert(parentState.types[v] != nil)

                    // Skip variables that are local to the child state
                    /// TODO: maybe improper
                    // guard parentState.types[v] != .nothing else { continue }

                    if newTypes[v] == nil {
                        newTypes[v] = t
                        numUpdatesPerVariable[v] = 1
                    } else {
                        newTypes[v]! |= t
                        numUpdatesPerVariable[v]! += 1
                    }
                }
            }

            for (v, c) in numUpdatesPerVariable {
                /// TODO: maybe improper
                // assert(parentState.types[v] != .nothing)

                // Not all paths updates this variable, so it must be unioned with the type in the parent state.
                // The parent state will always have an entry for v due to the invariant "activeState[v] != nil => parentState[v] != nil".
                if c != states.count {
                    newTypes[v]! |= parentState.types[v]!
                }
            }
            return newTypes
        }

        private mutating func makeParentStateTheActiveStateAndUpdateVariableTypes(to newTypes: VariableMap<LuaType>, _ typeChanges: inout [(Variable, LuaType)]) {
            // The previous parent state is now the active state
            let oldParentState = parentState
            activeState = parentState
            parentState = states.secondToTop.last!
            assert(activeState === states.top.last)

            // Update the overallState and compute typeChanges
            for (v, newType) in newTypes {
                if overallState.types[v] != newType {
                    typeChanges.append((v, newType))
                }
                // overallState now doesn't contain the older type but actually a newer type,
                // therefore we have to manually specify the old type here.
                updateType(of: v, to: newType, from: oldParentState.types[v])
            }
        }
    }
}