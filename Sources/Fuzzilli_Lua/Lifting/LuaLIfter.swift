import Foundation

/// Lifter to convert FuzzIL into its human readable text format
public class LuaLifter: Lifter {
    public init() {}
    public func lift(_ program: Program, withOptions options: LiftingOptions) -> String {
        var w = ScriptWriter()



        return w.code
    }
}