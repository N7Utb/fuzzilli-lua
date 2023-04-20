import Foundation
import Fuzzilli_Lua

//
// Process commandline arguments.
//
let args = Arguments.parse(from: CommandLine.arguments)
let swarmTesting = args.has("--swarmTesting")


var exitCondition = Fuzzer.ExitCondition.none

// Initialize the logger such that we can print to the screen.
let logger = Logger(withLabel: "Cli")

let lua_path = "./lua-5.4.4/src/lua"
let profile = LuaProfile
///
/// Chose the code generator weights.
///

if swarmTesting {
    logger.info("Choosing the following weights for Swarm Testing mode.")
    logger.info("Weight | CodeGenerator")
}

let regularCodeGenerators: [(CodeGenerator, Int)] = CodeGenerators.map {
    guard let weight = codeGeneratorWeights[$0.name] else {
        logger.fatal("Missing weight for code generator \($0.name) in CodeGeneratorWeights.swift")
    }
    return ($0, weight)
}
let additionalCodeGenerators = profile.additionalCodeGenerators
let disabledGenerators = Set(profile.disabledCodeGenerators)
var codeGenerators: WeightedList<CodeGenerator> = WeightedList<CodeGenerator>([])

for (generator, var weight) in (additionalCodeGenerators + regularCodeGenerators) {
    if disabledGenerators.contains(generator.name) {
        continue
    }

    if swarmTesting {
        weight = Int.random(in: 1...30)
        logger.info(String(format: "%6d | \(generator.name)", weight))
    }

    codeGenerators.append(generator, withWeight: weight)
}



func makeFuzzer(with configuration: Configuration) -> Fuzzer
{
    let runner = REPRL(executable: lua_path, processArguments: profile.processArgs, processEnvironment: profile.processEnv, maxExecsBeforeRespawn: profile.maxExecsBeforeRespawn)
    // The evaluator to score produced samples.
    let evaluator = ProgramCoverageEvaluator(runner: runner)
    let lifter = LuaLifter()
    let environment = LuaEnvironment()
    let engine = GenerativeEngine()
    // Corpus managing interesting programs that have been found during fuzzing.
    let corpus = BasicCorpus(minSize: 1000, maxSize: 2000, minMutationsPerSample: 5)
    return Fuzzer(configuration: configuration,
                  evaluator: evaluator, 
                  engine: engine, 
                  environment: environment, 
                  lifter: lifter, 
                  corpus: corpus, 
                  scriptrunner: runner, 
                  codeGenerators: codeGenerators)
    
}

// The configuration of this fuzzer.
let configuration = Configuration(logLevel: .verbose)

let fuzzer = makeFuzzer(with: configuration)

// Create a "UI". We do this now, before fuzzer initialization, so
// we are able to print log messages generated during initialization.
let ui = TerminalUI(for: fuzzer)

fuzzer.sync{
    // Always want some statistics.
    fuzzer.addModule(Statistics())

    // Exit this process when the main fuzzer stops.
    fuzzer.registerEventListener(for: fuzzer.events.ShutdownComplete) { reason in
        exit(reason.toExitCode())
    }

    // Initialize the fuzzer, and run startup tests
    fuzzer.initialize()

    // Start the main fuzzing job.
    fuzzer.start(runUntil: exitCondition)

    // let b = fuzzer.makeBuilder()
    // b.buildPrefix()
    // b.build(n: 1)
    // let v1 = b.loadNumber(3)
    // let v2 = b.loadNumber(4.5, isLocal: true)
    // b.loadString("3")
    // b.loadString("4.5", isLocal: true)
    // b.compare(v1, with: v2, using: .equal)
    // b.unary(.Minus, v1)
    
    // let f1 = b.buildFunction(with: .parameters(numParameters: 2, numReturns: 0)){ params in
    //     let v3 = b.loadString("323123")
    //     let v4 = b.loadString("4.5", isLocal: true)
    //     // b.doReturn(nil)
    //     let v5 = b.loadString("323123")
    //     let v6 = b.loadString("4.5", isLocal: true)
    //     b.doReturn([v3,v4])
        
    // }
    // b.callFunction(f1)
    // let p1 = b.finalize()
    // b.reset()
    // b.buildPrefix()
    // b.splice(from: p1)
    // let p2 = b.finalize()
    // print(fuzzer.lifter.lift(p1))
    // print(fuzzer.execute(p2))

    
}
// Install signal handlers to terminate the fuzzer gracefully.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    // Seems like we need this so the dispatch sources work correctly?
    signal(sig, SIG_IGN)

    let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.main)
    source.setEventHandler {
        fuzzer.async {
            fuzzer.shutdown(reason: .userInitiated)
        }
    }
    source.activate()
    signalSources.append(source)
}


// Start dispatching tasks on the main queue.
RunLoop.main.run()