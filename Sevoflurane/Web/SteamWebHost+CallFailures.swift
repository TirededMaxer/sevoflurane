import Foundation

extension SteamWebHost {
    /// Writes one call Steam's client refused to the event log, once per
    /// message while the app runs: a call the page keeps making would
    /// otherwise fill the log with one line.
    func noteSteamCallFailure(_ line: String) {
        let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, loggedSteamCallFailures.insert(message).inserted else { return }
        EventLog.shared.log(.client, "Steam refused a call: \(message)")
    }

    /// Subscribes the context page to the client's console and passes on the
    /// lines in which Steam refuses a `SteamClient` call, back through the
    /// popup message handler as `__steamCallFailure`.
    ///
    /// The client answers a call it refuses with nothing at all: the caller's
    /// promise resolves, and only the console says why. A Steam update that
    /// changes a method's arguments then shows up as a button that does
    /// nothing, so this is where such a change is seen first.
    static let callFailureScript = """
    (function () {
      if (window.__sevoCallFailures) return "already registered";
      if (!window.SteamClient || !SteamClient.Console
          || !SteamClient.Console.RegisterForSpewOutput) return "unavailable";
      window.__sevoCallFailures = true;
      SteamClient.Console.RegisterForSpewOutput(function (line) {
        var text = String((line && line.spew) || "");
        if (text.indexOf("RaiseJSException") === -1 && text.indexOf("Method call failed") === -1) return;
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage({ fn: "__steamCallFailure", args: [text.slice(0, 500)] });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
