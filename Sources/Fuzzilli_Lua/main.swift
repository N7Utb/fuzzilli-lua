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

    let b = fuzzer.makeBuilder()
    let v1 = b.loadNumber(3)
    let v2 = b.loadNumber(4.5, isLocal: true)
    b.loadString("3")
    b.loadString("4.5", isLocal: true)
    b.compare(v1, with: v2, using: .equal)
    b.unary(.Minus, v1)
    let f1 = b.buildFunction(with: .parameters(numParameters: 2, numReturns: 0)){ params in
        let v3 = b.loadString("323123")
        let v4 = b.loadString("4.5", isLocal: true)
        // b.doReturn(nil)
        b.doReturn([v3,v4])
        
    }
    b.callFunction(f1)
    let p = b.finalize()
    print(fuzzer.execute(p))

    
}

