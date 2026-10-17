import Foundation

/// Why `/program/launch` started nothing, which decides its HTTP status.
enum ProgramLaunchRefusal: Error, Equatable {
    /// No such program, or its file is gone: 404.
    case missing(String)
    /// It is starting or running already, so this request is the extra
    /// click: 409, which the app treats as done rather than failed.
    case busy(String)
    /// It could not be started: 500.
    case failed(String)

    var reason: String {
        switch self {
        case let .missing(reason), let .busy(reason), let .failed(reason): reason
        }
    }

    var status: Int {
        switch self {
        case .missing: 404
        case .busy: 409
        case .failed: 500
        }
    }
}

/// Starting a Windows program that Steam knows nothing about.
///
/// The supervisor owns every bottle process, adopted programs included, so
/// these are its verbs rather than the app's or the CLI's: the app posts to
/// `/program/launch` and the daemon is the parent that appears in the process
/// tree, which is what lets the owner check and the restart ladder account for
/// it.
extension BottleSupervisor {
    /// How long a spawned program has to appear in `pgrep` before a new request
    /// for it is taken as a new launch rather than the extra click.
    static let spawnSettles: Duration = .seconds(60)

    /// Starts an adopted Windows program in the bottle.
    ///
    /// The env files are rewritten first, so the program's own window
    /// treatment, upscaler and launcher bundle are on disk before the process
    /// reads them, and the spawn goes through the same engine invocation as
    /// everything else. Answers a refusal, or `nil` when the program started.
    func launchProgram(id: Int, renderer explicit: Renderer? = nil) async -> ProgramLaunchRefusal? {
        guard let program = AdoptedPrograms.program(id) else {
            return .missing("no adopted program with id \(id)")
        }
        guard program.exists else {
            return .missing("\(program.url.lastPathComponent) is no longer at \(program.path)")
        }
        let name = program.url.lastPathComponent
        // Mark before the first await so repeated clicks start only one program.
        guard programsStarting.insert(id).inserted else {
            note("\(name) is already starting; this request starts nothing")
            return .busy("\(name) is already starting")
        }
        defer { programsStarting.remove(id) }
        if let spawnedAt = programsSpawnedAt[id] {
            if ContinuousClock.now - spawnedAt < Self.spawnSettles, await !Self.isRunning(name) {
                note("\(name) was started \(Int((ContinuousClock.now - spawnedAt).components.seconds)) s ago and has not appeared yet; this request starts nothing")
                return .busy("\(name) is still starting")
            }
            programsSpawnedAt[id] = nil
        }
        await prepareLaunch(appID: id)
        stageGraphics(for: name, renderer: explicit, appID: id)
        programsSpawnedAt[id] = .now
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        await ClientLifecycle.launchInBottle(AdoptedPrograms.invocation(program))
        note("started \(program.url.lastPathComponent) in \(SteamBottle.name)")
        return nil
    }

    /// Whether a Windows program of that file name runs anywhere on this Mac.
    static func isRunning(_ name: String) async -> Bool {
        await !pids(named: name).isEmpty
    }

    static func pids(named name: String) async -> [pid_t] {
        let listing = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        return WineProcessList.pids(named: name, inPgrepLong: listing)
    }

    /// Runs one Windows program to completion in the bottle and answers what
    /// it printed — the "run once" path, which records nothing.
    func runProgram(_ url: URL, arguments: [String], timeout: Duration) async
        -> (status: Int32?, output: String) {
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        return await ClientLifecycle.runInBottle(
            Self.onceInvocation(url, arguments: arguments), timeout: timeout,
        )
    }

    /// Starts one Windows program and returns as soon as it is spawned — a
    /// game played once, which has no useful exit to wait for.
    func startProgram(_ url: URL, arguments: [String]) async {
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        await ClientLifecycle.launchInBottle(Self.onceInvocation(url, arguments: arguments))
        note("started \(url.lastPathComponent) in \(SteamBottle.name)")
    }

    /// The argument list for a program that has no record of its own.
    private static func onceInvocation(_ url: URL, arguments: [String]) -> [String] {
        AdoptedPrograms.invocation(AdoptedProgram(
            path: url.standardizedFileURL.path, arguments: arguments,
            bottle: SteamBottle.name, kind: ProgramKind.program, addedAt: .now,
        ))
    }

    /// Readies a launch before its graphics are staged and its process
    /// spawned (``LaunchPreparation``). A first launch's fixes are said in
    /// the event log here and in a notification by the app.
    func prepareLaunch(appID: Int) async {
        let fixes = await LaunchPreparation.prepare(appID: appID) { EventLog.enqueue(.client, $0) }
        guard let fixes else { return }
        let name = GameConfig.game(appID).name ?? SharedGames.installed(appID: appID)?.name ?? "App \(appID)"
        note(fixes.logLine(appID: appID, name: name))
        Task(name: "Announce app \(appID)'s fixes") { await app.announceFixesApplied(appID: appID) }
    }

    /// Puts the renderer a launch asked for into the engine tree.
    ///
    /// A program launched outside Steam gets a process tree of its own, so the
    /// renderer only has to be staged, never bounced: the DLLs it loads are
    /// the ones on disk when it starts.
    private func stageGraphics(for name: String, renderer explicit: Renderer?, appID: Int) {
        let desired = BottleGraphics.rendererToStage(forApp: appID, explicit: explicit)
        guard let desired, desired != BottleGraphics.currentSelection().renderer else { return }
        do {
            let current = BottleGraphics.currentSelection()
            try BottleGraphics.applyToActiveEngine(
                BottleGraphics.Selection(
                    renderer: desired, msync: current.msync, gpu: current.gpu,
                ),
            )
        } catch {
            note("could not set \(desired.label) for \(name): \(error)")
            return
        }
        if let staged = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
            note(staged)
        }
    }

    private func note(_ message: String) {
        EventLog.shared.log(.client, message)
    }
}
