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

/// Default weights for the builtin code generators.
public let codeGeneratorWeights = [
    // Value generators. These are used to bootstrap code
    // generation and therefore control the types of variables
    // available at the start of code generation.
    "NumberGenerator":                          20,
    "StringGenerator":                          20,
    "BooleanGenerator":                         10,
    "NilGenerator":                             5,
    "LabelGenerator":                           3,
    "TrivialFunctionGenerator":                 10,
    "FunctionGenerator":                        15,
    "FunctionCallGenerator":                    15,
    "SubroutineReturnGenerator":                3,
    "UnaryOperationGenerator":                  10,
    "BinaryOperationGenerator":                 40,
    "ComparisonGenerator":                      10,
    "IfElseGenerator":                          10,
    "CompareWithIfElseGenerator":               15,
    "WhileLoopGenerator":                       15,
    "ReassignmentGenerator":                    20,
    "UpdateGenerator":                          20,

    "SimpleForLoopGenerator":                   10,
    "ForInLoopGenerator":                       10,
    "GotoGenerator":                            5,
    "MethodCallGenerator":                      20,
    "BuiltinGenerator":                         10,
    "PairGenerator":                            10,
    "PropertyRetrievalGenerator":               20,
    "PropertyAssignmentGenerator":              20,
    "PropertyUpdateGenerator":                  10,
    "PropertyRemovalGenerator":                 5,
    "ElementRetrievalGenerator":                20,
    "ElementAssignmentGenerator":               20,
    "ElementUpdateGenerator":                   7,
    "ElementRemovalGenerator":                  5,

    "TableGenerator":                           20, 
    "TablePropertyGenerator":                   5,
    "TableElementGenerator":                    5,
    "TableMethodGenerator":                     5,

    "NumberComputationGenerator":               10,

]
