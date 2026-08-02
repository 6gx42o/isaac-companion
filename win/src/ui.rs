//! The readout, served from the binary.
//!
//! Same palette and typographic vocabulary as the macOS app and the site, so it reads
//! as the same product rather than a port someone bolted on. Deliberately one small
//! page: it polls a JSON endpoint and redraws, which is all a live stat readout needs
//! and it keeps the .exe a couple of megabytes rather than shipping a browser engine.

pub const PAGE: &str = r##"<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Isaac Companion</title>
<style>
:root{
  --void:#080405;--panel:#150b0e;--panel2:#1b0f13;--rule:#331a1f;--rule2:#4a2229;
  --ash:#e8d9c6;--dim:#9a7f75;--faint:#6b5450;
  --mark:#b81f22;--hot:#e2542b;--warn:#d9a441;--good:#7e9c46;
  --mono:ui-monospace,"Cascadia Mono","SF Mono",Consolas,monospace;
  --serif:ui-serif,Georgia,"Times New Roman",serif;
  --sans:-apple-system,"Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--void);color:var(--ash);font-family:var(--sans);
  font-size:15px;line-height:1.6;-webkit-font-smoothing:antialiased}
body::before{content:"";position:fixed;inset:0;pointer-events:none;z-index:0;
  background:radial-gradient(58% 34% at 50% -8%,rgba(184,31,34,.17),transparent 70%)}
.wrap{max-width:760px;margin:0 auto;padding:34px 22px 60px;position:relative;z-index:1}
h1{font-family:var(--serif);font-size:34px;margin:0;letter-spacing:-.02em}
.sub{font-family:var(--mono);font-size:10px;letter-spacing:.18em;text-transform:uppercase;
  color:var(--faint);margin:6px 0 0}
.badge{display:inline-flex;align-items:center;gap:7px;font-family:var(--mono);font-size:10px;
  letter-spacing:.14em;text-transform:uppercase;color:var(--dim);
  border:1px solid var(--rule2);border-radius:2px;padding:5px 10px}
.badge i{width:6px;height:6px;border-radius:50%;background:var(--warn);display:block}
.badge.live i{background:var(--good)}
.badge.off i{background:var(--mark)}
.top{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap}
.tags{display:flex;flex-wrap:wrap;gap:6px;margin:14px 0 0}
.tag{font-family:var(--mono);font-size:9px;letter-spacing:.14em;text-transform:uppercase;
  padding:3px 7px;border:1px solid var(--rule2);border-radius:2px;color:var(--warn)}
.tag.curse{color:var(--mark);border-color:var(--mark)}
.tag.flight{color:var(--good);border-color:var(--good)}
.stats{display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule);margin:22px 0 0;
  grid-template-columns:repeat(auto-fit,minmax(118px,1fr))}
.cell{background:var(--panel);padding:12px 13px 14px}
.cell .k{font-family:var(--mono);font-size:8.5px;letter-spacing:.2em;text-transform:uppercase;
  color:var(--faint)}
.cell .v{font-family:var(--mono);font-size:23px;margin-top:4px;font-variant-numeric:tabular-nums}
.cell.hot .v{color:var(--hot)}
.cell.approx .v{color:var(--warn)}
.cell .b{font-family:var(--mono);font-size:9px;color:var(--faint);margin-top:2px}
h2{font-family:var(--mono);font-size:10px;letter-spacing:.2em;text-transform:uppercase;
  color:var(--mark);margin:30px 0 10px;font-weight:400}
.items{display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule)}
.it{background:var(--panel);padding:8px 12px;display:flex;justify-content:space-between;gap:12px}
.it .n{font-family:var(--serif);font-size:14.5px}
.it .i{font-family:var(--mono);font-size:10px;color:var(--faint)}
.empty{color:var(--dim);font-size:13px;padding:14px 0}
.note{color:var(--dim);font-size:12.5px;border-left:2px solid var(--rule2);padding:2px 0 2px 12px;
  margin:18px 0 0}
.warn{color:var(--warn)}
code{font-family:var(--mono);font-size:12px;color:var(--ash)}
</style>
<div class="wrap">
  <div class="top">
    <div>
      <h1 id="char">—</h1>
      <p class="sub"><span id="seed">no run yet</span> <span id="floor"></span></p>
    </div>
    <span class="badge" id="badge"><i></i><span id="badgetext">starting</span></span>
  </div>
  <div class="tags" id="tags"></div>
  <div class="stats" id="stats"></div>
  <p class="note" id="note"></p>
  <h2>Items <span id="count"></span></h2>
  <div class="items" id="items"></div>
  <div class="empty" id="none">Nothing picked up yet.</div>
</div>
<script>
const ROWS = [
  ["damage","Damage",true],["tears","Tears",false],["tearDelay","Tear delay",false],
  ["range","Range",false],["shotSpeed","Shot speed",false],["speed","Speed",false],
  ["luck","Luck",false],
];
const $ = id => document.getElementById(id);
let lastSig = "";
let timer = 0;

function draw(s){
  $("char").textContent = s.character || "—";
  $("seed").textContent = s.seed || "no run yet";
  $("floor").textContent = s.stage ? "· floor " + s.stage : "";

  // Four states, not three. "live" has to mean the game is actually open: log.txt is
  // only rewritten on LAUNCH and nothing is appended on exit, so yesterday's file
  // reads exactly like a session in progress. Saying "live" over a closed game is the
  // readout lying about the most important thing on it.
  const b = $("badge");
  if(!s.log){ b.className = "badge off"; $("badgetext").textContent = "no log found"; }
  else if(!s.gameRunning){ b.className = "badge off"; $("badgetext").textContent = "game closed"; }
  else if(!s.seed){ b.className = "badge"; $("badgetext").textContent = "waiting for a run"; }
  else { b.className = "badge live"; $("badgetext").textContent = "live"; }

  const tags = [];
  for(const c of s.curses || []) tags.push(['curse', c]);
  if(s.flight) tags.push(['flight','flight']);
  if(s.shots > 1) tags.push(['', s.shots + ' shots']);
  if(s.pedestals) tags.push(['', s.pedestals + ' pedestal' + (s.pedestals>1?'s':'')]);
  $("tags").innerHTML = tags.map(([c,t])=>
    `<span class="tag ${c}">${t}</span>`).join("");

  $("stats").innerHTML = ROWS.map(([k,label,hot])=>{
    const st = s[k]; if(!st) return "";
    const cls = "cell" + (st.approx ? " approx" : hot ? " hot" : "");
    const moved = Math.abs(st.value - st.base) > 0.005;
    return `<div class="${cls}" title="${st.reason||''}">
      <div class="k">${label}</div>
      <div class="v">${st.approx?"~":""}${st.value.toFixed(2)}</div>
      <div class="b">${moved ? "base " + st.base.toFixed(2) : "&nbsp;"}</div></div>`;
  }).join("");

  const notes = [];
  if(!s.log) notes.push("No log.txt found. Launch the game once, then restart this — "
    + "or pass the path to it as an argument.");
  else if(!s.gameRunning && s.seed) notes.push("The game is not running. These are the "
    + "numbers from the last session, not a live run.");
  if((s.unverified||[]).length) notes.push(
    "<span class='warn'>Unverified for this character: " + s.unverified.join(", ") + "</span>");
  notes.push("The log never reports trinkets, cards or pills, so those are not counted here.");
  $("note").innerHTML = notes.join("<br>");

  const items = s.items || [];
  $("count").textContent = items.length ? "(" + items.length + ")" : "";
  $("none").style.display = items.length ? "none" : "block";
  $("items").innerHTML = items.slice().reverse().map(i=>
    `<div class="it"><span class="n"></span><span class="i">#${i.id}</span></div>`).join("");
  // textContent for the name so an item name can never be markup.
  const names = items.slice().reverse().map(i=>i.name);
  document.querySelectorAll("#items .n").forEach((el,n)=> el.textContent = names[n]);
}

async function poll(){
  // Nothing to look at while the tab is hidden, so do not ask. Browsers throttle
  // background timers anyway; skipping the request outright means the app is
  // genuinely idle rather than merely slowed down.
  // Always fetch the FIRST time, whatever the visibility says. A tab that opens in
  // the background -- which is exactly what happens when the browser is already open
  // on another tab -- would otherwise sit on the empty starting state until it was
  // looked at, and an empty readout is indistinguishable from a broken one.
  if(!document.hidden || lastSig === ""){
    try{
      const r = await fetch("/api/state", {cache:"no-store"});
      const text = await r.text();
      // Compare the raw body: the server hands back a byte-identical string while
      // nothing changes, so this skips both the parse and the redraw.
      if(text !== lastSig){ lastSig = text; draw(JSON.parse(text)); }
    }catch(e){ /* the server went away; keep trying */ }
  }
  // One timer, always replaced, never accumulated. Calling poll() straight from the
  // visibility handler started a SECOND chain every time the tab came back, so a few
  // tab switches left several loops running at once -- the opposite of the point.
  clearTimeout(timer);
  timer = setTimeout(poll, 500);
}
// Come back immediately on return rather than waiting out the current timer.
document.addEventListener("visibilitychange", ()=>{ if(!document.hidden){ clearTimeout(timer); poll(); } });
poll();
</script>
"##;
