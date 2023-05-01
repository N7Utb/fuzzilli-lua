import Foundation
public class Fuzzer {
    /// Id of this fuzzer.
    public let id: UUID

    /// Has this fuzzer been initialized?
    public private(set) var isInitialized = false
    
    /// Has this fuzzer been stopped?
    public private(set) var isStopped = false

    /// The list of events that can be dispatched on this fuzzer instance.
    public let events: Events

    /// Timer API for this fuzzer.
    public let timers: Timers

    /// The evaluator to score generated programs.
    public let evaluator: ProgramEvaluator

    /// The mutators used by the engine.
    public let mutators: WeightedList<Mutator>

    /// The model of the target environment.
    public let environment: Environment

    /// The lifter to translate FuzzIL programs to the target language.
    public let lifter: Lifter

    /// The corpus of "interesting" programs found so far.
    public let corpus: Corpus

    /// The engine used for initial corpus generation (if performed).
    public let corpusGenerationEngine = GenerativeEngine()

    /// The configuration used by this fuzzer.
    public let config: Configuration

    /// The script runner used to execute generated scripts.
    public let runner: ScriptRunner

    /// The fuzzer engine producing new programs from existing ones and executing them.
    public let engine: FuzzEngine

    /// The active code generators. It is possible to change these (temporarily) at runtime. This is e.g. done by some ProgramTemplates.
    public private(set) var codeGenerators: WeightedList<CodeGenerator>

    /// Start time of this fuzzing session
    private let startTime = Date()

    /// Returns the uptime of this fuzzer as TimeInterval.
    public func uptime() -> TimeInterval {
        return -startTime.timeIntervalSinceNow
    }

    /// DispatchGroup to group all tasks related to a fuzzing iteration together and thus be able to determine when they have all finished.
    /// The next fuzzing iteration will only be performed once all tasks in this group have finished. As such, this group can generally be used
    /// for all (long running) tasks during which it doesn't make sense to perform fuzzing.
    private let fuzzGroup = DispatchGroup()

    /// The logger instance for the main fuzzer.
    private var logger: Logger

    public enum ExitCondition {
        // Fuzz indefinitely.
        case none
        // Fuzz until a specified number of iterations have been performed.
        case iterationsPerformed(Int)
        // Fuzz for a specified amount of time.
        case timeFuzzed(TimeInterval)
    }

    /// How long to fuzz?
    private var exitCondition = ExitCondition.none

    /// Currently active corpus import job, if any.
    private var currentCorpusImportJob = CorpusImportJob(corpus: [], mode: .full)

    /// The modules active on this fuzzer.
    var modules = [String: Module]()

    /// The DispatchQueue  this fuzzer operates on.
    /// This could in theory be publicly exposed, but then the stopping logic wouldn't work correctly anymore and would probably need to be implemented differently.
    private let queue: DispatchQueue

    /// The possible states of a fuzzer.
    public enum State {
        // Initial state of the fuzzer. Will be changed to one of the below states during
        // initialization.
        case uninitialized

        // When running as a child node for distributed fuzzing, indicates that we're waiting
        // for our parent node to send as our initial corpus.
        // Child nodes remain in this state (and do effectively nothing) until they have
        // received a corpus (containing at least one program) from their parent node.
        case waiting

        // Importing and potentially minimizing an existing corpus.
        case corpusImport

        // Generating an initial corpus. Used when no existing corpus is imported and when
        // this instance isn't configured to receive a corpus from its parent node.
        case corpusGeneration

        // Fuzzing with the configured engine.
        case fuzzing
    }

    /// The current state of this fuzzer.
    public private(set) var state: State = .uninitialized

    private func changeState(to newState: State) {
        logger.info("Changing state from \(state) to \(newState)")

        // Some state transitions are forbidden, check for those here.
        assert(newState != .uninitialized)      // We never transition into .uninitialized
        assert(newState != .waiting || state == .uninitialized)     // We're only transitioning into .waiting during initialization
        assert(state != .fuzzing)   // Currently we never transition out of .fuzzing (although we could allow scheduling a corpus import while already fuzzing)

        state = newState
    }

    /// State management.
    private var iterations = 0
    private var iterationOfLastInteratingSample = 0

    private var iterationsSinceLastInterestingProgram: Int {
        assert(iterations >= iterationOfLastInteratingSample)
        return iterations - iterationOfLastInteratingSample
    }

    /// Fuzzer instances can be looked up from a dispatch queue through this key. See below.
    private static let dispatchQueueKey = DispatchSpecificKey<Fuzzer>()

    public init(configuration: Configuration, 
                evaluator: ProgramEvaluator, 
                engine: FuzzEngine,
                mutators: WeightedList<Mutator>,
                environment: Environment,
                lifter: Lifter,
                corpus: Corpus,
                scriptrunner: ScriptRunner,
                codeGenerators: WeightedList<CodeGenerator>,
                queue: DispatchQueue? = nil){
        let uniqueId = UUID()
        self.id = uniqueId
        self.events = Events()
        self.evaluator = evaluator
        self.mutators = mutators
        self.environment = environment
        self.engine = engine
        self.lifter = lifter
        self.corpus = corpus
        self.runner = scriptrunner
        self.config = configuration
        self.codeGenerators = codeGenerators
        self.logger = Logger(withLabel: "Fuzzer")
        self.queue = queue ?? DispatchQueue(label: "Fuzzer \(uniqueId)", target: DispatchQueue.global())
        self.timers = Timers(queue: self.queue)

        self.queue.setSpecific(key: Fuzzer.dispatchQueueKey, value: self)

    }

    /// Set the CodeGenerators (and their respecitve weight) to use when generating new code.
    public func setCodeGenerators(_ generators: WeightedList<CodeGenerator>) {
        guard generators.contains(where: { $0.isValueGenerator }) else {
            fatalError("Code generators must contain at least one value generator")
        }
        self.codeGenerators = generators
    }

    /// Adds a module to this fuzzer. Can only be called before the fuzzer is initialized.
    public func addModule(_ module: Module) {
        assert(!isInitialized)
        assert(modules[module.name] == nil)

        modules[module.name] = module
        
        /// TODO: childnode
        // We only allow one instance of certain modules.
        // assert(modules.values.filter( { $0 is DistributedFuzzingChildNode }).count <= 1)
    }

    /// Initializes this fuzzer.
    ///
    /// This will initialize all components and modules, causing event listeners to be registerd,
    /// timers to be scheduled, communication channels to be established, etc. After initialization,
    /// task may already be scheduled on this fuzzer's dispatch queue.
    public func initialize() {
        dispatchPrecondition(condition: .onQueue(queue))
        assert(!isInitialized)

        // Initialize the script runner first so we are able to execute programs.
        runner.initialize(with: self)
        
        // Then initialize all components.
        engine.initialize(with: self)
        evaluator.initialize(with: self)
        environment.initialize(with: self)
        corpus.initialize(with: self)
        // minimizer.initialize(with: self)
        corpusGenerationEngine.initialize(with: self)

        // Finally initialize all modules.
        for module in modules.values {
            module.initialize(with: self)
        }

        // Install a watchdog to monitor the utilization of this instance.
        // var lastCheck = Date()
        // timers.scheduleTask(every: 1 * Minutes) {
        //     // Monitor responsiveness
        //     let now = Date()
        //     let interval = now.timeIntervalSince(lastCheck)
        //     lastCheck = now
        //     if interval > 180 {
        //         self.logger.warning("Fuzzer appears unresponsive (watchdog only triggered after \(Int(interval))s instead of 60s).")
        //     }
        // }

        // Determine our initial state if necessary.
        assert(state == .uninitialized || state == .corpusImport)
        if state == .uninitialized {
            /// TODO: childNode
            // let isChildNode = modules.values.contains(where: { $0 is DistributedFuzzingChildNode })
            // if isChildNode {
            //     // We're a child node, so wait until we've received some kind of corpus from our parent node.
            //     // We'll change our state when we're synchronized with our parent, see updateStateAfterSynchronizingWithParentNode() below.
            //     changeState(to: .waiting)
            // } else {
            //     // Start with corpus generation.
            //     assert(corpus.isEmpty)
            //     changeState(to: .corpusGeneration)
            // }

            assert(corpus.isEmpty)
            changeState(to: .corpusGeneration)
        }

        dispatchEvent(events.Initialized)
        logger.info("Initialized")
        isInitialized = true
    }

    /// Returns the fuzzer for the active DispatchQueue.
    public static var current: Fuzzer? {
        return DispatchQueue.getSpecific(key: Fuzzer.dispatchQueueKey)
    }

    /// Schedule work on this fuzzer's dispatch queue.
    public func async(do block: @escaping () -> ()) {
        queue.async {
            guard !self.isStopped else { return }
            block()
        }
    }

    /// Schedule work on this fuzzer's dispatch queue and wait for its completion.
    public func sync(do block: () -> ()) {
        queue.sync {
            guard !self.isStopped else { return }
            block()
        }
    }

    /// Computes and returns the corpus import progress as percentage.
    public func corpusImportProgress() -> Double {
        assert(state == .corpusImport)
        return currentCorpusImportJob.progress()
    }

    /// Executes a program.
    ///
    /// This will first lift the given FuzzIL program to the target language, then use the configured script runner to execute it.
    ///
    /// - Parameters:
    ///   - program: The FuzzIL program to execute.
    ///   - timeout: The timeout after which to abort execution. If nil, the default timeout of this fuzzer will be used.
    /// - Returns: An Execution structure representing the execution outcome.
    public func execute(_ program: Program, withTimeout timeout: UInt32? = nil) -> Execution {
        dispatchPrecondition(condition: .onQueue(queue))
        assert(runner.isInitialized)

        let script = lifter.lift(program)
        dispatchEvent(events.PreExecute, data: program)
        let execution = runner.run(script, withTimeout: timeout ?? config.timeout)
        dispatchEvent(events.PostExecute, data: execution)

        return execution
    }
    /// Process a program that appears to have interesting aspects.
    /// This function will first determine which (if any) of the interesting aspects are triggered reliably, then schedule the program for minimization and inclusion in the corpus.
    /// Returns true if this program was interesting (i.e. had at least some interesting aspects that are triggered reliably), false if not.
    @discardableResult
    func processMaybeInteresting(_ program: Program, havingAspects aspects: ProgramAspects, origin: ProgramOrigin) -> Bool {
        var aspects = aspects

        // Determine which (if any) aspects of the program are triggered deterministially.
        // For that, the sample is executed at a few more times and the intersection of the interesting aspects of each execution is computed.
        // Once that intersection is stable, the remaining aspects are considered to be triggered deterministic.
        let minAttempts = 5
        let maxAttempts = 50
        var didConverge = false
        var attempt = 0
        repeat {
            attempt += 1
            if attempt > maxAttempts {
                logger.warning("Sample did not converage after \(maxAttempts) attempts. Discarding it")
                return false
            }

            guard let intersection = evaluator.computeAspectIntersection(of: program, with: aspects) else {
                // This likely means that no aspects are triggered deterministically, so discard this sample.
                return false
            }

            // Since evaluateAndIntersect will only ever return aspects that are equivalent to, or a subset of,
            // the provided aspects, we can check if they are identical by comparing their sizes
            didConverge = aspects.count == intersection.count
            aspects = intersection
        } while !didConverge || attempt < minAttempts

        if origin == .local {
            iterationOfLastInteratingSample = iterations
        }

        // Determine whether the program needs to be minimized, then, using this helper function, dispatch the appropriate
        // event and insert the sample into the corpus.
        func finishProcessing(_ program: Program) {
            if config.enableInspection {
                if origin == .local {
                    program.comments.add("Program is interesting due to \(aspects)", at: .footer)
                } else {
                    program.comments.add("Imported program is interesting due to \(aspects)", at: .footer)
                }
            }
            assert(!program.code.contains(where: { $0.op is LuaInternalOperation }))
            dispatchEvent(events.InterestingProgramFound, data: (program, origin))

            // If we're running in static corpus mode, we only add programs to our corpus during corpus import.
            if !config.staticCorpus || origin.isFromCorpusImport() {
                corpus.add(program, aspects)
            }
        }
        /// TODO: Minizer
        finishProcessing(program)
        // if !origin.requiresMinimization() {
        //     finishProcessing(program)
        // } else {
        //     // Minimization should be performed as part of the fuzzing dispatch group. This way, the next fuzzing iteration
        //     // will only start once the curent sample has been fully processed and inserted into the corpus.
        //     fuzzGroup.enter()
        //     minimizer.withMinimizedCopy(program, withAspects: aspects, limit: config.minimizationLimit) { minimizedProgram in
        //         self.fuzzGroup.leave()
        //         finishProcessing(minimizedProgram)
        //     }
        // }
        return true
    }

        /// Process a program that causes a crash.
    func processCrash(_ program: Program, withSignal termsig: Int, withStderr stderr: String, withStdout stdout: String, origin: ProgramOrigin, withExectime exectime: TimeInterval) {
        func processCommon(_ program: Program) {
            let hasCrashInfo = program.comments.at(.footer)?.contains("CRASH INFO") ?? false
            if !hasCrashInfo {
                program.comments.add("CRASH INFO", at: .footer)
                program.comments.add("==========", at: .footer)
                if let tag = config.tag {
                    program.comments.add("INSTANCE TAG: \(tag)", at: .footer)
                }
                program.comments.add("TERMSIG: \(termsig)", at: .footer)
                program.comments.add("STDERR:", at: .footer)
                program.comments.add(stderr.trimmingCharacters(in: .newlines), at: .footer)
                program.comments.add("STDOUT:", at: .footer)
                program.comments.add(stdout.trimmingCharacters(in: .newlines), at: .footer)
                program.comments.add("ARGS: \(runner.processArguments.joined(separator: " "))", at: .footer)
                program.comments.add("CONTRIBUTORS: \(program.contributors.map({ $0.name }).joined(separator: ", "))", at: .footer)
                program.comments.add("EXECUTION TIME: \(Int(exectime * 1000))ms", at: .footer)
            }
            assert(program.comments.at(.footer)?.contains("CRASH INFO") ?? false)

            // Check for uniqueness only after minimization
            let execution = execute(program, withTimeout: self.config.timeout * 2)
            if case .crashed = execution.outcome {
                let isUnique = evaluator.evaluateCrash(execution) != nil
                dispatchEvent(events.CrashFound, data: (program, .deterministic, isUnique, origin))
            } else {
                dispatchEvent(events.CrashFound, data: (program, .flaky, true, origin))
            }
        }
        /// TODO: Minizer
        if !origin.requiresMinimization() {
            return processCommon(program)
        }
        return processCommon(program)
        // fuzzGroup.enter()
        // minimizer.withMinimizedCopy(program, withAspects: ProgramAspects(outcome: .crashed(termsig))) { minimizedProgram in
        //     self.fuzzGroup.leave()
        //     processCommon(minimizedProgram)
        // }
    }



    /// Constructs a new ProgramBuilder using this fuzzing context.
    public func makeBuilder(forMutating parent: Program? = nil) -> ProgramBuilder {
        dispatchPrecondition(condition: .onQueue(queue))
        // Program ancestor chains are only constructed if inspection mode is enabled
        let parent = config.enableInspection ? parent : nil
        return ProgramBuilder(for: self, parent: parent)
    }

    /// Performs one round of fuzzing.
    private func fuzzOne() {
        dispatchPrecondition(condition: .onQueue(queue))
        assert(currentCorpusImportJob.isFinished || state == .corpusImport)

        guard !self.isStopped else { return }

        // Check if we are done fuzzing.
        switch exitCondition {
        case .none:
            break
        case .iterationsPerformed(let maxIterations):
            if iterations > maxIterations {
                return shutdown(reason: .finished)
            }
        case .timeFuzzed(let maxRuntime):
            if uptime() > maxRuntime {
                return shutdown(reason: .finished)
            }
        }

        switch state {
        case .uninitialized:
            fatalError("This state should never be observed here")

        case .waiting:
            // Nothing to do, we're waiting for our parent node to send us a corpus.
            // To avoid idle spinning, just sleep for a short while
            Thread.sleep(forTimeInterval: 5 * Seconds)

            if uptime() > 15 * Minutes {
                logger.fatal("Did not receive a corpus from our parent node within 15 minutes")
            }

        case .corpusImport:
            assert(!currentCorpusImportJob.isFinished)
            let program = currentCorpusImportJob.nextProgram()

            if currentCorpusImportJob.numberOfProgramsImportedSoFar % 500 == 0 {
                logger.info("Corpus import prograss: imported \(currentCorpusImportJob.numberOfProgramsImportedSoFar) of \(currentCorpusImportJob.totalNumberOfProgramsToImport) programs")
            }

            let outcome = importProgram(program, origin: .corpusImport(mode: currentCorpusImportJob.importMode))
            currentCorpusImportJob.notifyImportOutcome(outcome)

            if currentCorpusImportJob.isFinished {
                logger.info("Corpus import finished:")
                logger.info("\(currentCorpusImportJob.numberOfProgramsThatExecutedSuccessfullyDuringImport)/\(currentCorpusImportJob.totalNumberOfProgramsToImport) programs executed successfully during import")
                logger.info("\(currentCorpusImportJob.numberOfProgramsThatTimedOutDuringImport)/\(currentCorpusImportJob.totalNumberOfProgramsToImport) programs timed out during import")
                logger.info("\(currentCorpusImportJob.numberOfProgramsThatFailedDuringImport)/\(currentCorpusImportJob.totalNumberOfProgramsToImport) programs failed to execute during import")
                logger.info("Corpus now contains \(corpus.size) programs")
                changeState(to: .fuzzing)
            }
        case .corpusGeneration:
            // We should never perform corpus generation if we're using a static corpus.
            // assert(!config.staticCorpus)

            iterations += 1
            corpusGenerationEngine.fuzzOne(fuzzGroup)

            // Perform initial corpus generation until we haven't found a new interesting sample in the last N
            // iterations. The rough order of magnitude of N has been determined experimentally: run two instances with
            // different values (e.g. 10 and 100) for roughly the same number of iterations (approximately until both
            // have finished the initial corpus generation), then compare the corpus size and coverage.
            if iterationsSinceLastInterestingProgram > 100 {
                guard !corpus.isEmpty else {
                    logger.fatal("Initial corpus generation failed, corpus is still empty. Is the evaluator working correctly?")
                }
                logger.info("Initial corpus generation finished. Corpus now contains \(corpus.size) elements")
                changeState(to: .fuzzing)
            }
            // changeState(to: .fuzzing)
        case .fuzzing:
            iterations += 1
            engine.fuzzOne(fuzzGroup)
        }

        // Perform the next iteration as soon as all tasks related to the current iteration are finished.
        fuzzGroup.notify(queue: queue) {
            self.fuzzOne()
        }
    }

    /// Starts the fuzzer and runs for the specified number of iterations.
    ///
    /// This must be called after initializing the fuzzer.
    /// Use -1 for maxIterations to run indefinitely.
    public func start(runUntil exitCondition: ExitCondition = .none) {
        dispatchPrecondition(condition: .onQueue(queue))
        assert(isInitialized)

        self.exitCondition = exitCondition

        logger.info("Let's go!")

        fuzzOne()
    }

    /// Shuts down this fuzzer.
    public func shutdown(reason: ShutdownReason) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped else { return }

        // No more scheduled tasks will execute after this point.
        isStopped = true
        timers.stop()

        logger.info("Shutting down due to \(reason)")
        dispatchEvent(events.Shutdown, data: reason)

        dispatchEvent(events.ShutdownComplete, data: reason)
    }

    /// Registers a new listener for the given event.
    public func registerEventListener<T>(for event: Event<T>, listener: @escaping Event<T>.EventListener) {
        dispatchPrecondition(condition: .onQueue(queue))
        event.addListener(listener)
    }

    /// Dispatches an event, potentially with some data attached to the event.
    public func dispatchEvent<T>(_ event: Event<T>, data: T) {
        dispatchPrecondition(condition: .onQueue(queue))
        for listener in event.listeners {
            listener(data)
        }
    }
    private func dispatchEvent(_ event: Event<Void>) {
        dispatchEvent(event, data:())
    }


    /// Imports a potentially interesting program into this fuzzer.
    ///
    /// When importing, the program will be treated like one that was generated by this fuzzer. As such it will
    /// be executed and evaluated to determine whether it results in previously unseen, interesting behaviour.
    /// When dropout is enabled, a configurable percentage of programs will be ignored during importing. This
    /// mechanism can help reduce the similarity of different fuzzer instances.
    @discardableResult
    public func importProgram(_ program: Program, enableDropout: Bool = false, origin: ProgramOrigin) -> ExecutionOutcome {
        dispatchPrecondition(condition: .onQueue(queue))

        if enableDropout && probability(config.dropoutRate) {
            return .succeeded
        }

        let execution = execute(program)

        switch execution.outcome {
        case .crashed(let termsig):
            // Here we explicitly deal with the possibility that an interesting sample
            // from another instance triggers a crash in this instance.
            processCrash(program, withSignal: termsig, withStderr: execution.stderr, withStdout: execution.stdout, origin: origin, withExectime: execution.execTime)

        case .succeeded:
            var imported = false
            if let aspects = evaluator.evaluate(execution) {
                imported = processMaybeInteresting(program, havingAspects: aspects, origin: origin)
            }

            if case .corpusImport(let mode) = origin, mode == .full, !imported {
                // We're performing a full corpus import, so the sample still needs to be added to our corpus even though it doesn't trigger any new behaviour.
                corpus.add(program, ProgramAspects(outcome: .succeeded))
                // We also dispatch the InterestingProgramFound event here since we technically found an interesting program, but also so that the program is forwarded to child nodes.
                dispatchEvent(events.InterestingProgramFound, data: (program, origin))
            }

        default:
            break
        }

        return execution.outcome
    }

    /// A pending corpus import job together with some statistics.
    private struct CorpusImportJob {
        private var corpusToImport: [Program]

        let importMode: CorpusImportMode
        let totalNumberOfProgramsToImport: Int

        private(set) var numberOfProgramsImportedSoFar = 0
        private(set) var numberOfProgramsThatFailedDuringImport = 0
        private(set) var numberOfProgramsThatTimedOutDuringImport = 0
        private(set) var numberOfProgramsThatExecutedSuccessfullyDuringImport = 0

        init(corpus: [Program], mode: CorpusImportMode) {
            self.corpusToImport = corpus.reversed()         // Programs are taken from the end.
            self.importMode = mode
            self.totalNumberOfProgramsToImport = corpus.count
        }

        var isFinished: Bool {
            return corpusToImport.isEmpty
        }

        mutating func nextProgram() -> Program {
            assert(!isFinished)
            numberOfProgramsImportedSoFar += 1
            return corpusToImport.removeLast()
        }

        mutating func notifyImportOutcome(_ outcome: ExecutionOutcome) {
            switch outcome {
            case .crashed:
                // This is unexpected so we don't track these
                break
            case .failed:
                numberOfProgramsThatFailedDuringImport += 1
            case .succeeded:
                numberOfProgramsThatExecutedSuccessfullyDuringImport += 1
            case .timedOut:
                numberOfProgramsThatTimedOutDuringImport += 1
            }
        }

        func progress() -> Double {
            let numberOfProgramsToImport = Double(totalNumberOfProgramsToImport)
            let numberOfProgramsAlreadyImported = Double(numberOfProgramsImportedSoFar)
            return numberOfProgramsAlreadyImported / numberOfProgramsToImport
        }
    }
}