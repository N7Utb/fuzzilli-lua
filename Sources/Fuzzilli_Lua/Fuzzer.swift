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

    /// The lifter to translate FuzzIL programs to the target language.
    public let lifter: Lifter

    /// The configuration used by this fuzzer.
    public let config: Configuration

    /// The script runner used to execute generated scripts.
    public let runner: ScriptRunner

    /// The logger instance for the main fuzzer.
    private var logger: Logger

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

    /// Fuzzer instances can be looked up from a dispatch queue through this key. See below.
    private static let dispatchQueueKey = DispatchSpecificKey<Fuzzer>()

    public init(configuration: Configuration, evaluator: ProgramEvaluator, lifter: Lifter,scriptrunner: ScriptRunner,queue: DispatchQueue? = nil){
        let uniqueId = UUID()
        self.id = uniqueId
        self.events = Events()
        self.evaluator = evaluator
        self.lifter = lifter
        self.runner = scriptrunner
        self.config = configuration
        
        self.logger = Logger(withLabel: "Fuzzer")
        self.queue = queue ?? DispatchQueue(label: "Fuzzer \(uniqueId)", target: DispatchQueue.global())
        self.timers = Timers(queue: self.queue)

        self.queue.setSpecific(key: Fuzzer.dispatchQueueKey, value: self)

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
        // engine.initialize(with: self)
        evaluator.initialize(with: self)
        // environment.initialize(with: self)
        // corpus.initialize(with: self)
        // minimizer.initialize(with: self)
        // corpusGenerationEngine.initialize(with: self)

        // // Finally initialize all modules.
        // for module in modules.values {
        //     module.initialize(with: self)
        // }

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
        // if state == .uninitialized {
        //     let isChildNode = modules.values.contains(where: { $0 is DistributedFuzzingChildNode })
        //     if isChildNode {
        //         // We're a child node, so wait until we've received some kind of corpus from our parent node.
        //         // We'll change our state when we're synchronized with our parent, see updateStateAfterSynchronizingWithParentNode() below.
        //         changeState(to: .waiting)
        //     } else {
        //         // Start with corpus generation.
        //         assert(corpus.isEmpty)
        //         changeState(to: .corpusGeneration)
        //     }
        // }s

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
}