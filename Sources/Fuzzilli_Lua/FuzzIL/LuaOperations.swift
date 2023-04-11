final class LoadInteger: Operation {
    override var opcode: Opcode { .loadInteger(self) }

    let value: Int64

    init(value: Int64) {
        self.value = value
        super.init(numOutputs: 1, attributes: [.isPure, .isMutable])
    }
}
