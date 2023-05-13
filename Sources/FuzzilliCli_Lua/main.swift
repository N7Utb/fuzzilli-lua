import Foundation
import Fuzzilli_Lua

// Helper function that prints out an error message, then exits the process.
func configError(_ msg: String) -> Never {
    print(msg)
    exit(-1)
}


//
// Process commandline arguments.
//
let args = Arguments.parse(from: CommandLine.arguments)
let swarmTesting = args.has("--swarmTesting")
let consecutiveMutations = args.int(for: "--consecutiveMutations") ?? 5
let numJobs = args.int(for: "--jobs") ?? 1
let DebugTest = args.has("--debug")
let storagePath = args["--storagePath"]
var resume = args.has("--resume")
let overwrite = args.has("--overwrite")
let exportStatistics = args.has("--exportStatistics")
let statisticsExportInterval = args.uint(for: "--statisticsExportInterval") ?? 10

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

if (resume || overwrite) && storagePath == nil {
    configError("--resume and --overwrite require --storagePath")
}

if let path = storagePath {
    let directory = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    if !directory.isEmpty && !resume && !overwrite {
        configError("Storage path \(path) exists and is not empty. Please specify either --resume or --overwrite or delete the directory manually")
    }
}

if resume && overwrite {
    configError("Must only specify one of --resume and --overwrite")
}

if exportStatistics && storagePath == nil {
    configError("--exportStatistics requires --storagePath")
}

if statisticsExportInterval <= 0 {
    configError("statisticsExportInterval needs to be > 0")
}

if args.has("--statisticsExportInterval") && !exportStatistics  {
    configError("statisticsExportInterval requires --exportStatistics")
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

func loadCorpus(from dirPath: String) -> [Program] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir) && isDir.boolValue else {
        logger.fatal("Cannot import programs from \(dirPath), it is not a directory!")
    }

    var programs = [Program]()
    let fileEnumerator = FileManager.default.enumerator(atPath: dirPath)
    while let filename = fileEnumerator?.nextObject() as? String {
        guard filename.hasSuffix(".fzil") else { continue }
        let path = dirPath + "/" + filename
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let pb = try FuzzilliLua_Protobuf_Program(serializedData: data)
            let program = try Program.init(from: pb)
            if !program.isEmpty {
                programs.append(program)
            }
        } catch {
            logger.error("Failed to load program \(path): \(error). Skipping")
        }
    }

    return programs
}

func makeFuzzer(with configuration: Configuration) -> Fuzzer
{
    let runner = REPRL(executable: lua_path, processArguments: profile.processArgs, processEnvironment: profile.processEnv, maxExecsBeforeRespawn: profile.maxExecsBeforeRespawn)
    // The evaluator to score produced samples.
    let evaluator = ProgramCoverageEvaluator(runner: runner)
    let lifter = LuaLifter()
    let environment = LuaEnvironment()
    // let engine = GenerativeEngine()
    let engine = MutationEngine(numConsecutiveMutations: consecutiveMutations)
    // Corpus managing interesting programs that have been found during fuzzing.
    let corpus = BasicCorpus(minSize: 1000, maxSize: 2000, minMutationsPerSample: 5)
    /// The mutation fuzzer responsible for mutating programs from the corpus and evaluating the outcome.
    let mutators: WeightedList<Mutator> = WeightedList([
        // (ExplorationMutator(),              3),
        (CodeGenMutator(),                  2),
        (SpliceMutator(),                   2),
        // (ProbingMutator(),                  2),
        (InputMutator(isTypeAware: false),  2),
        (InputMutator(isTypeAware: true),   1),
        // Can be enabled for experimental use, ConcatMutator is a limited version of CombineMutator
        (ConcatMutator(),                   1),
        (OperationMutator(),                1),
        (CombineMutator(),                  1),
        (JITStressMutator(),                1),
    ])
    // Minimizer to minimize crashes and interesting programs.
    let minimizer = Minimizer()
    return Fuzzer(configuration: configuration,
                  evaluator: evaluator, 
                  engine: engine, 
                  mutators: mutators,
                  environment: environment, 
                  lifter: lifter, 
                  corpus: corpus, 
                  minimizer: minimizer,
                  scriptrunner: runner, 
                  codeGenerators: codeGenerators)
    
}

func unitTest(with fuzzer: Fuzzer){
    fuzzer.sync{
    // Always want some statistics.
    fuzzer.addModule(Statistics())

    // Exit this process when the main fuzzer stops.
    fuzzer.registerEventListener(for: fuzzer.events.ShutdownComplete) { reason in
        exit(reason.toExitCode())
    }

    // Initialize the fuzzer, and run startup tests
    fuzzer.initialize()
    // let b = fuzzer.makeBuilder()
    let exec = fuzzer.runner.run("while 1 do end", withTimeout: 1000)
    print(exec.outcome)
    
    // b.buildForLoop {
    //     b.loadNumber(2)
    // }
    // String.random(ofLength: 1, withCharSet: .l)
    
    // String.randomElement(CharacterSet.letters)
    
    // b.buildLabel(b.nextLabel())
    // let v1 = b.loadNumber(123)
    // let _ = b.loadString("abc")
    // // let s = b.loadBuiltin("math")
    // b.buildRepeatLoop(n: 10){
    //     b.loadString("abc")
    // }
    // b.buildRepeatLoop(n: 10){ v in
    //     b.loadString("abc")

    // }

    // let v1 = b.loadBoolean(true)
    // let n = b.loadNil()
    // let f1 = b.buildFunction(with: .parameters(n: 0)) { _ in
    //     b.loadString("ccc")
    // }
    // let t1 = b.buildTable({ td in
    //     td.addMethod("a", with: .parameters(n: 0)){ v in
    //         b.loadString("ddd")
    //         b.loadNumber(2)
    //         let f2 = b.buildFunction(with: .parameters(n: 0)) { _ in
    //             b.loadString("ccc")
    //         }
    //         b.callFunction(f2)
    //     }
    // })
    // b.callFunction(f1)
    // b.callMethod("a", on: t1)


    // b.loadNumber(4)
    // let v1 = b.loadNumber(5)
    // let v2 = b.loadString("ccc")
    // b.buildPrefix()
    // b.run(CodeGenerators.get("TableGenerator"))
    // b.loadString("ddd")
    // let methodName = "gmatch"
    // let propertyName = "pi"
    // b.buildPair(b.createArray(with: [b.loadNumber(1), b.loadNumber(2)]))
    // TODO: here and below, if we aren't finding arguments of compatible types, we probably still need a try-catch guard.
    // let arguments = b.randomArguments(forCallingMethod: methodName, on: s)
    // print(222)
    // print(b.getMethodNumReturns(of: methodName, on: s))
    // let v1 = b.callMethod(methodName, on: s, withArgs: arguments, numReturns: b.getMethodNumReturns(of: methodName, on: s))[0]
    // b.buildForInLoop(v1){ _ in

    // }
    // print(b.type(of: s))
    // let loopVar = b.loadNumber(0)
    // let c1 = b.compare(loopVar, with: b.loadNumber(Float64.random(in: 1...10)), using: .lessThan) 
    // var c2: Variable = b.loadNumber(0)
    // b.buildWhileLoop({ 
    //     c2 = b.compare(loopVar, with: b.loadNumber(Float64.random(in: 1...10)), using: .lessThan) 
    //     return c1}, {
    //         b.loadNumber(0)
    //         b.compare(c2, with: b.loadNumber(Float64.random(in: 1...10)), using: .lessThan) 
    // })
    
    // b.run(CodeGenerators.get("PropertyAssignmentGenerator"))
    // b.run(CodeGenerators.get("PropertyUpdateGenerator"))
    // b.run(CodeGenerators.get("PropertyRemovalGenerator"))
    // b.createArray(with: [v1, v2])
    // b.buildForLoop(i: {
    //     b.buildLabel(b.nextLabel())
    //     b.loadNumber(123)
    //     return b.binary(b.loadNumber(5), b.loadNumber(0), with: BinaryOperator.Add)
    // }, {  
    //     b.loadNumber(123)
        
    //     return b.loadNumber(10)
    // }, {
    //     b.loadNumber(123)
    //     return b.binary(b.loadNumber(5), b.loadNumber(15), with: BinaryOperator.Add)
    // },  { v in
    //     b.binary(v, b.loadNumber(0), with: BinaryOperator.Add)
    // })
    // b.buildGoto(b.randomLabel()!)
    // let label = b.nextLabel()
    // b.buildForLoop(i: { b.loadNumber(0) }, { b.loadNumber(Float64.random(in: 10...20))}, {b.loadNumber(1)}) { loopVar in
    //     b.buildIf(b.compare(loopVar, with: b.loadNumber(5), using: .greaterThan)){
    //         b.buildGoto(label)
    //     }
    // }
    // b.buildLabel(label)
    // print(b.dumpCurrentProgram())
    // let p1 = b.finalize()
    // print(fuzzer.lifter.lift(p1))

    // let execution = fuzzer.execute(p1)
    // let aspects = fuzzer.evaluator.evaluate(execution)
    // let p2 = fuzzer.minimizer.minimize(p1, withAspects: aspects!)
    // let mutator = InputMutator(isTypeAware: true)
    // let p2 = mutator.mutate(p1, for: fuzzer)
    // print(fuzzer.lifter.lift(p2!))
    
    // print(fuzzer.lifter.lift(p2))

    
}
}
// The configuration of this fuzzer.
let configuration = Configuration(logLevel: .verbose)

let fuzzer = makeFuzzer(with: configuration)

// Create a "UI". We do this now, before fuzzer initialization, so
// we are able to print log messages generated during initialization.
let ui = TerminalUI(for: fuzzer)

if DebugTest { 
    unitTest(with: fuzzer)
    exit(0)
}

fuzzer.sync{
    // Always want some statistics.
    fuzzer.addModule(Statistics())

    // Store samples to disk if requested.
    if let path = storagePath {
        if resume {
            // Move the old corpus to a new directory from which the files will be imported afterwards
            // before the directory is deleted.
            do {
                try FileManager.default.moveItem(atPath: path + "/corpus", toPath: path + "/old_corpus")
            } catch {
                logger.info("Nothing to resume from: \(path)/corpus does not exist")
                resume = false
            }
        } else if overwrite {
            logger.info("Deleting all files in \(path) due to --overwrite")
            try? FileManager.default.removeItem(atPath: path)
        } else {
            // The corpus directory must be empty. We already checked this above, so just assert here
            let directory = (try? FileManager.default.contentsOfDirectory(atPath: path + "/corpus")) ?? []
            assert(directory.isEmpty)
        }

        fuzzer.addModule(Storage(for: fuzzer,
                                 storageDir: path,
                                 statisticsExportInterval: exportStatistics ? Double(statisticsExportInterval) * Minutes : nil
        ))
    }

    // Synchronize with thread workers if requested.
    if numJobs > 1 {
        fuzzer.addModule(ThreadParent(for: fuzzer))
    }

    // Exit this process when the main fuzzer stops.
    fuzzer.registerEventListener(for: fuzzer.events.ShutdownComplete) { reason in
        exit(reason.toExitCode())
    }

    // Resume a previous fuzzing session ...
    if resume, let path = storagePath {
        var corpus = loadCorpus(from: path + "/old_corpus")
        logger.info("Scheduling import of \(corpus.count) programs from previous fuzzing run.")

        // Reverse the order of the programs, so that older programs are imported first.
        corpus.reverse()

        // Delete the old corpus directory now
        try? FileManager.default.removeItem(atPath: path + "/old_corpus")

        fuzzer.scheduleCorpusImport(corpus, importMode: .interestingOnly(shouldMinimize: false))  // We assume that the programs are already minimized
    }

    // Initialize the fuzzer, and run startup tests
    fuzzer.initialize()

    // Start the main fuzzing job.
    fuzzer.start(runUntil: exitCondition)
}

// Add thread worker instances if requested
// Worker instances use a slightly different configuration, mostly just a lower log level.
let workerConfig = Configuration(logLevel: .verbose)

for _ in 1..<numJobs {
    let worker = makeFuzzer(with: workerConfig)
    worker.async {
        // Wait some time between starting workers to reduce the load on the main instance.
        // If we start the workers right away, they will all very quickly find new coverage
        // and send lots of (probably redundant) programs to the main instance.
        let minDelay = 1 * Minutes
        let maxDelay = 10 * Minutes
        let delay = Double.random(in: minDelay...maxDelay)
        Thread.sleep(forTimeInterval: delay)

        worker.addModule(Statistics())
        worker.addModule(ThreadChild(for: worker, parent: fuzzer))
        worker.initialize()
        worker.start()
    }
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