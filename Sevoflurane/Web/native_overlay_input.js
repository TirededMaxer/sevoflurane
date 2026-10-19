/* The original game window keeps OS focus and Steam's overlay hotkey. Only
 * events delivered to this original CEF document are passed to its WK twin. */
(function () {
  if (window.__sevoOverlayInput) { window.__sevoOverlayInput.ping = Date.now(); return "ready"; }
  var state = {ping: Date.now(), enabled:false}, listeners = [], frame = 0, tick = 0;
  var proxy = document.createElement("textarea");
  proxy.style.cssText = "position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none";
  proxy.setAttribute("aria-hidden", "true"); document.body.appendChild(proxy);
  var clock = document.createElement("canvas"); clock.width = clock.height = 1;
  clock.style.cssText = "position:fixed;right:0;bottom:0;width:1px;height:1px;pointer-events:none";
  document.body.appendChild(clock); var context = clock.getContext("2d");
  function paint() {
    if (Date.now() - state.ping > 2000) { stop(); return; }
    context.fillStyle = (++tick & 1) ? "#000001" : "#000002"; context.fillRect(0, 0, 1, 1);
    frame = requestAnimationFrame(paint);
  }
  function send(e) {
    if (!state.enabled) return;
    if (e.key === "Tab" && e.shiftKey) return; // Steam owns the opening/closing chord.
    if (e.type === "keydown" && (e.isComposing || e.key === "Process")) return;
    var kind = {pointerdown:"mousedown",pointerup:"mouseup",pointermove:"mousemove"}[e.type] || e.type;
    __sevo(JSON.stringify({type:"overlay-input",event:kind,x:e.clientX||0,y:e.clientY||0,
      button:e.button||0,buttons:e.buttons||0,clicks:e.detail||1,dx:e.deltaX||0,dy:e.deltaY||0,
      key:e.key||"",code:e.code||"",text:e.data||"",repeat:!!e.repeat,
      shift:!!e.shiftKey,ctrl:!!e.ctrlKey,alt:!!e.altKey,meta:!!e.metaKey}));
    if (kind === "mousedown") proxy.focus({preventScroll:true});
    if (!/^composition/.test(e.type)) { e.preventDefault(); e.stopImmediatePropagation(); }
    if (e.type === "compositionend") proxy.value = "";
  }
  function listen(name) { window.addEventListener(name,send,{capture:true,passive:false}); listeners.push(name); }
  ["pointerdown","pointerup","pointermove","wheel","keydown","keyup","compositionstart","compositionupdate","compositionend"].forEach(listen);
  function suppress(e) { if (state.enabled) { e.preventDefault(); e.stopImmediatePropagation(); } }
  var suppressed = ["mousedown","mouseup","mousemove","click","dblclick","contextmenu"];
  suppressed.forEach(function (n) { window.addEventListener(n,suppress,true); });
  function stop() {
    cancelAnimationFrame(frame); clearInterval(watchdog);
    listeners.forEach(function (n) { window.removeEventListener(n,send,true); });
    suppressed.forEach(function (n) { window.removeEventListener(n,suppress,true); });
    proxy.remove(); clock.remove(); delete window.__sevoOverlayInput;
  }
  state.stop = stop; window.__sevoOverlayInput = state;
  var watchdog = setInterval(function () { if (Date.now()-state.ping>2000) stop(); },500);
  paint(); return "ready";
})()
