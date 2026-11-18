const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

const shim = readFileSync(join(__dirname, '../../Sevoflurane/Bridge/steamclient_shim.js'), 'utf8')
  .replace('%STEAM_HOSTS%', '[]').replace('%PAGE_PORT%', '8761');

function browserWindow() {
  const timers = new Map();
  let next = 0;
  let now = 0;
  return {
    timers,
    performance: { now: () => now },
    setTimeout(callback) { timers.set(++next, callback); return next; },
    clearTimeout(handle) { timers.delete(handle); },
    advance(ms) { now += ms; },
    addEventListener() {},
    postMessage() {},
  };
}

test('the shim provides cancellable callbacks in both the root and its native popups', () => {
  const root = browserWindow();
  const popup = browserWindow();
  const native = browserWindow();
  const nativeRequest = () => 10;
  const nativeCancel = () => {};
  native.requestIdleCallback = nativeRequest;
  native.cancelIdleCallback = nativeCancel;
  for (const child of [popup, native]) {
    child.webkit = { messageHandlers: { sevoWindow: { postMessage() {} } } };
  }
  root.open = (_url, name) => name === 'native' ? native : popup;
  root.XMLHttpRequest = class {};
  root.WebSocket = class {};
  root.window = root;
  vm.runInNewContext(shim, root);
  assert.equal(root.open('about:blank', 'test'), popup);
  assert.equal(root.open('about:blank', 'native'), native);
  assert.equal(native.requestIdleCallback, nativeRequest);
  assert.equal(native.cancelIdleCallback, nativeCancel);

  for (const window of [root, popup]) {
    let deadline;
    const canceled = window.requestIdleCallback(() => assert.fail('canceled callback ran'));
    window.cancelIdleCallback(canceled);
    assert.equal(window.timers.has(canceled), false);
    const handle = window.requestIdleCallback(value => { deadline = value; }, { timeout: 1000 });
    assert.equal(deadline, undefined);
    window.advance(1000);
    window.timers.get(handle)();
    assert.equal(deadline.didTimeout, true);
    assert.equal(deadline.timeRemaining(), 0);
    const idle = window.requestIdleCallback(value => { deadline = value; });
    window.timers.get(idle)();
    assert.equal(deadline.didTimeout, false);
    assert.ok(deadline.timeRemaining() > 0);
    window.advance(10);
    assert.equal(deadline.timeRemaining(), 0);
  }
});
