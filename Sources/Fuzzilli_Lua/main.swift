import Foundation

let lua_path = "./lua-5.4.4/src/lua"
let profile = LuaProfile



func makeFuzzer(with configuration: Configuration) -> Fuzzer
{
    let runner = REPRL(executable: lua_path, processArguments: profile.processArgs, processEnvironment: profile.processEnv, maxExecsBeforeRespawn: profile.maxExecsBeforeRespawn)
    // The evaluator to score produced samples.
    let evaluator = ProgramCoverageEvaluator(runner: runner)
    let lifter = LuaLifter()

    return Fuzzer(configuration: configuration,evaluator: evaluator, lifter: lifter, scriptrunner: runner)
    
}

// The configuration of this fuzzer.
let configuration = Configuration(logLevel: .info)

let fuzzer = makeFuzzer(with: configuration)

fuzzer.sync{
    // Exit this process when the main fuzzer stops.
    fuzzer.registerEventListener(for: fuzzer.events.ShutdownComplete) { reason in
        exit(reason.toExitCode())
    }

    // Initialize the fuzzer, and run startup tests
    fuzzer.initialize()
}

