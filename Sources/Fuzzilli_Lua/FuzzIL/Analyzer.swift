protocol Analyzer {
    /// Analyzes the next instruction of a program.
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
