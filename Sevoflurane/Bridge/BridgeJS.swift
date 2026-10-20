import Foundation

/// The JavaScript the bridge injects or evaluates. Fidelity rules: shape
/// mirroring, base64 envelopes carrying the view type, rejection objects
/// never stringified, callbacks routed per page.
nonisolated enum BridgeJS {
    /// SharedConnection — the protobuf transport the UI gets its real data
    /// from — passes ArrayBuffers, which JSON drops silently. Both sides
    /// translate binary to base64 envelopes instead.
    static let binaryCodec = #"""
    (() => {
      const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return btoa(s); };
      /* The view type travels with the bytes: Steam hands some callbacks a
         Uint8Array and rejects an ArrayBuffer in its place. */
      window.__sevoEnc = function (v) {
        if (v instanceof ArrayBuffer) return { __sevoBin: b64(new Uint8Array(v)), __sevoView: '' };
        if (ArrayBuffer.isView(v)) {
          return { __sevoBin: b64(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)),
                   __sevoView: v.constructor.name };
        }
        if (Array.isArray(v)) return v.map(window.__sevoEnc);
        /* Binary hides inside plain objects too (parental settings, and anything
           else that hands back a protobuf field alongside scalars). */
        if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype) {
          const out = {};
          for (const k of Object.keys(v)) out[k] = window.__sevoEnc(v[k]);
          return out;
        }
        return v;
      };
      window.__sevoDec = function (v) {
        if (v && typeof v === 'object' && typeof v.__sevoBin === 'string') {
          const s = atob(v.__sevoBin), u = new Uint8Array(s.length);
          for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
          if (!v.__sevoView) return u.buffer;
          const Ctor = window[v.__sevoView] || Uint8Array;
          return Ctor === Uint8Array ? u : new Ctor(u.buffer);
        }
        if (Array.isArray(v)) return v.map(window.__sevoDec);
        if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype) {
          const out = {};
          for (const k of Object.keys(v)) out[k] = window.__sevoDec(v[k]);
          return out;
        }
        return v;
      };
      return 'codec ready';
    })()
    """#

    /// Each renderer has its own NotificationStore. Share only the identities
    /// removed for presentation, leaving Steam's tray, unread state and per-app
    /// prompts alone. This factory runs unchanged in CEF and WebKit.
    static let toastSync = #"""
    window.__sevoInstallToastSync = function (store, emit) {
      if (!store || typeof store.PopNextToastNotification !== 'function'
          || typeof store.DispatchNextToast !== 'function') return null;
      if (store.__sevoToastSync) {
        store.__sevoToastSync.emit = emit;
        return store.__sevoToastSync;
      }
      var consumed = new Set(), pruning = false;
      var sync = { store: store, emit: emit,
        epoch: String(Date.now()) + ':' + Math.random(),
        snapshot: function () { return Array.from(consumed); },
        receive: function (keys) {
          keys.forEach(function (key) { if (typeof key === 'string') consumed.add(key); });
          prune();
        },
        reset: function (keys) { consumed.clear(); sync.receive(keys); }
      };
      function key(item) {
        if (!item || item.notificationID == null) return null;
        // Server rollups reuse their group ID for later messages. Match the
        // underlying server item too, so a new rollup is not mistaken for an old toast.
        var serverItem = item.eSource === 2 && item.data && item.data.item;
        return JSON.stringify([item.eSource, item.eType, String(item.notificationID),
          serverItem ? String(serverItem.notification_id) : '']);
      }
      function prune() {
        if (pruning) return;
        pruning = true;
        try {
          // ExpireToast compares just the rollup ID and could also remove a
          // newer server item in that rollup. Remove only the exact consumed
          // identity here; notify subscribers through Steam's original dispatch.
          var queue = store.m_rgNotificationToasts || [];
          var remaining = queue.filter(function (item) { return !consumed.has(key(item)); });
          if (remaining.length !== queue.length) {
            store.m_rgNotificationToasts = remaining;
            if (queue[0] !== remaining[0]) store.DispatchNextToast();
          }
        } finally { pruning = false; }
      }
      var dispatch = store.DispatchNextToast;
      store.DispatchNextToast = function () {
        prune();
        return dispatch.apply(this, arguments);
      };
      var pop = store.PopNextToastNotification;
      store.PopNextToastNotification = function () {
        prune();
        var pending = (store.m_rgNotificationToasts || [])[0];
        var item = pop.apply(this, arguments);
        // The original method can instead return an app-only Shift+Tab or
        // achievement prompt. Those queues belong exclusively to Steam.
        if (item && item === pending) {
          var id = key(item);
          if (id && !consumed.has(id)) {
            consumed.add(id);
            try { sync.emit([id]); }
            catch (e) { console.error('[sevo] toast consumption sync:', e); }
          }
        }
        return item;
      };
      store.__sevoToastSync = sync;
      return sync;
    };
    """#

    /// Opens the relay socket from inside SharedJSContext. `%RELAY_PORT%` is
    /// substituted before evaluation.
    static let tunnel = #"""
    (() => {
      if (window.__sevoRelay && window.__sevoRelay.readyState <= 1) return 'relay live';
      /* The client's own context is the only one allowed to open a transport
         socket, but it can reach the bridge freely. Relaying frames over one
         socket it owns keeps the hot protobuf path off CDP entirely — driving it
         with an evaluate per frame wedges steamwebhelper. */
      const relay = new WebSocket('ws://127.0.0.1:%RELAY_PORT%');
      relay.binaryType = 'arraybuffer';
      /* The bridge takes a socket as its relay on this first message. */
      relay.onopen = () => relay.send(JSON.stringify({ type: 'hello' }));
      window.__sevoRelay = relay;
      const socks = window.__sevoTunnels = {};
      const ctl = (o) => { if (relay.readyState === 1) relay.send(JSON.stringify(o)); };
      /* Frames are length-prefixed with their tunnel id so one relay socket can
         carry every tunnel without a JSON hop around the payload. */
      const frame = (id, buf) => {
        const idb = new TextEncoder().encode(id);
        if (idb.length > 255) return;
        const out = new Uint8Array(1 + idb.length + buf.byteLength);
        out[0] = idb.length;
        out.set(idb, 1);
        out.set(new Uint8Array(buf), 1 + idb.length);
        if (relay.readyState === 1) relay.send(out.buffer);
      };
      relay.onmessage = (e) => {
        if (typeof e.data === 'string') {
          const m = JSON.parse(e.data);
          if (m.cmd === 'ws_open') {
            let s;
            try { s = new WebSocket(m.url); }
            catch (err) { ctl({ type: 'ws_event', id: m.id, ev: 'close', code: 1006 }); return; }
            s.binaryType = 'arraybuffer';
            socks[m.id] = s;
            s.onopen = () => ctl({ type: 'ws_event', id: m.id, ev: 'open' });
            s.onerror = () => ctl({ type: 'ws_event', id: m.id, ev: 'error' });
            s.onclose = (ev) => {
              delete socks[m.id];
              ctl({ type: 'ws_event', id: m.id, ev: 'close', code: ev.code, reason: ev.reason });
            };
            s.onmessage = (ev) => {
              if (typeof ev.data === 'string') ctl({ type: 'ws_event', id: m.id, ev: 'message', text: ev.data });
              else frame(m.id, ev.data);
            };
          } else if (m.cmd === 'ws_close') {
            const s = socks[m.id];
            if (s) { try { s.close(m.code || 1000, m.reason || ''); } catch (err) {} }
          } else if (m.cmd === 'ws_send_text') {
            const s = socks[m.id];
            if (s && s.readyState === 1) s.send(m.text);
          }
          return;
        }
        const u = new Uint8Array(e.data);
        const id = new TextDecoder().decode(u.subarray(1, 1 + u[0]));
        const s = socks[id];
        if (s && s.readyState === 1) s.send(u.subarray(1 + u[0]).slice().buffer);
      };
      return 'relay opening';
    })()
    """#

    /// Shape snapshot of the real `SteamClient` (namespace tree, 1 = method).
    static let shape = #"""
    JSON.stringify((function walk(o, d) {
      const out = {};
      for (const k of Object.keys(o)) {
        let v; try { v = o[k]; } catch (e) { continue; }
        if (typeof v === 'function') out[k] = 1;
        else if (v && typeof v === 'object' && d > 0) out[k] = walk(v, d - 1);
      }
      return out;
    })(SteamClient, 3))
    """#
}
