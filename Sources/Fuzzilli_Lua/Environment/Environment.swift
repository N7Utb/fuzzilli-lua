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

/// Model of the execution environment.
public protocol Environment: Component {
    /// List of integer values that might yield interesting behaviour or trigger edge cases in the target language.
    var interestingIntegers: [Int64] { get }

    /// List of floating point values that might yield interesting behaviour or trigger edge cases in the target language.
    var interestingFloats: [Double] { get }

    /// List of string values that might yield interesting behaviour or trigger edge cases in the target language.
    var interestingStrings: [String] { get }

    /// List of all builtin objects in the target environment.
    var builtins: Set<String> { get }

    /// Custom property names to use when defining new properties on objects.
    /// These should not exist on builtin objects.
    var customProperties: Set<String> { get }

    /// List of properties that exist on at least one type of builtin objects.
    var builtinProperties: Set<String> { get }

    /// Custom method names to use when defining new methods on objects.
    /// These should not exist on builtin objects.
    var customMethods: Set<String> { get }

    /// List of methods that exist on at least one builtin object.
    var builtinMethods: Set<String> { get }

    /// The type representing integers in the target environment.
    var numberType: LuaType { get }

    /// The type representing booleans in the target environment.
    var booleanType: LuaType { get }

    /// The type representing strings in the target environment.
    var stringType: LuaType { get }

    /// The type representing arrays in the target environment.
    /// Used e.g. for arrays created through a literal.
    var tableType: LuaType { get }

    /// Retuns the type of the builtin with the given name.
    func type(ofBuiltin builtinName: String) -> LuaType

    /// Returns the type of the property on the provided base object.
    func type(ofProperty propertyName: String, on baseType: LuaType) -> LuaType

    /// Returns the signature of the specified method of he base object.
    func signature(ofMethod methodName: String, on baseType: LuaType) -> Signature
}
