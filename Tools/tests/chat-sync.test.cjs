const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const swift = fs.readFileSync(path.join(__dirname, '../../Sevoflurane/Bridge/BridgeJS+ChatSync.swift'), 'utf8');
const code = swift.split('#"""\n')[1].split('\n    """#')[0];
const account = '76561198000000000', friendSteamID = '76561197960265770';
const response = (result = 1) => ({ GetEResult: () => result });
const request = (body) => ({ Body: () => Object.fromEntries(Object.entries(body).map(([k, v]) => [k, () => v])) });
function appFixture(owner = account) {
  const counts = { sessions: 0, history: 0, ranges: [], previews: 0, calls: 0 };
  const rows = [];
  const chat = {
    unique_id: 'f42', m_bChatLogsLoaded: true, chat_messages: rows, time_last_message: 100, time_last_ack: 100,
    self: { accountid: 1 },
    InternalLoadChatLogs: async () => { counts.history++; },
    GetMessagesFromTimeRange: async (...args) => { counts.ranges.push(args); return { messages: [{ time: args[0] + 1 }] }; },
    MergeChatHistoryChunk: (messages) => { rows.splice(0, rows.length, ...messages); },
    GetMostRecentChatMsg: () => null,
    CheckShouldNotify: () => { counts.previews++; },
    UpdateLastAckTimeFromServer: t => { chat.time_last_ack = Math.max(chat.time_last_ack, t); },
  };
  let next = Promise.resolve(response());
  const transport = {
    SendMsg: () => { counts.calls++; return next; },
    SendNotification: () => true,
  };
  const cm = {
    logged_on: true, steamid: { ConvertTo64BitString: () => owner }, GetServiceTransport: () => transport,
    DispatchMessage: p => { if (p.change) chat.time_last_message++; return 'original'; },
  };
  const store = {
    FriendChatStore: { GetAllChats: () => [chat], GetFriendChat: id => id === 42 ? chat : null,
      LoadFriendMessageSessions: () => { counts.sessions++; } },
    currentChatRoomGroups: [], FindChatRoom: (g, r) => g === '10' && r === '20' ? chat : null,
  };
  const context = vm.createContext({ window: {}, setTimeout });
  vm.runInContext(code, context);
  const app = { CMInterface: cm, ChatStore: store };
  const emitted = [];
  const sync = context.window.__sevoInstallChatSync(app, e => emitted.push(JSON.parse(JSON.stringify(e))));
  return { app, sync, emitted, counts, chat, cm, transport,
    setNext: p => { next = p; }, setOwner: id => { owner = id; },
    install: emit => context.window.__sevoInstallChatSync(app, emit) };
}
async function ready(f) { await f.sync.idle(); f.counts.history = f.counts.sessions = 0; }
const event = (kind, extra = {}) => ({ account, origin: 'other', kind, target: { friend: '42' }, ...extra });
const sendBody = { steamid: friendSteamID, chat_entry_type: 1, message: 'PRIVATE BODY NEVER RELAYED' };

test('successful send preserves its promise and emits only an invalidation', async () => {
  const f = appFixture(); await ready(f);
  const p = Promise.resolve(response()); f.setNext(p);
  assert.equal(f.transport.SendMsg('FriendMessages.SendMessage#1', request(sendBody)), p);
  await p; await Promise.resolve();
  assert.equal(f.emitted.length, 1); assert.equal(f.emitted[0].target.friend, '42');
  assert.equal(JSON.stringify(f.emitted).includes('PRIVATE'), false);
  assert.equal(f.sync.receive(f.emitted[0]), false);
});
test('failure, rejection, typing and read-only methods produce no invalidation', async () => {
  const f = appFixture(); await ready(f);
  f.setNext(Promise.resolve(response(2))); await f.transport.SendMsg('FriendMessages.SendMessage#1', request(sendBody));
  f.setNext(Promise.reject(new Error('original rejection')));
  await assert.rejects(f.transport.SendMsg('FriendMessages.SendMessage#1', request(sendBody)), /original rejection/);
  f.setNext(Promise.resolve(response()));
  await f.transport.SendMsg('FriendMessages.SendMessage#1', request({ ...sendBody, chat_entry_type: 2 }));
  await f.transport.SendMsg('FriendMessages.GetRecentMessages#1', request(sendBody));
  assert.equal(f.emitted.length, 0);
});
test('observer failure never prevents the original call', async () => {
  const f = appFixture(); await ready(f);
  await f.transport.SendMsg('FriendMessages.SendMessage#1', { Body() { throw Error('unknown body'); } });
  assert.equal(f.counts.calls, 1);
});
test('peer reads history through Steam and does not send or echo another message', async () => {
  const a = appFixture(), b = appFixture(); await ready(a); await ready(b);
  a.install(e => b.sync.receive(e)); b.install(e => a.sync.receive(e));
  await a.transport.SendMsg('FriendMessages.SendMessage#1', request(sendBody)); await b.sync.idle();
  assert.equal(a.counts.calls, 1); assert.equal(b.counts.calls, 0);
  assert.equal(b.counts.history, 1); assert.equal(b.sync.stats.emitted, 0);
});
test('read acknowledgements are monotonic and do not trigger a network write', async () => {
  const f = appFixture(); await ready(f);
  f.sync.receive(event('read', { ack: 200 })); f.sync.receive(event('read', { ack: 150 })); await f.sync.idle();
  assert.equal(f.chat.time_last_ack, 200); assert.equal(f.counts.history, 0); assert.equal(f.counts.sessions, 0);
  assert.equal(f.counts.calls, 0); assert.equal(f.emitted.length, 0);
});
test('local friend and group read actions identify the correct chat', async () => {
  const f = appFixture(); await ready(f);
  f.transport.SendNotification('FriendMessages.AckMessage#1', request({ steamid_partner: friendSteamID, timestamp: 500 }));
  f.transport.SendNotification('ChatRoom.AckChatMessage#1', request({ chat_group_id: '10', chat_id: '20', timestamp: 600 }));
  assert.equal(f.emitted[0].ack, 500); assert.equal(f.emitted[1].target.room, '20');
});
test('reaction and deletion refresh older rows, including changes outside the recent tail', async () => {
  const f = appFixture(); await ready(f);
  f.sync.receive(event('history', { times: [5] })); await f.sync.idle();
  assert.equal(f.counts.ranges[0][0], 4); assert.equal(f.counts.ranges[0][2], 6);
  assert.equal(f.counts.history, 0); assert.equal(f.chat.chat_messages[0].time, 5);
});
test('group send, reaction and deletion requests retain room IDs and affected timestamps', async () => {
  const f = appFixture(); await ready(f);
  await f.transport.SendMsg('ChatRoom.SendChatMessage#1', request({ chat_group_id: '10', chat_id: '20' }));
  await f.transport.SendMsg('ChatRoom.UpdateMessageReaction#1', request({ chat_group_id: '10', chat_id: '20', server_timestamp: 50 }));
  await f.transport.SendMsg('ChatRoom.DeleteChatMessages#1', request({ chat_group_id: '10', chat_id: '20', messages: [request({ server_timestamp: 40 }).Body()] }));
  assert.equal(f.emitted.length, 3); assert.equal(f.emitted[0].target.group, '10');
  assert.equal(f.emitted[1].times[0], 50); assert.equal(f.emitted[2].times[0], 40);
});
test('burst merging retains both new-message tail and older reaction updates', async () => {
  const f = appFixture(); await ready(f);
  f.sync.receive(event('history')); f.sync.receive(event('history', { times: [5] }));
  f.sync.receive(event('history', { times: [6, 5] })); await f.sync.idle();
  assert.equal(f.counts.history, 1); assert.equal(f.counts.ranges.length, 2);
});
test('initial/reconnect reconciliation catches missed events without loading unopened chats', async () => {
  const f = appFixture(); await ready(f); f.chat.m_bChatLogsLoaded = false;
  f.sync.reconcile(); await f.sync.idle();
  assert.equal(f.counts.sessions, 1); assert.equal(f.counts.history, 0);
});
test('wrong account, own-origin, malformed events and stale send completion are ignored', async () => {
  const f = appFixture(); await ready(f);
  assert.equal(f.sync.receive(event('history', { account: 'other' })), false);
  assert.equal(f.sync.receive(event('read', { ack: -1 })), false);
  assert.equal(f.sync.receive(event('history', { target: { friend: '../bad' } })), false);
  let settle; const p = new Promise(r => settle = r); f.setNext(p);
  f.transport.SendMsg('FriendMessages.SendMessage#1', request(sendBody)); f.setOwner('changed'); settle(response()); await p;
  assert.equal(f.emitted.length, 0);
});
test('incoming chat changes notify peers; typing/no-change packets do not', async () => {
  const f = appFixture(); await ready(f);
  const packet = change => ({ change, Hdr: () => ({ target_job_name: () => 'FriendMessagesClient.IncomingMessage#1' }) });
  assert.equal(f.cm.DispatchMessage(packet(false)), 'original'); assert.equal(f.emitted.length, 0);
  f.cm.DispatchMessage(packet(true)); assert.equal(f.emitted.length, 1);
});
test('self-message preview uses the original helper; another sender is not re-notified', async () => {
  const f = appFixture(); await ready(f);
  f.chat.GetMostRecentChatMsg = () => ({ unAccountID: 2, rtTimestamp: 200, strMessage: 'not relayed' });
  f.sync.receive(event('history')); await f.sync.idle(); assert.equal(f.counts.previews, 0);
  f.chat.GetMostRecentChatMsg = () => ({ unAccountID: 1, rtTimestamp: 200, strMessage: 'not relayed' });
  f.sync.receive(event('history')); await f.sync.idle(); assert.equal(f.counts.previews, 1);
});
test('reinstallation does not stack wrappers and disposal restores the original transport', async () => {
  const f = appFixture(); await ready(f); const wrapped = f.transport.SendMsg;
  assert.equal(f.install(() => {}), f.sync); assert.equal(f.transport.SendMsg, wrapped);
  f.sync.dispose(); assert.notEqual(f.transport.SendMsg, wrapped);
  assert.equal(f.sync.receive(event('history')), false);
});

test('queued events from a previous account do not merge into the new account', async () => {
  const f = appFixture(); await ready(f);
  f.sync.receive(event('read', { ack: 900 }));
  f.setOwner('76561198000000001');
  f.sync.receive(event('read', { account: '76561198000000001', ack: 200 }));
  await f.sync.idle(); assert.equal(f.chat.time_last_ack, 200);
});
