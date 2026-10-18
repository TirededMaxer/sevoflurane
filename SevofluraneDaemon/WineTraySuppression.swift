import Foundation

extension BottleSupervisor {
    /// True when a bottle process runs an executable that is not part of the
    /// client's own infrastructure or Wine's — the cheap "a game is up" signal.
    nonisolated static func isGameRunning() async -> Bool {
        let infrastructure: Set = [
            "steam.exe", "steamwebhelper.exe", "steamservice.exe", "explorer.exe",
            "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
            "rpcss.exe", "conhost.exe", "wineboot.exe", "start.exe", "rundll32.exe",
            "winemenubuilder.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe",
            "tabtip.exe", "gameoverlayui64.exe", "cefwebhelper.exe", "sevo-discord-bridge.exe",
        ]
        let out = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        return WineProcessList.entries(fromPgrepLong: out).contains {
            !infrastructure.contains($0.name)
        }
    }
}
