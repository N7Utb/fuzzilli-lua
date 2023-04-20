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
            /// TODO: Reassigns Analyze
            // if instr.reassigns(v) {
            //     assignments[v]?.append(instr.index)
            // }
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