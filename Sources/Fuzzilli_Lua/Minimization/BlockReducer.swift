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

/// Reducer to remove unecessary block groups.
struct BlockReducer: Reducer {
    func reduce(_ code: inout Code, with helper: MinimizationHelper) {
        /// Here we iterate over the blocks in the code while also changing the code (by removing blocks). This works
        /// since we are for the most part only nopping out block instructions, not moving them around. In the cases
        /// where code is moved, only code inside the processed block is moved, and the iteration order visits inner
        /// blocks before outer blocks.
        /// As such, the block indices stay valid across these code transformations.
        for group in code.findAllBlockGroups() {
            switch code[group.head].op.opcode {
            case .beginTable:
                assert(group.numBlocks == 1)
                reduceTable(group.block(0), in: &code, with: helper)

            case .beginTableMethod:
                assert(group.numBlocks == 1)
                reduceFunctionInObjectLiteral(group.block(0), in: &code, with: helper)


            case .beginWhileLoopHeader,
                 .beginForLoopInitializer,
                 .beginForInLoop,
                 .beginRepeatLoop:
                reduceLoop(group, in: &code, with: helper)

            case .beginIf:
                reduceIfElse(group, in: &code, with: helper)

            case .beginFunction:
                reduceFunctionOrConstructor(group, in: &code, with: helper)

            default:
                fatalError("Unknown block group: \(code[group.head].op.name)")
            }
        }
    }

    private func reduceTable(_ literal: Block, in code: inout Code, with helper: MinimizationHelper) {
        // The instructions in the body of the object literal aren't valid outside of
        // object literals, so either remove the entire literal or nothing.
        helper.tryNopping(literal.allInstructions, in: &code)
    }

    private func reduceFunctionInObjectLiteral(_ function: Block, in code: inout Code, with helper: MinimizationHelper) {
        // The instruction in the body of these functions aren't valid inside the object literal as
        // they require .javascript context. So either remove the entire function or nothing.
        helper.tryNopping(function.allInstructions, in: &code)
    }



    private func reduceFunctionInClassDefinition(_ function: Block, in code: inout Code, with helper: MinimizationHelper) {
        // Similar to the object literal case, the instructions inside the function body aren't valid inside
        // the surrounding class definition, so we can only try to temove the entire function.
        helper.tryNopping(function.allInstructions, in: &code)
    }

    private func reduceLoop(_ loop: BlockGroup, in code: inout Code, with helper: MinimizationHelper) {
        // We reduce loops by removing the loop itself as well as
        // any 'break' or 'continue' instructions in the loop body.
        var candidates = loop.blockInstructionIndices
        var inNestedLoop = false
        var nestedBlocks = Stack<Bool>()
        for block in loop.blocks {
            for instr in code.body(of: block) {
                if instr.isBlockEnd {
                   inNestedLoop = nestedBlocks.pop()
                }
                if instr.isBlockStart {
                    let isLoop = instr.op.contextOpened.contains(.loop)
                    nestedBlocks.push(inNestedLoop)
                    inNestedLoop = inNestedLoop || isLoop
                }

                if !inNestedLoop && instr.op.requiredContext.contains(.loop) {
                    candidates.append(instr.index)
                }
            }
            assert(nestedBlocks.isEmpty)
        }

        helper.tryNopping(candidates, in: &code)
    }

    private func reduceIfElse(_ group: BlockGroup, in code: inout Code, with helper: MinimizationHelper) {
        assert(code[group.head].op is BeginIf)
        assert(code[group.tail].op is EndIf)

        // First try to remove the entire if-else block but keep its content.
        if helper.tryNopping(group.blockInstructionIndices, in: &code) {
            return
        }

        // Now try to turn if-else into just if.
        if group.numBlocks == 2 {
            // First try to remove the else block.
            let elseBlock = group.block(1)
            let rangeToNop = Array(elseBlock.head ..< elseBlock.tail)
            if helper.tryNopping(rangeToNop, in: &code) {
                return
            }

            // Then try to remove the if block. This requires inverting the condition of the if.
            let ifBlock = group.block(0)
            let beginIf = code[ifBlock.head].op as! BeginIf
            let invertedIf = BeginIf(inverted: !beginIf.inverted)
            var replacements = [(Int, Instruction)]()
            replacements.append((ifBlock.head, Instruction(invertedIf, inouts: code[ifBlock.head].inouts)))
            // The rest of the if body is nopped ...
            for instr in code.body(of: ifBlock) {
                replacements.append((instr.index, helper.nop(for: instr)))
            }
            // ... as well as the BeginElse.
            replacements.append((elseBlock.head, Instruction(Nop())))
            helper.tryReplacements(replacements, in: &code)
        }
    }

    private func reduceGenericBlockGroup(_ group: BlockGroup, in code: inout Code, with helper: MinimizationHelper) {
        var candidates = group.blockInstructionIndices
        if helper.tryNopping(candidates, in: &code) {
            // Success!
            return
        }

        // Also try removing the entire block group, including its content.
        // This is sometimes necessary. Consider the following FuzzIL code:
        //
        //  v6 <- BeginCodeString
        //      v7 <- GetProperty v6, '__proto__'
        //  EndCodeString v7
        //
        // Or, lifted to JavaScript:
        //
        //   const v6 = `
        //       const v7 = v6.__proto__;
        //       v7;
        //   `;
        //
        // Here, neither the single instruction inside the block, nor the two block instruction
        // can be removed independently, since they have data dependencies on each other. As such,
        // the only option is to remove the entire block, including its content.
        candidates = group.instructionIndices
        helper.tryNopping(candidates, in: &code)
    }


    private func reduceFunctionOrConstructor(_ function: BlockGroup, in code: inout Code, with helper: MinimizationHelper) {
        
        // Only attempt generic block group reduction and rely on the InliningReducer to handle more complex scenarios.
        // Alternatively, we could also attempt to turn
        //
        //     v0 <- BeginPlainFunction
        //         someImportantCode
        //     EndPlainFunction
        //
        // Into
        //
        //     v0 <- BeginPlainFunction
        //     EndPlainFunction
        //     someImportantCode
        //
        // So that the calls to the function can be removed by a subsequent reducer if only the body is important.
        // But its likely not worth the effort as the InliningReducer will do a better job at solving this.
        reduceGenericBlockGroup(function, in: &code, with: helper)
    }

}