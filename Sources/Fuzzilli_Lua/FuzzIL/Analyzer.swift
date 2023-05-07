    /// Analyzes the next instruction of a program.
protocol Analyzer {
    ///
    /// The caller must guarantee that the instructions are given to this method in the correct order.
    mutating func analyze(_ instr: Instruction)
}

extension Analyzer {
    /// Analyze the provided program.
    mutating func analyze(_ program: Program) {
        analyze(program.code)
    }

    mutating func analyze(_ code: Code) {
        assert(code.isStaticallyValid())
        for instr in code {
            analyze(instr)
        }
    }
}

/// Determines definitions, assignments, and uses of variables.
struct DefUseAnalyzer: Analyzer {
    private var assignments = VariableMap<[Int]>()
    private var uses = VariableMap<[Int]>()
    private let code: Code
    private var analysisDone = false

    init(for program: Program) {
        self.code = program.code
    }

    mutating func finishAnalysis() {
        analysisDone = true
    }

    mutating func analyze() {
        analyze(code)
        finishAnalysis()
    }

    mutating func analyze(_ instr: Instruction) {
        assert(code[instr.index].op === instr.op)    // Must be operating on the program passed in during construction
        assert(!analysisDone)
        for v in instr.allOutputs {
            assignments[v] = [instr.index]
            uses[v] = []
        }
        for v in instr.inputs {
            assert(uses.contains(v))
            uses[v]?.append(instr.index)
            if instr.reassigns(v) {
                assignments[v]?.append(instr.index)
            }
        }
    }

    /// Returns the instruction that defines the given variable.
    func definition(of variable: Variable) -> Instruction {
        assert(assignments.contains(variable))
        return code[assignments[variable]![0]]
    }

    /// Returns all instructions that assign the given variable, including its initial definition.
    func assignments(of variable: Variable) -> [Instruction] {
        assert(assignments.contains(variable))
        return assignments[variable]!.map({ code[$0] })
    }

    /// Returns the instructions using the given variable.
    func uses(of variable: Variable) -> [Instruction] {
        assert(uses.contains(variable))
        return uses[variable]!.map({ code[$0] })
    }

    /// Returns the indices of the instructions using the given variable.
    func assignmentIndices(of variable: Variable) -> [Int] {
        assert(uses.contains(variable))
        return assignments[variable]!
    }

    /// Returns the indices of the instructions using the given variable.
    func usesIndices(of variable: Variable) -> [Int] {
        assert(uses.contains(variable))
        return uses[variable]!
    }

    /// Returns the number of instructions using the given variable.
    func numAssignments(of variable: Variable) -> Int {
        assert(assignments.contains(variable))
        return assignments[variable]!.count
    }

    /// Returns the number of instructions using the given variable.
    func numUses(of variable: Variable) -> Int {
        assert(uses.contains(variable))
        return uses[variable]!.count
    }
}

struct ContextAnalyzer: Analyzer{
    private var contextStack = Stack([Context.script])

    var context: Context {
        return contextStack.top
    }

    mutating func analyze(_ instr: Instruction) {
        if instr.isBlockEnd {
            contextStack.pop()
        }
        if instr.isBlockStart {
            var newContext = instr.op.contextOpened
            if instr.propagatesSurroundingContext {
                newContext.formUnion(context)
            }

            // If we resume the context analysis, we currently take the second to last context.
            // This currently only works if we have a single layer of these instructions.
            if instr.skipsSurroundingContext {
                assert(!instr.propagatesSurroundingContext)
                assert(contextStack.count >= 2)

                // Currently we only support context "skipping" for switch blocks. This logic may need to be refined if it is ever used for other constructs as well.
                assert(contextStack.top.contains(.switchBlock) && contextStack.top.subtracting(.switchBlock) == .empty)

                newContext.formUnion(contextStack.secondToTop)
            }
            contextStack.push(newContext)
        }
    }

}

/// Keeps track of currently visible variables during program construction.
struct VariableAnalyzer: Analyzer {
    private(set) var visibleVariables = [Variable]()
    private(set) var scopes = Stack<Int>([0])

    mutating func analyze(_ instr: Instruction) {
        // Scope management (1).
        if instr.isBlockEnd {
            assert(scopes.count > 0, "Trying to end a scope that was never started")
            let variablesInClosedScope = scopes.pop()
            visibleVariables.removeLast(variablesInClosedScope)
        }

        scopes.top += instr.numOutputs
        visibleVariables.append(contentsOf: instr.outputs)

        // Scope management (2). Happens here since e.g. function definitions create a variable in the outer scope.
        // This code has to be somewhat careful since e.g. BeginElse both ends and begins a variable scope.
        if instr.isBlockStart {
            scopes.push(0)
        }

        scopes.top += instr.numInnerOutputs
        visibleVariables.append(contentsOf: instr.innerOutputs)
    }
}

/// Determines whether code after the current instruction is dead code (i.e. can never be executed).
struct DeadCodeAnalyzer: Analyzer {
    private var depth = 0

    var currentlyInDeadCode: Bool {
        return depth != 0
    }

    mutating func analyze(_ instr: Instruction) {
        if instr.isBlockEnd && currentlyInDeadCode {
            depth -= 1
        }
        if instr.isBlockStart && currentlyInDeadCode {
            depth += 1
        }
        if instr.isJump && !currentlyInDeadCode {
            depth = 1
        }
        assert(depth >= 0)
    }
}


/// Keeps track of the current context during program construction.
struct ScopeAnalyzer: Analyzer {

    private var subroutine_stack = Stack<Subroutine>()
    private var r_stack = Stack<[String]>()
    private var t_stack = Stack<Int>()
    private var table_count = 0

    /// Visible variables management.
    /// The `scopes` stack contains one entry per currently open scope containing all local variables created in that scope.
    private var scopes = Stack<[Variable]>([[]])
    /// The `variablesInScope` array simply contains all variables that are currently in scope. It is effectively the `scopes` stack flattened.
    private var variablesInScope: [Variable] {
        scopes.buffer.flatMap({$0})
    }


    private var global_map = [Subroutine:[Variable]]()
    enum Subroutine: Hashable{
        case function(Variable)
        case tmp_method(String, Int)
        case method(String, Variable)
    }
    private var label_stack = Stack<[String]>([[]])
    mutating func analyze(_ instr: Instruction) {
        // Scope management (1).
        if instr.isBlockEnd {
            assert(scopes.count > 0, "Trying to close a scope that was never opened")
            scopes.pop()
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
}