import Foundation

extension BridgeJS {
    /// Notify the other renderer that authoritative Steam chat data changed.
    /// Both sides use the original Steam history/session/read helpers.
    static let chatSync = #"""
    // Local invalidations only. Steam remains responsible for messages, history
    // ordering, reactions, deletion state, unread counts and all network writes.
    window.__sevoInstallChatSync = function (app, emit) {
      var cm = app && app.CMInterface, store = app && app.ChatStore;
      var transport = cm && cm.GetServiceTransport && cm.GetServiceTransport();
      if (!store || !transport || typeof transport.SendMsg !== 'function') return null;
      var previous = app.__sevoChatSync;
      if (previous && previous.transport === transport) { previous.emit = emit; return previous; }
      if (previous) previous.dispose();
      var origin = String(Date.now()) + ':' + Math.random(), disposed = false;
      var pending = new Map(), scheduled = false, running = false;
      var restore = [], stats = { emitted: 0, reconciled: 0, failed: 0 };
      function account() {
        return cm.logged_on && cm.steamid && cm.steamid.ConvertTo64BitString
          ? cm.steamid.ConvertTo64BitString() : '';
      }
      function chats() {
        var result = store.FriendChatStore.GetAllChats().slice();
        for (var group of store.currentChatRoomGroups || [])
          for (var room of group.chatRoomList || []) result.push(room);
        return result;
      }
      function snapshot() {
        return chats().map(function (c) {
          return [c.unique_id, c.time_last_message, c.time_last_ack, c.chat_messages.length].join(':');
        }).join('|');
      }
      function value(body, field) { return body && typeof body[field] === 'function' ? body[field]() : undefined; }
      function target(body, group) {
        if (group) {
          var g = value(body, 'chat_group_id'), r = value(body, 'chat_id');
          return g && r ? { group: String(g), room: String(r) } : null;
        }
        var id = value(body, 'steamid') || value(body, 'steamid_partner');
        try { return id ? { friend: String(BigInt(id) & 0xffffffffn) } : null; }
        catch (_) { return null; }
      }
      function describe(method, request) {
        try { return describeRequest(method, request); } catch (_) { stats.failed++; return null; }
      }
      function describeRequest(method, request) {
        var body = request && request.Body && request.Body(), group = method.startsWith('ChatRoom.');
        var outgoing = method === 'FriendMessages.SendMessage#1' || method === 'ChatRoom.SendChatMessage#1';
        var reaction = method === 'FriendMessages.UpdateMessageReaction#1' || method === 'ChatRoom.UpdateMessageReaction#1';
        var deletion = method === 'ChatRoom.DeleteChatMessages#1';
        var read = method === 'FriendMessages.AckMessage#1' || method === 'ChatRoom.AckChatMessage#1';
        if (!outgoing && !reaction && !deletion && !read) return null;
        // FriendMessages.SendMessage also carries typing notices, not messages.
        if (outgoing && !group && value(body, 'chat_entry_type') !== 1) return null;
        var destination = target(body, group);
        if (!destination) return null;
        var event = { kind: read ? 'read' : 'history', target: destination };
        if (read) event.ack = value(body, 'timestamp');
        if (reaction) event.times = [value(body, 'server_timestamp')];
        if (deletion) event.times = (value(body, 'messages') || []).map(function (m) { return value(m, 'server_timestamp'); });
        return event;
      }
      function publish(event, owner) {
        if (!event || disposed || !owner || owner !== account()) return;
        event.account = owner; event.origin = origin;
        stats.emitted++;
        try { sync.emit(event); } catch (_) { stats.failed++; }
      }
      function wrap(object, name, wrapper) {
        var original = object[name];
        if (typeof original !== 'function') return;
        var replacement = wrapper(original), own = Object.prototype.hasOwnProperty.call(object, name);
        try { object[name] = replacement; } catch (_) { stats.failed++; return; }
        if (object[name] !== replacement) { stats.failed++; return; }
        restore.push(function () {
          if (object[name] !== replacement) return;
          if (own) object[name] = original; else delete object[name];
        });
      }
      wrap(transport, 'SendMsg', function (original) {
        return function (method, request) {
          var owner = account(), event = describe(String(method), request);
          var result = original.apply(this, arguments);
          if (event) Promise.resolve(result).then(function (response) {
            if (response && response.GetEResult() === 1) publish(event, owner);
          }, function () {}).catch(function () { stats.failed++; });
          // Preserve the exact promise/value and the original rejection path.
          return result;
        };
      });
      wrap(transport, 'SendNotification', function (original) {
        return function (method, request) {
          var owner = account(), event = describe(String(method), request);
          var result = original.apply(this, arguments);
          if (event && event.kind === 'read' && result === true) publish(event, owner);
          return result;
        };
      });
      wrap(cm, 'DispatchMessage', function (original) {
        return function (packet) {
          var method = packet && packet.Hdr && value(packet.Hdr(), 'target_job_name');
          var relevant = /^(FriendMessagesClient\.(IncomingMessage|NotifyAckMessageEcho|MessageReaction)|ChatRoomClient\.(NotifyIncomingChatMessage|NotifyChatMessageModified|NotifyMessageReaction|NotifyAckChatMessageEcho))#1$/.test(method || '');
          var owner = account(), before;
          if (relevant) { try { before = snapshot(); } catch (_) { relevant = false; stats.failed++; } }
          var result = original.apply(this, arguments);
          // Typing packets do not change chat metadata. Reactions/deletions can
          // change older rows without changing their timestamps or message count.
          if (relevant) {
            try { if (before !== snapshot() || /Reaction|Modified/.test(method)) publish({ kind: 'all' }, owner); }
            catch (_) { stats.failed++; }
          }
          return result;
        };
      });
      function valid(event) {
        if (!event || event.account !== account() || !event.account || event.origin === origin) return false;
        if (event.kind === 'all') return true;
        var t = event.target;
        if (!t || !(typeof t.friend === 'string' && /^\d{1,10}$/.test(t.friend)
            || typeof t.group === 'string' && /^\d{1,20}$/.test(t.group)
            && typeof t.room === 'string' && /^\d{1,20}$/.test(t.room))) return false;
        if (event.kind === 'read') return Number.isSafeInteger(event.ack) && event.ack >= 0;
        return event.kind === 'history' && (!event.times || Array.isArray(event.times)
          && event.times.every(function (t) { return Number.isSafeInteger(t) && t > 0; }));
      }
      function getChat(t) {
        return t.friend ? store.FriendChatStore.GetFriendChat(Number(t.friend), false)
          : store.FindChatRoom(t.group, t.room);
      }
      async function reconcile(event) {
        if (disposed || event.account !== account()) return;
        if (event.kind === 'read') {
          var readChat = getChat(event.target);
          if (readChat) readChat.UpdateLastAckTimeFromServer(event.ack);
          return;
        }
        // Steam's session loader updates recent-chat time and unread metadata.
        // Histories are merged by its original helpers, never copied from the
        // other renderer's model and never presented as a new incoming toast.
        store.FriendChatStore.LoadFriendMessageSessions();
        var list = event.kind === 'all' ? chats() : [getChat(event.target)].filter(Boolean);
        for (var chat of list) {
          if (!chat.m_bChatLogsLoaded || event.account !== account()) continue;
          if (event.times && event.times.length) {
            for (var time of new Set(event.times)) {
              var chunk = await chat.GetMessagesFromTimeRange(Math.max(0, time - 1), 0, time + 1, 0, 100);
              if (disposed || event.account !== account()) return;
              chat.MergeChatHistoryChunk(chunk.messages);
            }
          }
          if (!event.times || event.tail) await chat.InternalLoadChatLogs(true);
          // Steam's own local-echo path refreshes previews and clears self-message
          // unread state. Reuse that helper only for the user's own last message;
          // replaying another sender here could repeat their toast/sound.
          var last = chat.GetMostRecentChatMsg && chat.GetMostRecentChatMsg();
          if (last && chat.self && last.unAccountID === chat.self.accountid
              && last.rtTimestamp >= (chat.time_last_message || 0)
              && typeof chat.CheckShouldNotify === 'function')
            chat.CheckShouldNotify(last, last.strMessage, last.strMessage);
        }
        stats.reconciled++;
      }
      function enqueue(event) {
        var key = event.account + ':' + event.kind + ':' + (event.target ? JSON.stringify(event.target) : '*');
        var old = pending.get(key);
        if (old && event.kind === 'history') {
          event.tail = old.tail || event.tail || !old.times || !event.times;
          var times = Array.from(new Set((old.times || []).concat(event.times || [])));
          if (times.length) event.times = times;
        }
        if (old && event.kind === 'read') event.ack = Math.max(old.ack, event.ack);
        pending.set(key, event);
        if (!scheduled && !running) {
          scheduled = true;
          Promise.resolve().then(drain);
        }
      }
      async function drain() {
        scheduled = false; running = true;
        try {
          while (pending.size && !disposed) {
            var entry = pending.entries().next().value;
            pending.delete(entry[0]);
            try { await reconcile(entry[1]); } catch (_) { stats.failed++; }
          }
        } finally { running = false; }
      }
      var sync = {
        transport: transport, emit: emit, stats: stats,
        receive: function (event) {
          if (disposed || !valid(event)) return false;
          enqueue(Object.assign({}, event)); return true;
        },
        reconcile: function () {
          if (account()) enqueue({ kind: 'all', account: account() });
        },
        idle: async function () {
          while (scheduled || running) await new Promise(function (resolve) { setTimeout(resolve, 0); });
        },
        dispose: function () { disposed = true; pending.clear(); restore.forEach(function (f) { f(); }); }
      };
      app.__sevoChatSync = sync;
      sync.reconcile();
      return sync;
    };
    """#

    static var installChatSync: String {
        """
        \(chatSync)
        window.__sevoInstallChatSync(window.g_FriendsUIApp, function (event) {
          window.__sevo(JSON.stringify({type: 'chat_changed', event: event}));
        });
        """
    }
}
