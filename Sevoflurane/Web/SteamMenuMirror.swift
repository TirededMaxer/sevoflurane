import AppKit

/// Reads Steam's original Friends menu for the Dock's persona-status choices.
/// Steam's visible menu strip stays inside its original web document.
@MainActor
final class SteamMenuMirror {
    struct MirroredItem: Decodable, Equatable {
        var sep: Bool?
        var label: String?
        var on: Bool?
        var disabled: Bool?
    }
    private weak var host: SteamWebHost?
    private var model: [String: [MirroredItem]] = [:]
    private var refreshing = false

    init(host: SteamWebHost) {
        self.host = host
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            defer { refreshing = false }
            for _ in 0..<10 {
                if let raw = await host?.evaluateInContext(Self.fetchScript),
                   let data = raw.data(using: .utf8),
                   let roots = try? JSONDecoder().decode([String: [MirroredItem]].self, from: data),
                   !(roots[Self.friendsTitle] ?? []).isEmpty {
                    model = roots
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @discardableResult
    func cancelTracking() -> [String] {
        MenuTrackingWatchdog.cancelMenuBarTracking()
        if MenuTrackingWatchdog.privateLeverEngages {
            _ = MenuTrackingWatchdog.stopPrivateSession(candidateMenus: [NSApp.mainMenu].compactMap(\.self))
        }
        return []
    }

    private static let fetchScript = """
    (function () {
      var roots = {};
      g_PopupManager.m_mapPopups.forEach(function (v) {
        var title = v.m_strTitle || "";
        if (title !== "Friends Root Menu") return;
        var p = v.m_popup;
        var doc = p && !p.closed && p.document;
        if (!doc || !doc.body) return;
        var el = doc.body;
        while (el && el.children.length === 1) el = el.children[0];
        if (!el) return;
        roots[title.replace(/ Root Menu$/, "")] =
          Array.prototype.map.call(el.children, function (c) {
            if (c.tagName === "HR") return { sep: true };
            return { label: c.textContent.trim(),
                     on: !!c.querySelector("svg, img"),
                     disabled: c.getAttribute("aria-disabled") === "true" };
          });
      });
      return JSON.stringify(roots);
    })()
    """

    // MARK: - Friends status

    /// One persona state as the Friends menu offers it: Steam's label, in
    /// Steam's language, and where the strip holds it.
    struct StatusChoice: Equatable {
        let label: String
        /// The DOM child index ``clickScript(rootTitle:childIndex:label:)``
        /// takes.
        let childIndex: Int
        /// Whether this is the state the user is in: Steam marks it with a
        /// check.
        let isCurrent: Bool
        let isEnabled: Bool
    }

    private static let friendsTitle = "Friends"

    /// Online, Away, Invisible and Offline.
    private static let personaStateCount = 4

    /// The persona states the cached Friends menu offers, in Steam's order;
    /// empty until the page has answered for it.
    var friendsStatuses: [StatusChoice] {
        Self.statusChoices(in: model[Self.friendsTitle] ?? [])
    }

    /// The Friends menu's last group, which Steam builds from the four
    /// persona states. It is found by position so it reads the same in every
    /// language Steam speaks; a last group of any other size is some other
    /// menu, and answers none.
    static func statusChoices(in items: [MirroredItem]) -> [StatusChoice] {
        guard let rule = items.lastIndex(where: { $0.sep == true }) else { return [] }
        let group = items.indices.dropFirst(rule + 1)
        guard group.count == personaStateCount,
              group.allSatisfy({ items[$0].sep != true && !(items[$0].label ?? "").isEmpty })
        else { return [] }
        return group.map { index in
            StatusChoice(
                label: items[index].label ?? "",
                childIndex: index,
                isCurrent: items[index].on == true,
                isEnabled: items[index].disabled != true,
            )
        }
    }

    func setFriendsStatus(_ choice: StatusChoice) {
        Task { [weak self] in
            _ = await self?.host?.evaluateInContext(Self.clickScript(
                rootTitle: Self.friendsTitle, childIndex: choice.childIndex, label: choice.label
            ))
            self?.refresh()
        }
    }

    /// Clicks the item's element in the hidden root-menu popup. The index is
    /// the DOM child index (separators included), the one the fetch read the
    /// item at; the element is clicked only while its text is still `label`,
    /// so a strip Steam changed since the last read answers "moved" instead
    /// of running its neighbor.
    static func clickScript(rootTitle: String, childIndex: Int, label: String) -> String {
        """
        (function () {
          var doc = null;
          g_PopupManager.m_mapPopups.forEach(function (v) {
            if (v.m_strTitle === \(JSLiteral.string(rootTitle + " Root Menu"))) {
              var p = v.m_popup;
              if (p && !p.closed) doc = p.document;
            }
          });
          if (!doc || !doc.body) return "no popup";
          var el = doc.body;
          while (el && el.children.length === 1) el = el.children[0];
          var item = el && el.children[\(childIndex)];
          if (!item || item.tagName === "HR") return "no item";
          if (item.textContent.trim() !== \(JSLiteral.string(label))) return "moved";
          item.click();
          return "clicked";
        })()
        """
    }

}
