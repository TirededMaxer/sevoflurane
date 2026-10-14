#!/usr/bin/env python3
"""Compares every SteamClient call in this repository with the calls Steam's own UI makes.

The client refuses a call with too few arguments and answers it with nothing but a console
line, so a Steam update that adds a parameter shows up as a button that does nothing. This
reads the argument counts from the running client's webpack modules (through `sevo eval`)
and lists each of our calls that passes fewer than Steam's own code ever does.

Run it after a Steam client update, with Sevoflurane's Steam up:  Tools/steam-call-audit.py
Exits 1 when a call falls short.
"""

import json
import re
import subprocess
import sys

STEAM_SIDE = r"""
(function () {
  var req = null;
  webpackChunksteamui.push([["sevo-audit-" + Date.now()], {}, function (r) { req = r; }]);
  function count(s, i) {
    var depth = 0, n = 0, any = false, quote = null;
    for (var j = i; j < s.length && j < i + 4000; j++) {
      var c = s[j];
      if (quote) { if (c === "\\") { j++; continue; } if (c === quote) quote = null; continue; }
      if (c === '"' || c === "'" || c === "`") { quote = c; any = true; continue; }
      if (c === "(" || c === "[" || c === "{") { depth++; any = true; continue; }
      if (c === ")" || c === "]" || c === "}") { if (depth === 0) return any ? n + 1 : 0; depth--; continue; }
      if (c === "," && depth === 0) { n++; continue; }
      if (!/\s/.test(c)) any = true;
    }
    return -1;
  }
  var seen = {};
  for (var id in req.m) {
    var s = String(req.m[id]), re = /SteamClient\.(\w+)\.(\w+)\(/g, m;
    while ((m = re.exec(s))) {
      var n = count(s, re.lastIndex);
      if (n >= 0) (seen[m[1] + "." + m[2]] = seen[m[1] + "." + m[2]] || {})[n] = 1;
    }
  }
  var out = {};
  for (var k in seen) out[k] = Object.keys(seen[k]).map(Number);
  return JSON.stringify(out);
})()
"""


def count(source: str, start: int) -> int:
    """The number of top-level arguments in the call whose `(` ends at `start`; -1 if unclosed."""
    depth, commas, nonempty, quote, i = 0, 0, False, None, start
    while i < len(source) and i < start + 4000:
        c = source[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'`":
            quote, nonempty = c, True
        elif c in "([{":
            depth, nonempty = depth + 1, True
        elif c in ")]}":
            if depth == 0:
                return commas + 1 if nonempty else 0
            depth -= 1
        elif c == "," and depth == 0:
            commas += 1
        elif not c.isspace():
            nonempty = True
        i += 1
    return -1


def main() -> int:
    answer = subprocess.run(["sevo", "eval", STEAM_SIDE], capture_output=True, text=True, timeout=90)
    if answer.returncode != 0:
        print(answer.stderr.strip() or "sevo eval failed: is Sevoflurane's Steam up?", file=sys.stderr)
        return 2
    steam = json.loads(json.loads(answer.stdout))
    files = subprocess.run(["git", "ls-files", "*.swift", "*.js"], capture_output=True, text=True).stdout.split()
    short, unseen, total = [], set(), 0
    for path in files:
        if "Tests/" in path:
            continue
        source = open(path, errors="ignore").read()
        for call in re.finditer(r"SteamClient\.(\w+)\.(\w+)\(", source):
            method, given = f"{call.group(1)}.{call.group(2)}", count(source, call.end())
            total += 1
            if method not in steam:
                unseen.add(method)
            elif 0 <= given < min(steam[method]):
                line = source.count("\n", 0, call.start()) + 1
                short.append(f"{path}:{line}  {method} passes {given}, Steam's own code passes {sorted(steam[method])}")
    print(f"{total} calls checked against {len(steam)} methods Steam's UI calls")
    print("\n".join(short) if short else "every call passes at least as many arguments as Steam's own")
    if unseen:
        print("not called by Steam's UI, so unchecked:", ", ".join(sorted(unseen)))
    return 1 if short else 0


if __name__ == "__main__":
    sys.exit(main())
