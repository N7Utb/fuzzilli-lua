import Foundation

/// Lifter to convert FuzzIL into its human readable text format
public class LuaLifter: Lifter {
    public init() {}

    /// Stack of for-loop header parts. A for-loop's header consists of three different blocks (initializer, condition, afterthought), which
    /// are lifted independently but should then typically be combined into a single line. This helper stack makes that possible.
    struct ForLoopHeader {
        var initializer = ""
        var condition = ""
        // No need for the afterthought string since this struct will be consumed
        // by the handler for the afterthought block.
        var loopVariables = [String]()
    }
    private var forLoopHeaderStack = Stack<ForLoopHeader>()



    public func lift(_ program: Program, withOptions options: LiftingOptions) -> String {
            // Perform some analysis on the program, for example to determine variable uses
        let needToSupportExploration = false
        let needToSupportProbing = false
        var analyzer = DefUseAnalyzer(for: program)
        for instr in program.code {
            analyzer.analyze(instr)
            /// TODO: probe
            // if instr.op is Explore { needToSupportExploration = true }
            // if instr.op is Probe { needToSupportProbing = true }
        }
        analyzer.finishAnalysis()

        var w = LuaWriter(analyzer: analyzer)
        
        if options.contains(.includeComments), let header = program.comments.at(.header) {
            w.emitComment(header)
        }

        /// TODO: probe
        // w.emitBlock(prefix)

        if needToSupportExploration {
            // w.emitBlock(JavaScriptExploreHelper.prefixCode)
        }

        if needToSupportProbing {
            // w.emitBlock(JavaScriptProbeHelper.prefixCode)
        }
        for instr in program.code {
            if options.contains(.includeComments), let comment = program.comments.at(.instruction(instr.index)) {
                w.emitComment(comment)
            }

            // Retrieve all input expressions.
            //
            // Here we assume that the input expressions are evaluated exactly in the order that they appear in the instructions inputs array.
            // If that is not the case, it may change the program's semantics as inlining could reorder operations, see JavaScriptWriter.retrieve
            // for more details.
            // We also have some lightweight checking logic to ensure that the input expressions are retrieved in the correct order.
            // This does not guarantee that they will also _evaluate_ in that order at runtime, but it's probably a decent approximation.
            let inputs = w.retrieve(expressionsFor: instr.inputs)
            var nextExpressionToFetch = 0
            func input(_ i: Int) -> Expression {
                assert(i == nextExpressionToFetch)
                nextExpressionToFetch += 1
                return inputs[i]
            }
            // Retrieves the expression for the given input and makes sure that it is an identifier. If necessary, this will create a temporary variable.
            func inputAsIdentifier(_ i: Int) -> Expression {
                let expr = input(i)
                let identifier = w.ensureIsIdentifier(expr, for: instr.input(i))
                assert(identifier.type === Identifier)
                return identifier
            }
            switch instr.op.opcode {
            case .loadBuiltin(let op):
                w.assign(Identifier.new(op.builtinName), to: instr.output)
            case .getProperty(let op):
                let obj = input(0)
                let accessOperator = "."
                let expr = MemberExpression.new() + obj + accessOperator + op.propertyName
                w.assign(expr, to: instr.output)
            case .setProperty(let op):
                // For aesthetic reasons, we don't want to inline the lhs of an assignment, so force it to be stored in a variable.
                let obj = inputAsIdentifier(0)
                let PROPERTY = MemberExpression.new() + obj + "." + op.propertyName
                let VALUE = input(1)
                w.emit("\(PROPERTY) = \(VALUE);")
            case .updateProperty(let op):
                // For aesthetic reasons, we don't want to inline the lhs of an assignment, so force it to be stored in a variable.
                let obj = inputAsIdentifier(0)
                let PROPERTY = MemberExpression.new() + obj + "." + op.propertyName
                let VALUE = input(1) 
                w.emit("\(PROPERTY) = \(PROPERTY) \(op.op.token) \(VALUE);")
            case .deleteProperty(let op):
                // For aesthetic reasons, we don't want to inline the lhs of a property deletion, so force it to be stored in a variable.
                let obj = inputAsIdentifier(0)
                let accessOperator = "."
                let target = MemberExpression.new() + obj + accessOperator + op.propertyName
                w.emit("\(target) = nil;")

            case .getElement(let op):
                let obj = input(0)
                let accessOperator = "["
                let expr = MemberExpression.new() + obj + accessOperator + op.index + "]"
                w.assign(expr, to: instr.output)

            case .setElement(let op):
                // For aesthetic reasons, we don't want to inline the lhs of an assignment, so force it to be stored in a variable.
                let obj = inputAsIdentifier(0)
                let ELEMENT = MemberExpression.new() + obj + "[" + op.index + "]"
                let VALUE = input(1)
                w.emit("\(ELEMENT) = \(VALUE);")

            case .updateElement(let op):
                // For aesthetic reasons, we don't want to inline the lhs of an assignment, so force it to be stored in a variable.
                let obj = inputAsIdentifier(0)
                let ELEMENT = MemberExpression.new() + obj + "[" + op.index + "]"
                let VALUE = input(1)
                w.emit("\(ELEMENT) \(op.op.token)= \(VALUE);")

            case .deleteElement(let op):
                // For aesthetic reasons, we don't want to inline the lhs of an element deletion, so force it to be stored in a variable.
                let obj = inputAsIdentifier(0)
                let accessOperator = "["
                let target = MemberExpression.new() + obj + accessOperator + op.index + "]"
                w.emit("\(target) = nil;")
            
            case .loadNumber(let op):
                w.assign(NumberLiteral.new(String(op.value)), to: instr.output)
            case .loadString(let op):
                w.assign(StringLiteral.new("\"\(op.value)\""), to: instr.output)
            case .loadBoolean(let op):
                w.assign(Literal.new(op.value ? "true" : "false"), to: instr.output)
            case .loadNil:
                w.assign(Literal.new("nil"), to: instr.output)
            case .loadPair:
                withEqualProbability({
                    w.assign(Literal.new("pairs(\(input(0)))"), to: instr.output)
                },{
                    w.assign(Literal.new("ipairs(\(input(0)))"), to: instr.output)
                })
            
            case .beginTable:
                let end = program.code.findBlockEnd(head: instr.index) 
                let output = program.code[end].output
                let V = w.declare(output, as: "t\(output.number)")
                w.emit("\(V) = {")
                w.enterNewBlock()
            case .tableAddProperty(let op):
                let PROPERTY = op.propertyName
                if op.hasValue{
                    let VALUE = input(0)
                    w.emit("\(PROPERTY) = \(VALUE),")
                }
                else{
                    w.emit("\(PROPERTY),")
                }

            case .tableAddElement(let op):
                let INDEX = op.index < 0 ? "[\(op.index)]" : String(op.index)
                let VALUE = input(0)
                w.emit("[\(INDEX)] = \(VALUE),")
            case .endTable: 
                w.leaveCurrentBlock()
                w.emit("}")
            case .beginTableMethod(let op):
                // First inner output is explicit |this| parameter
                let vars =  w.declareAll(instr.innerOutputs, usePrefix: "a")
                let PARAMS = liftParameters(op.parameters, as: vars)
                let METHOD = op.methodName
                w.emit("\(METHOD) = function (\(PARAMS))")
                w.enterNewBlock()
            case .endTableMethod:
                w.leaveCurrentBlock()
                w.emit("end,")

            case .beginFunction:
                liftFunctionDefinitionBegin(instr, keyword: "function", using: &w)
            case .endFunction:
                w.leaveCurrentBlock()
                w.emit("end")

            case .callMethod(let op):
                let obj = input(0)
                let accessOperator = "."
                let method = MemberExpression.new() + obj + accessOperator + op.methodName
                let args = inputs.dropFirst()
                let expr = CallExpression.new() + method + "(" + liftCallArguments(args) + ")"
                if instr.numOutputs != 0{
                    let outputs = w.declareAll(instr.outputs).joined(separator: ", ")
                    w.emit("\(outputs) = \(expr);")
                }
                else{
                    w.emit("\(expr)")
                }
            case .unaryOperation(let op):
                let input = input(0)
                let expr: Expression
                if op.op.isPostfix{
                    expr = UnaryExpression.new() + input + op.op.token
                } else {
                    expr = UnaryExpression.new() + op.op.token + input
                }
                w.assign(expr, to: instr.output)
            case .binaryOperation(let op):
                let lhs = input(0)
                let rhs = input(1)
                let expr = BinaryExpression.new() + lhs + " " + op.op.token + " " + rhs
                w.assign(expr, to: instr.output)
            case .reassign:
                let dest = input(0)
                assert(dest.type === Identifier)
                let expr = AssignmentExpression.new() + dest + " = " + input(1)
                w.reassign(instr.input(0), to: expr)
            case .update(let op):
                let dest = input(0)
                assert(dest.type === Identifier)
                let expr = AssignmentExpression.new() + dest + " = " + dest + " \(op.op.token) " + input(1)
                w.reassign(instr.input(0), to: expr)
            case .compare(let op):
                let lhs = input(0)
                let rhs = input(1)
                let expr = BinaryExpression.new() + lhs + " " + op.op.token + " " + rhs
                w.assign(expr, to: instr.output)
            case .return(let op):
                if op.hasReturnValue{
                    var tmp:[String] = []
                    let _ = inputs.map{ exp in  return tmp.append("\(exp)") }
                    w.emit("return \(tmp.joined(separator:", "))")
                }
                else {
                    w.emit("return")
                }
            case .callFunction:
                let f = inputAsIdentifier(0)
                let args = inputs.dropFirst()
                let expr = CallExpression.new() + f + "(" + liftCallArguments(args) + ")"
                if instr.numOutputs != 0{
                    let outputs = w.declareAll(instr.outputs).joined(separator: ", ")
                    w.emit("\(outputs) = \(expr);")

                }
                else{
                    w.emit("\(expr)")
                }
            case .beginIf(let op):
                var COND = input(0)
                if op.inverted {
                    COND = UnaryExpression.new() + "not" + COND
                }
                w.emit("if (\(COND)) then")
                w.enterNewBlock()

            case .beginElse:
                w.leaveCurrentBlock()
                w.emit("else")
                w.enterNewBlock()

            case .endIf:
                w.leaveCurrentBlock()
                w.emit("end")
            case .beginWhileLoopHeader:
                // Must not inline across loop boundaries as that would change the program's semantics.
                w.emitPendingExpressions()
                handleBeginSingleExpressionContext(with: &w, initialIndentionLevel: 2)

            case .beginWhileLoopBody:
                let COND = handleEndSingleExpressionContext(result: input(0), with: &w)
                w.emitBlock("while (\(COND)) do")
                w.enterNewBlock()

            case .endWhileLoop:
                w.leaveCurrentBlock()
                w.emit("end")
            case .beginForLoopInitializer:
                // While we could inline into the loop header, we probably don't want to do that as it will often lead
                // to the initializer block becoming an arrow function, which is not very readable. So instead force
                // all pending expressions to be emitted now, before the loop.
                w.emitPendingExpressions()

                // The loop initializer is a bit odd: it may be a single expression (`for (foo(); ...)`), but it
                // could also be a variable declaration containing multiple expressions (`for (let i = X, j = Y; ...`).
                // However, we'll figure this out at the end of the block in the .beginForLoopCondition case.
                handleBeginSingleExpressionContext(with: &w, initialIndentionLevel: 2)

            case .beginForLoopCondition:
                let loopVars = w.declareAll(instr.innerOutputs, usePrefix: "i")
                // The logic for a for-loop's initializer block is a little different from the lifting logic for other block headers.
                let initializer: String

                // In this case, the initializer declares one or more variables. We first try to lift the variable declarations
                // as `let i = X, j = Y, ...`, however, this is _only_ possible if we have as many expressions as we have
                // variables to declare _and_ if they are in the correct order.
                // In particular, the following syntax is invalid: `let i = foo(), bar(), j = baz()` and so we cannot chain
                // independent expressions using the comma operator as we do for the other loop headers.
                // In all other cases, we lift the initializer to something like `let [i, j] = (() => { CODE })()`.
                if w.isCurrentTemporaryBufferEmpty && w.numPendingExpressions == 0 {
                    // The "good" case: we can emit `let i = X, j = Y, ...`
                    assert(loopVars.count == inputs.count)
                    // let declarations = zip(loopVars, inputs).map({ "\($0) = \($1)" }).joined(separator: ", ")
                    initializer = "\(loopVars[0]) = \(input(0))"
                    let code = w.popTemporaryOutputBuffer()
                    assert(code.isEmpty)
                } else {
                    // In this case, we have to emit a temporary arrow function that returns all initial values in an array
                    w.emitPendingExpressions()
                    // Emit a `let i = (() => { ...; return X; })()`
                    w.emit("return \(input(0));")
                    let I = loopVars[0]
                    let CODE = w.popTemporaryOutputBuffer()
                    initializer = "\(I) = (function()\n\(CODE)end)()"
                }

                forLoopHeaderStack.push(ForLoopHeader(initializer: initializer, loopVariables: loopVars))
                handleBeginSingleExpressionContext(with: &w, initialIndentionLevel: 2)

            case .beginForLoopAfterthought:
                var condition = handleEndSingleExpressionContext(result: input(0), with: &w)
                // Small syntactic "optimization": an empty condition is always true, so we can replace the constant "true" with an empty condition.
                if condition == "true" {
                    condition = ""
                }

                forLoopHeaderStack.top.condition = condition
                w.declareAll(instr.innerOutputs, as: forLoopHeaderStack.top.loopVariables)
                handleBeginSingleExpressionContext(with: &w, initialIndentionLevel: 2)

            case .beginForLoopBody:
                let header = forLoopHeaderStack.pop()
                let INITIALIZER = header.initializer
                let CONDITION = header.condition
                if instr.numInputs != 0{
                    let AFTERTHOUGHT = handleEndSingleExpressionContext(result: input(0), with: &w)
                    w.emitBlock("for \(INITIALIZER),\(CONDITION),\(AFTERTHOUGHT) do")
                }
                else {
                    w.emit("for \(INITIALIZER),\(CONDITION) do")
                }
            
                w.declareAll(instr.innerOutputs, as: header.loopVariables)
                w.enterNewBlock()

            case .endForLoop:
                w.leaveCurrentBlock()
                w.emit("end")

            case .beginForInLoop:
                let V = w.declareAll(instr.innerOutputs).joined(separator: ", ")
                let OBJ = input(0)
                w.emit("for \(V) in \(OBJ) do")
                w.enterNewBlock()

            case .endForInLoop:
                w.leaveCurrentBlock()
                w.emit("end")
            case .beginRepeatLoop(let op):
                let I: String
                if op.exposesLoopCounter {
                    I = w.declare(instr.innerOutput)
                } else {
                    I = "i"
                }
                w.emit("\(I) = 0")
                w.emit("repeat")
                w.enterNewBlock()
                w.emit("\(I) = \(I) + 1")
            case .endRepeatLoop:
                let begin = program.code[program.code.findBlockBegin(end: instr.index)]
                switch begin.op.opcode{
                    case .beginRepeatLoop(let op):
                        let COND: String
                        
                        if op.exposesLoopCounter{
                            COND = "\(begin.innerOutput) >= \(op.iterations)"
                        }
                        else{
                            COND = "i >= \(op.iterations)"
                        }
                        w.leaveCurrentBlock()
                        w.emit("until(\(COND))")
                    default:
                        fatalError("Repeat Loop doesn't match")
                }

            case .createArray:
                var elems = inputs.map({$0.text}).map({ $0 == "undefined" ? "" : $0 }).joined(separator: ",")
                if elems.last == "," || (instr.inputs.count == 1 && elems == "") {
                    // If the last element is supposed to be a hole, we need one additional comma
                    elems += ","
                }
                w.assign(ArrayLiteral.new("{\(elems)}"), to: instr.output)
            case .loopBreak(_):
                //  .switchBreak:
                w.emit("break;")
            case .label(let op):
                w.emit("::\(op.value)::")
            case .goto(let op):
                w.emit("goto \(op.value)")
            case .nop:
                break
            }
        }


        w.emitPendingExpressions()

        /// TODO: probe
        if needToSupportProbing {
            // w.emitBlock(JavaScriptProbeHelper.suffixCode)
        }

        if options.contains(.includeComments), let footer = program.comments.at(.footer) {
            w.emitComment(footer)
        }
        // w.emitBlock(suffix)
        return w.code
    }

    // Signal that the following code needs to be lifted into a single expression.
    private func handleBeginSingleExpressionContext(with w: inout LuaWriter, initialIndentionLevel: Int) {
        // Lift the following code into a temporary buffer so that it can either be emitted
        // as a single expression, or as body of a temporary function, see below.
        w.pushTemporaryOutputBuffer(initialIndentionLevel: initialIndentionLevel)
    }

    // Lift all code between the begin and end of the single expression context (e.g. a loop header) into a single expression.
    // The optional result parameter contains the value to which the entire expression must ultimately evaluate.
    private func handleEndSingleExpressionContext(result maybeResult: Expression? = nil, with w: inout LuaWriter) -> String {
        if w.isCurrentTemporaryBufferEmpty {
            // This means that the code consists entirely of expressions that can be inlined, and that the result
            // variable is either not an inlined expression (but instead e.g. the identifier for a local variable), or that
            // it is the most recent pending expression (in which case previously pending expressions are not emitted).
            //
            // In this case, we can emit a single expression by combining all pending expressions using the comma operator.
            var COND = CommaExpression.new()
            let expressions = w.takePendingExpressions() + (maybeResult != nil ? [maybeResult!] : [])
            for expr in expressions {
                if COND.text.isEmpty {
                    COND = COND + expr
                } else {
                    COND = COND + ", " + expr
                }
            }

            let headerContent = w.popTemporaryOutputBuffer()
            assert(headerContent.isEmpty)

            return COND.text
        } 
        else {
            /// TODO: improper
            // The code is more complicated, so emit a temporary function and call it.
            w.emitPendingExpressions()
            if let result = maybeResult {
                w.emit("return \(result);")
            }
            let CODE = w.popTemporaryOutputBuffer()
            assert(CODE.contains("\n"))
            assert(CODE.hasSuffix("\n"))
            return "(function()\n\(CODE)end)()"
        }
    }

    private func liftParameters(_ parameters: Parameters, as variables: [String]) -> String {
        assert(parameters.count == variables.count)
        var paramList = [String]()
        for v in variables {
            if parameters.hasRestParameter && v == variables.last {
                paramList.append("..." + v)
            } else {
                paramList.append(v)
            }
        }
        return paramList.joined(separator: ", ")
    }

    private func liftFunctionDefinitionBegin(_ instr: Instruction, keyword FUNCTION: String, using w: inout LuaWriter) {
        // Function are lifted as `function f3(a4, a5, a6) { ...`.
        // This will produce functions with a recognizable .name property, which the JavaScriptExploreHelper code makes use of (see shouldTreatAsConstructor).
        guard let op = instr.op as? BeginFunction else {
            fatalError("Invalid operation passed to liftFunctionDefinitionBegin")
        }
        let NAME = w.declare(instr.output, as: "f\(instr.output.number)")
        let vars = w.declareAll(instr.innerOutputs, usePrefix: "a")
        let PARAMS = liftParameters(op.parameters, as: vars)
        w.emit("\(FUNCTION) \(NAME)(\(PARAMS))")
        w.enterNewBlock()
    }

    private func liftCallArguments<Arguments: Sequence>(_ args: Arguments, spreading spreads: [Bool] = []) -> String where Arguments.Element == Expression {
        var arguments = [String]()
        for (i, a) in args.enumerated() {
            if spreads.count > i && spreads[i] {
                let expr = SpreadExpression.new() + "..." + a
                arguments.append(expr.text)
            } else {
                arguments.append(a.text)
            }
        }
        return arguments.joined(separator: ", ")
    }


    /// A wrapper around a ScriptWriter. It's main responsibility is expression inlining.
    ///
    /// Expression inlining roughly works as follows:
    /// - FuzzIL operations that map to a single JavaScript expressions are lifted to these expressions and associated with the output FuzzIL variable using assign()
    /// - If an expression is pure, such as for example a number literal, it will be inlined into all its uses
    /// - On the other hand, if an expression is effectful, it can only be inlined if there is a single use of the FuzzIL variable (otherwise, the expression would execute multiple times), _and_ if there is no other effectful expression before that use (otherwise, the execution order of instructions would change)
    /// - To achieve that, pending effectful expressions are kept in a list of expressions which must execute in FIFO order at runtime
    /// - To retrieve the expression for an input FuzzIL variable, the retrieve() function is used. If an inlined expression is returned, this function takes care of first emitting pending expressions if necessary (to ensure correct execution order)
    private struct LuaWriter {
        private var writer: ScriptWriter
        private var analyzer: DefUseAnalyzer

        /// Variable declaration keywords to use.
        // let varKeyword: String
        // let constKeyword: String

        /// Code can be emitted into a temporary buffer instead of into the final script. This is mainly useful for inlining entire blocks.
        /// The typical way to use this would be to call pushTemporaryOutputBuffer() when handling a BeginXYZBlock, then calling
        /// popTemporaryOutputBuffer() when handling the corresponding EndXYZBlock and then either inlining the block's body
        /// or assigning it to a local variable.
        var temporaryOutputBufferStack = Stack<ScriptWriter>()

        var code: String {
            assert(pendingExpressions.isEmpty)
            assert(temporaryOutputBufferStack.isEmpty)
            return writer.code
        }

        // Maps each FuzzIL variable to its JavaScript expression.
        // The expression for a FuzzIL variable can generally either be
        //  * an identifier like "v42" if the FuzzIL variable is mapped to a JavaScript variable OR
        //  * an arbitrary expression if the expression producing the FuzzIL variable is a candidate for inlining
        public var expressions = VariableMap<Expression>()

        // List of effectful expressions that are still waiting to be inlined. In the order that they need to be executed at runtime.
        // The expressions are identified by the FuzzIL output variable that they generate. The actual expression is stored in the expressions dictionary.
        private var pendingExpressions = [Variable]()

        // We also try to inline reassignments once, into the next use of the reassigned FuzzIL variable. However, for all subsequent uses we have to use the
        // identifier of the JavaScript variable again (the lhs of the reassignment). This map is used to remember these identifiers.
        // See `reassign()` for more details about reassignment inlining.
        private var inlinedReassignments = VariableMap<Expression>()

        init(analyzer: DefUseAnalyzer, stripComments: Bool = false, includeLineNumbers: Bool = false, indent: Int = 4) {
            self.writer = ScriptWriter(stripComments: stripComments, includeLineNumbers: includeLineNumbers, indent: indent)
            self.analyzer = analyzer
        }

        /// Assign a JavaScript expression to a FuzzIL variable.
        ///
        /// If the expression can be inlined, it will be associated with the variable and returned at its use. If the expression cannot be inlined,
        /// the expression will be emitted either as part of a variable definition or as an expression statement (if the value isn't subsequently used).
        mutating func assign(_ expr: Expression, to v: Variable) {
            if shouldTryInlining(expr, producing: v) {
                expressions[v] = expr
                // If this is an effectful expression, it must be the next expression to be evaluated. To ensure that, we
                // keep a list of all "pending" effectful expressions, which must be executed in FIFO order.
                if expr.isEffectful {
                    pendingExpressions.append(v)
                }
            } else {
                // The expression cannot be inlined. Now decide whether to define the output variable or not. The output variable can be omitted if:
                //  * It is not used by any following instructions, and
                //  * It is not an Object literal, as that would not be valid syntax (it would mistakenly be interpreted as a block statement)
                
                /// TODO: maybe improper
                // if analyzer.numUses(of: v) == 0 && expr.type !== ObjectLiteral {
                //     emit("\(expr);")
                // } else {
                //     let V = declare(v)
                //     emit("\(V) = \(expr);")
                // }
                let V = declare(v)
                emit("\(V) = \(expr);")
            }
        }

        /// Reassign a FuzzIL variable to a new JavaScript expression.
        /// The given expression is expected to be an AssignmentExpression.
        ///
        /// Variable reassignments such as `a = b` or `c += d` can be inlined once into the next use of the reassigned variable. All subsequent uses then again use the variable.
        /// For example:
        ///
        ///     a += b;
        ///     foo(a);
        ///     bar(a);
        ///
        /// Can also be lifted as:
        ///
        ///     foo(a += b);
        ///     bar(a);
        ///
        /// However, this is only possible if the next use is not again a reassignment, otherwise it'd lead to something like `(a = b) = c;`which is invalid.
        /// To simplify things, we therefore only allow the inlining if there is exactly one reassignment.
        mutating func reassign(_ v: Variable, to expr: Expression) {
            assert(expr.type === AssignmentExpression)
            assert(analyzer.numAssignments(of: v) > 1)
            guard analyzer.numAssignments(of: v) == 2 else {
                // There are multiple (re-)assignments, so we cannot inline the assignment expression.
                return emit("\(expr);")
            }

            guard let identifier = expressions[v] else {
                fatalError("Missing identifier for reassignment")
            }
            assert(identifier.type === Identifier)
            expressions[v] = expr
            pendingExpressions.append(v)
            assert(!inlinedReassignments.contains(v))
            inlinedReassignments[v] = identifier
        }

        /// Retrieve the JavaScript expressions assigned to the given FuzzIL variables.
        ///
        /// The returned expressions _must_ subsequently execute exactly in the order that they are returned (i.e. in the order of the input variables).
        /// Otherwise, expression inlining will change the semantics of the program.
        ///
        /// This is a mutating operation as it can modify the list of pending expressions or emit pending expression to retain the correct ordering.
        mutating func retrieve(expressionsFor queriedVariables: ArraySlice<Variable>) -> [Expression] {
            // If any of the expression for the variables is pending, then one of two things will happen:
            //
            // 1. Iff the pending expressions that are being retrieved are an exact suffix match of the pending expressions list, then these pending expressions
            //    are removed but no code is emitted here.
            //    For example, if pendingExpressions = [v1, v2, v3, v4], and retrievedExpressions = [v3, v0, v4], then v3 and v4 are removed from the pending
            //    expressions list and returned, but no expressions are emitted, and so now pendingExpressions = [v1, v2] (v0 was not a pending expression
            //    and so is ignored). This works because no matter what the lifter now does with the expressions for v3 and v4, they will still executed
            //    _after_ v1 and v2, and so the correct order is maintainted (see also the explanation below).
            //
            // 2. In all other cases, some pending expressions must now be emitted. If there is a suffix match, then only the pending expressions
            //    before the matching suffix are emitted, otherwise, all of them are.
            //    For example, if pendingExpressions = [v1, v2, v3, v4, v5], and retrievedExpressions = [v0, v2, v5], then we would emit the expressions for
            //    v1, v2, v3, and v4 now. Otherwise, something like the following can happen: v0, v2, and v5 are inlined into a new expression, which is
            //    emitted as part of a variable declaraion (or appended to the pending expressions list, the outcome is the same). During the emit() call, all
            //    remaining pending expressions are now emitted, and so v1, v3, and v4 are emitted. However, this has now changed the execution order: v3 and
            //    v4 execute prior to v2. As such, v3 and v4 (in general, all instructions before a matching suffix) must be emitted during the retrieval,
            //    which then requires that all preceeding pending expressions (i.e. v1 in the above example) are emitted as well.
            //
            // This logic works because one of the following two cases must happen with the returned expressions:
            // 1. The handler for the instruction being lifted will emit a single expression for it. In that case, either that expression will be added to the
            //    end of the pending expression list and thereby effectively replace the suffix that is being removed, or it will cause a variable declaration
            //    to be emitted, in which case earlier pending expressions will also be emitted.
            // 2. The handler for the instruction being lifted will emit a statement. In that case, it will call emit() which will take care of emitting all
            //    pending expressions in the correct order.
            //
            // As such, in every possible case the correct ordering of the pending expressions is maintained.
            var results = [Expression]()

            var matchingSuffixLength = 0
            // Filter the queried variables for the suffix matching: for that we only care about
            //  - variables for which the expressions are currently pending (i.e. are being inlined)
            //  - the first occurance of every variable. This is irrelevant for "normal" pending expressions
            //    since they can only occur once (otherwise, they wouldn't be inlined), but is important
            //    for inlined reassignments, e.g. to be able to correctly handle `foo(a = 42, a, bar(), a);`
            var queriedPendingExpressions = [Variable]()
            for v in queriedVariables where pendingExpressions.contains(v) && !queriedPendingExpressions.contains(v) {
                queriedPendingExpressions.append(v)
            }
            for v in queriedPendingExpressions.reversed() {
                assert(matchingSuffixLength < pendingExpressions.count)
                let currentSuffixPosition = pendingExpressions.count - 1 - matchingSuffixLength
                if matchingSuffixLength < pendingExpressions.count && v == pendingExpressions[currentSuffixPosition] {
                    matchingSuffixLength += 1
                }
            }

            if matchingSuffixLength == queriedPendingExpressions.count {
                // This is case 1. from above, so we don't need to emit any pending expressions here \o/
            } else {
                // Case 2, so we need to emit (some) pending expressions.
                let numExpressionsToEmit = pendingExpressions.count - matchingSuffixLength
                for v in pendingExpressions.prefix(upTo: numExpressionsToEmit) {
                    emitPendingExpression(forVariable: v)
                }
                pendingExpressions.removeFirst(numExpressionsToEmit)
            }
            pendingExpressions.removeLast(matchingSuffixLength)

            for v in queriedVariables {
                guard let expression = expressions[v] else {
                    fatalError("Don't have an expression for variable \(v)")
                }
                if expression.isEffectful {
                    usePendingExpression(expression, forVariable: v)
                }
                results.append(expression)
            }

            return results
        }

        /// If the given expression is not an identifier, create a temporary variable and assign the expression to it.
        ///
        /// Mostly used for aesthetical reasons, if an expression is more readable if some subexpression is always an identifier.
        mutating func ensureIsIdentifier(_ expr: Expression, for v: Variable) -> Expression {
            if expr.type === Identifier {
                return expr
            } else if expr.type === AssignmentExpression {
                // Just need to emit the assignment now and return the lhs.
                emit("\(expr);")
                guard let identifier = inlinedReassignments[v] else {
                    fatalError("Don't have an identifier for a reassignment")
                }
                return identifier
            } else {
                // We use a different naming scheme for these temporary variables since we may end up defining
                // them multiple times (if the same expression is "un-inlined" multiple times).
                // We could instead remember the existing local variable for as long as it is visible, but it's
                // probably not worth the effort.
                let V = "t" + String(writer.currentLineNumber)
                emit("\(V) = \(expr);")
                return Identifier.new(V)
            }
        }

        /// Declare the given FuzzIL variable as a JavaScript variable with the given name.
        /// Whenever the variable is used in a FuzzIL instruction, the given identifier will be used in the lifted JavaScript code.
        ///
        /// Note that there is a difference between declaring a FuzzIL variable as a JavaScript identifier and assigning it to the current value of that identifier.
        /// Consider the following FuzzIL code:
        ///
        ///     v0 <- LoadUndefined
        ///     v1 <- LoadInt 42
        ///     Reassign v0 v1
        ///
        /// This code should be lifted to:
        ///
        ///     let v0 = undefined;
        ///     v0 = 42;
        ///
        /// And not:
        ///
        ///     undefined = 42;
        ///
        /// The first (correct) example corresponds to assign()ing v0 the expression 'undefined', while the second (incorrect) example corresponds to declare()ing v0 as 'undefined'.
        @discardableResult
        mutating func declare(_ v: Variable, as maybeName: String? = nil) -> String {
            assert(!expressions.contains(v))
            let name = maybeName ?? "v" + String(v.number)
            expressions[v] = Identifier.new(name)
            return (v.isLocal() ? "local " : "") + name
        }

        /// Declare all of the given variables. Equivalent to calling declare() for each of them.
        /// The variable names will be constructed as prefix + v.number. By default, the prefix "v" is used.
        @discardableResult
        mutating func declareAll(_ vars: ArraySlice<Variable>, usePrefix prefix: String = "v") -> [String] {
            return vars.map({ declare($0, as: prefix + String($0.number)) })
        }

        /// Declare all of the given variables. Equivalent to calling declare() for each of them.
        mutating func declareAll(_ vars: ArraySlice<Variable>, as names: [String]) {
            assert(vars.count == names.count)
            zip(vars, names).forEach({ declare($0, as: $1) })
        }


        mutating func enterNewBlock() {
            emitPendingExpressions()
            writer.increaseIndentionLevel()
        }

        mutating func leaveCurrentBlock() {
            emitPendingExpressions()
            writer.decreaseIndentionLevel()
        }

        mutating func emit(_ line: String) {
            emitPendingExpressions()
            writer.emit(line)
        }

        /// Emit a (potentially multi-line) comment.
        mutating func emitComment(_ comment: String) {
            writer.emitComment(comment)
        }

        /// Emit one or more lines of code.
        mutating func emitBlock(_ block: String) {
            emitPendingExpressions()
            writer.emitBlock(block)
        }

        /// Emit all expressions that are still waiting to be inlined.
        /// This is usually used because some other effectful piece of code is about to be emitted, so the pending expression must execute first.
        mutating func emitPendingExpressions() {
            for v in pendingExpressions {
                emitPendingExpression(forVariable: v)
            }
            pendingExpressions.removeAll()
        }

        mutating func pushTemporaryOutputBuffer(initialIndentionLevel: Int) {
            temporaryOutputBufferStack.push(writer)
            writer = ScriptWriter(stripComments: writer.stripComments, includeLineNumbers: false, indent: writer.indent.count, initialIndentionLevel: initialIndentionLevel)
        }

        mutating func popTemporaryOutputBuffer() -> String {
            assert(pendingExpressions.isEmpty)
            let code = writer.code
            writer = temporaryOutputBufferStack.pop()
            return code
        }

        var isCurrentTemporaryBufferEmpty: Bool {
            return writer.code.isEmpty
        }

        var numPendingExpressions: Int {
            return pendingExpressions.count
        }

        // The following methods are mostly useful for lifting loop headers. See the corresponding for more details.
        mutating func takePendingExpressions() -> [Expression] {
            var result = [Expression]()
            for v in pendingExpressions {
                guard let expr = expressions[v] else {
                    fatalError("Missing expression for variable \(v)")
                }
                usePendingExpression(expr, forVariable: v)
                result.append(expr)
            }
            pendingExpressions.removeAll()
            return result
        }

        mutating func lastPendingExpressionIsFor(_ v: Variable) -> Bool {
            return pendingExpressions.last == v
        }

        mutating func isExpressionPending(for v: Variable) -> Bool {
            return pendingExpressions.contains(v)
        }

        /// Emit the pending expression for the given variable.
        /// Note: this does _not_ remove the variable from the pendingExpressions list. It is the caller's responsibility to do so (as the caller can usually batch multiple removals together).
        private mutating func emitPendingExpression(forVariable v: Variable) {
            guard let EXPR = expressions[v] else {
                fatalError("Missing expression for variable \(v)")
            }
            usePendingExpression(EXPR, forVariable: v)

            if EXPR.type === AssignmentExpression {
                // Reassignments require special handling: there is already a variable declared for the lhs,
                // so we only need to emit the AssignmentExpression as an expression statement.
                writer.emit("\(EXPR);")
            } else if analyzer.numUses(of: v) > 0 {
                let V = declare(v)
                // Need to use writer.emit instead of emit here as the latter will emit all pending expressions.
                writer.emit("\(V) = \(EXPR);")
            } else {
                // Pending expressions with no uses are allowed and are for example necessary to be able to
                // combine multiple expressions into a single comma-expression for e.g. a loop header.
                // See the loop header lifting code and tests for examples.
                writer.emit("\(EXPR);")
            }
        }

        /// When a pending expression is used (either emitted or attached to another expression), it should be removed from the list of
        /// available expressions. Further, inlined reassignments require additional handling, see `reassign` for more details.
        /// This function takes care of both of these things.
        private mutating func usePendingExpression(_ expr: Expression, forVariable v: Variable) {
            // Inlined expressions must only be used once, so delete it from the list of available expressions.
            expressions.removeValue(forKey: v)

            // If the inlined expression is an assignment expression, we now have to restore the previous
            // expression for that variable (which must be an identifier). See `reassign` for more details.
            if let lhs = inlinedReassignments[v] {
                assert(expr.type === AssignmentExpression)
                expressions[v] = lhs
            }
        }

        /// Decide if we should attempt to inline the given expression. We do that if:
        ///  * The output variable is not reassigned later on (otherwise, that reassignment would fail as the variable was never defined)
        ///  * The output variable is pure OR
        ///  * The output variable is effectful and at most one use. However, in this case, the expression will only be inlined if it is still the next expression to be evaluated at runtime.
        private func shouldTryInlining(_ expression: Expression, producing v: Variable) -> Bool {
            if analyzer.numAssignments(of: v) > 1 {
                // Can never inline an expression when the output variable is reassigned again later.
                return false
            }

            /// TODO: maybe improper
            if analyzer.numUses(of: v) == 0{
                return false
            }

            switch expression.characteristic {
            case .pure:
                // We always inline these, which also means that we may not emit them at all if there is no use of them.
                return true

            case .effectful:
                // We also attempt to inline expressions for variables that are unused. This may seem strange since it
                // usually will just lead to the expression being emitted as soon as the next line of code is emitted,
                // however it is necessary to be able to combime multiple expressions into a single comma-expression as
                // is done for example when lifting loop headers.
                // return analyzer.numUses(of: v) <= 1
                return false
            }
        }
    }
}




