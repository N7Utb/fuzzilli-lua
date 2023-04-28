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
public extension LuaType{
    

    static let luaTable = LuaType.table

    static let luaStringObject = table(ofGroup: "string", withProperties: [], withMethods: ["upper", "lower","gsub","find", "reverse", "char", "byte", "len", "rep", "gmatch", "match", "sub"])

    static let luaMathObject = table(ofGroup: "math", withProperties: ["pi", "maxinteger", "mininteger", "huge"], withMethods: ["abs", "acos", "asin", "atan2", "atan", "ceil", "cosh", "cos", "deg", "exp", "floor", "fmod", "frexp", "ldexp", "log10", "log", "max", "min", "modf", "pow", "rad", "random", "randomseed", "sinh", "sin", "sqrt", "tanh", "tan"])

    static let luaUtf8Object = table(ofGroup: "utf8", withProperties: ["charpattern"], withMethods: ["char", "codes", "codepoint", "len", "offset"])
}

public class LuaEnvironment: ComponentBase, Environment{
    // Possible return values of the 'typeof' operator.
    public static let LuaTypeNames = ["nil", "boolean", "number", "string", "function"]
    // Integer values that are more likely to trigger edge-cases.
    public let interestingIntegers: [Int64] = [
        -9223372036854775808, -9223372036854775807,               // Int64 min, mostly for BigInts
        -9007199254740992, -9007199254740991, -9007199254740990,  // Smallest integer value that is still precisely representable by a double
        -4294967297, -4294967296, -4294967295,                    // Negative Uint32 max
        -2147483649, -2147483648, -2147483647,                    // Int32 min
        -1073741824, -536870912, -268435456,                      // -2**32 / {4, 8, 16}
        -65537, -65536, -65535,                                   // -2**16
        -4096, -1024, -256, -128,                                 // Other powers of two
        -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 64,         // Numbers around 0
        127, 128, 129,                                            // 2**7
        255, 256, 257,                                            // 2**8
        512, 1000, 1024, 4096, 10000,                             // Misc numbers
        65535, 65536, 65537,                                      // 2**16
        268435456, 536870912, 1073741824,                         // 2**32 / {4, 8, 16}
        2147483647, 2147483648, 2147483649,                       // Int32 max
        4294967295, 4294967296, 4294967297,                       // Uint32 max
        9007199254740990, 9007199254740991, 9007199254740992,     // Biggest integer value that is still precisely representable by a double
        9223372036854775806,  9223372036854775807                 // Int64 max, mostly for BigInts (TODO add Uint64 max as well?)
    ]
    public let numberType: LuaType = LuaType.number
    public let booleanType: LuaType = LuaType.boolean
    public let stringType = LuaType.string
    public let tableType = LuaType.luaTable
    

    // Double values that are more likely to trigger edge-cases.
    public let interestingFloats = [-Double.infinity, -Double.greatestFiniteMagnitude, -1e-15, -1e12, -1e9, -1e6, -1e3, -5.0, -4.0, -3.0, -2.0, -1.0, -Double.ulpOfOne, -Double.leastNormalMagnitude, -0.0, 0.0, Double.leastNormalMagnitude, Double.ulpOfOne, 1.0, 2.0, 3.0, 4.0, 5.0, 1e3, 1e6, 1e9, 1e12, 1e-15, Double.greatestFiniteMagnitude, Double.infinity, Double.nan]

    public let interestingStrings: [String] = LuaTypeNames

    public private(set) var builtins = Set<String>()
    public let customProperties = Set<String>(["a", "b", "c", "d", "e", "f", "g", "h"])
    public let customMethods = Set<String>(["m", "n", "o", "p", "valueOf", "toString"])
    public private(set) var builtinProperties = Set<String>()
    public private(set) var builtinMethods = Set<String>()

    private var builtinTypes: [String: LuaType] = [:]
    private var groups: [String: ObjectGroup] = [:]


    public init(additionalBuiltins: [String: LuaType] = [:]) {
        super.init(name: "LuaEnvironment")

        registerObjectGroup(.luaStringObject)
        registerObjectGroup(.luaMathObject)

        registerBuiltin("string", ofType: .luaStringObject)
        registerBuiltin("math", ofType: .luaMathObject)
    }
    override func initialize() {
        // Log detailed information about the environment here so users are aware of it and can modify things if they like.
        logger.info("Initialized static Lua environment model")
        logger.info("Have \(builtins.count) available builtins: \(builtins)")
        logger.info("Have \(groups.count) different object groups: \(groups.keys)")
        logger.info("Have \(builtinProperties.count) builtin property names: \(builtinProperties)")
        logger.info("Have \(builtinMethods.count) builtin method names: \(builtinMethods)")
        logger.info("Have \(customProperties.count) custom property names: \(customProperties)")
        logger.info("Have \(customMethods.count) custom method names: \(customMethods)")
    }
    public func type(ofBuiltin builtinName: String) -> LuaType {
        if let type = builtinTypes[builtinName] {
            return type
        } else {
            logger.warning("Missing type for builtin \(builtinName)")
            return .anything
        }
    }

    public func type(ofProperty propertyName: String, on baseType: LuaType) -> LuaType {
        if let groupName = baseType.group {
            if let group = groups[groupName] {
                if let type = group.properties[propertyName] {
                    return type
                }
                else if let type = baseType.additionalproperties[propertyName]{
                    return type
                }
            } else {
                // This shouldn't happen, probably forgot to register the object group
                logger.warning("No type information for object group \(groupName) available")
            }
        }

        return .anything
    }


    public func signature(ofMethod methodName: String, on baseType: LuaType) -> Signature {

        if let groupName = baseType.group {
            if let group = groups[groupName] {
                if let type = group.methods[methodName] {
                    // print(groupName, methodName)
                    return type
                }

            } else {
                // This shouldn't happen, probably forgot to register the object group
                logger.warning("No type information for object group \(groupName) available")
            }
        }
        return Signature.forUnknownFunction
    }

    public func registerBuiltin(_ name: String, ofType type: LuaType) {
        assert(builtinTypes[name] == nil)
        builtinTypes[name] = type
        builtins.insert(name)
    }

    public func registerObjectGroup(_ group: ObjectGroup) {
        assert(groups[group.name] == nil)
        groups[group.name] = group
        builtinProperties.formUnion(group.properties.keys)
        builtinMethods.formUnion(group.methods.keys)
    }
}

/// A struct to encapsulate property and method type information for a group of related objects.
public struct ObjectGroup {
    public let name: String
    public let properties: [String: LuaType]
    public let methods: [String: Signature]

    /// The type of instances of this group.
    public let instanceType: LuaType

    public init(name: String, instanceType: LuaType, properties: [String: LuaType], methods: [String: Signature]) {
        self.name = name
        self.instanceType = instanceType
        self.properties = properties
        self.methods = methods
    }
}

// Type information for the object groups that we use to model the JavaScript runtime environment.
// The general rules here are:
//  * "output" type information (properties and return values) should be as precise as possible
//  * "input" type information (function parameters) should be as broad as possible
public extension ObjectGroup {
    /// Object group modelling JavaScript strings
    static let luaStringObject = ObjectGroup(
        name: "string",
        instanceType: .string,
        properties: [:],
        methods: [
            "upper"       : [.string] => [.string],
            "lower"       : [.string] => [.string],
            "gsub"        : [.string, .string, .string, .opt(.number)] => [.string, .number], 
            "find"        : [.string, .string, .opt(.number), .opt(.boolean)] => [.number, .number],
            "reverse"     : [.string] => [.string],
            /// TODO: format
            "char"        : [.rest(.number)] => [.string],
            "byte"        : [.string, .opt(.number)] => [.number],
            "len"         : [.string] => [.number],
            "rep"         : [.string, .number] => [.string],
            "gmatch"      : [.string, .string] => [.plain(.function([] => [.string]) + .iterable)],
            "match"       : [.string, .string, .opt(.number)] => [.number, .string],
            "sub"         : [.string, .number ,.opt(.number)] => [.string]
        ]
    )

    static let luaMathObject = ObjectGroup(
        name: "math", 
        instanceType: .luaMathObject, 
        properties: [
            "pi"          : .number,
            "maxinteger"  : .number, 
            "mininteger"  : .number, 
            "huge"        : .number
            ], 
        methods: [
            "abs"         : [.number] => [.number],
            "acos"        : [.number] => [.number],
            "asin"        : [.number] => [.number],
            "atan2"       : [.number, .number] => [.number],
            "atan"        : [.number] => [.number], 
            "ceil"        : [.number] => [.number],
            "cosh"        : [.number] => [.number],
            "cos"         : [.number] => [.number],
            "deg"         : [.number] => [.number],
            "exp"         : [.number] => [.number],
            "floor"       : [.number] => [.number],
            "fmod"        : [.number, .number] => [.number],
            "frexp"       : [.number] => [.number, .number],
            "ldexp"       : [.number, .number] => [.number],
            "log10"       : [.number] => [.number],
            "log"         : [.number] => [.number],
            "max"         : [.rest(.number)] => [.number],
            "min"         : [.rest(.number)] => [.number],
            "modf"        : [.number] => [.number, .number],
            "pow"         : [.number, .number] => [.number],
            "rad"         : [.number] => [.number],
            "random"      : [.number, .opt(.number)] => [.number],
            "randomseed"  : [.number] => [],
            "sinh"        : [.number] => [.number], 
            "sin"         : [.number] => [.number], 
            "sqrt"        : [.number] => [.number], 
            "tanh"        : [.number] => [.number], 
            "tan"         : [.number] => [.number], 
            "ult"         : [.number, .number] => [.boolean]
            ]
        )
    static let luaUtf8Object = ObjectGroup(
        name: "utf8", 
        instanceType: .luaUtf8Object, 
        properties: [
            "charpattern" : .string
        ], 
        methods: [
            "char"        : [.rest(.number)] => [.string],
            "codes"       : [.string] => [.plain(.iterable + .function([] => [.number, .number]))],
            "codepoint"   : [.string, .opt(.number), .opt(.number)] => [.number],
            "len"         : [.string, .opt(.number), .opt(.number)] => [.number],
            "offset"      : [.string, .number, .opt(.number)] => [.number],
            ]
        )

}