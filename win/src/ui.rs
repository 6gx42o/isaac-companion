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

/* ---- tabs ---- */
.tabs{display:flex;gap:2px;border-bottom:1px solid var(--rule);margin:0 0 24px;flex-wrap:wrap}
.tab{background:none;border:0;border-bottom:2px solid transparent;color:var(--faint);
  font-family:var(--mono);font-size:10px;letter-spacing:.16em;text-transform:uppercase;
  padding:10px 13px;cursor:pointer;transition:color .15s,border-color .15s}
.tab:hover{color:var(--dim)}
.tab.on{color:var(--ash);border-bottom-color:var(--mark)}
.page{display:none}
.page.on{display:block}
.search{width:100%;background:var(--panel);border:1px solid var(--rule2);color:var(--ash);
  padding:10px 13px;border-radius:2px;font:inherit;font-size:14px;margin:0 0 16px}
.search:focus{outline:none;border-color:var(--hot)}
.rows{display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule)}
.row{background:var(--panel);padding:8px 12px;display:flex;align-items:center;gap:11px}
.row .spr{width:32px;height:32px;flex:0 0 32px;image-rendering:pixelated;
  background:var(--panel2);border:1px solid var(--rule)}
.row .body{min-width:0;flex:1}
.row .n{font-family:var(--serif);font-size:14.5px;display:block}
.row .m{font-family:var(--mono);font-size:9.5px;color:var(--faint);letter-spacing:.08em;
  text-transform:uppercase}
.row .hp{font-family:var(--mono);font-size:12px;color:var(--dim);
  font-variant-numeric:tabular-nums;flex:0 0 auto}
.row .cond{color:var(--dim);font-size:12.5px;display:block}
.pill{font-family:var(--mono);font-size:8.5px;letter-spacing:.12em;text-transform:uppercase;
  border:1px solid var(--rule2);border-radius:2px;padding:2px 5px;color:var(--dim)}
.pill.boss{color:var(--mark);border-color:var(--mark)}
.pill.special{color:var(--warn);border-color:var(--warn)}
.count{font-family:var(--mono);font-size:10px;color:var(--faint);margin:0 0 12px}
.setrow{display:flex;justify-content:space-between;align-items:center;gap:16px;
  padding:13px 0;border-top:1px solid var(--rule)}
.setrow:first-of-type{border-top:0}
.setrow .lab{font-size:14px}
.setrow .d{color:var(--dim);font-size:12.5px;margin:3px 0 0}
.setrow select,.setrow input[type=number]{background:var(--panel);border:1px solid var(--rule2);
  color:var(--ash);padding:6px 9px;border-radius:2px;font:inherit;font-size:13px}
</style>
<div class="wrap">
  <div class="tabs">
    <button class="tab on" data-page="run">Run</button>
    <button class="tab" data-page="items">Items</button>
    <button class="tab" data-page="enemies">Enemies</button>
    <button class="tab" data-page="unlocks">Unlocks</button>
    <button class="tab" data-page="settings">Settings</button>
  </div>

  <section class="page on" id="page-run">
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
  </section>

  <section class="page" id="page-items">
    <input class="search" id="q-items" placeholder="Search 775 items, cards, pills and trinkets">
    <p class="count" id="c-items"></p>
    <div class="rows" id="r-items"></div>
  </section>

  <section class="page" id="page-enemies">
    <input class="search" id="q-enemies" placeholder="Search enemies and bosses">
    <p class="count" id="c-enemies"></p>
    <div class="rows" id="r-enemies"></div>
  </section>

  <section class="page" id="page-unlocks">
    <input class="search" id="q-unlocks" placeholder="Search achievements by name or unlock condition">
    <p class="count" id="c-unlocks"></p>
    <div class="rows" id="r-unlocks"></div>
  </section>

  <section class="page" id="page-settings">
    <h2 style="margin-top:0">Settings</h2>
    <div class="setrow">
      <div><div class="lab">Refresh rate</div>
        <p class="d">How often the readout asks for new numbers. Lower is snappier,
          higher is kinder to a laptop battery.</p></div>
      <select id="s-poll">
        <option value="250">4 a second</option>
        <option value="500" selected>2 a second</option>
        <option value="1000">Once a second</option>
        <option value="3000">Every 3 seconds</option>
      </select>
    </div>
    <div class="setrow">
      <div><div class="lab">Sprites</div>
        <p class="d" id="d-art"></p></div>
      <select id="s-art">
        <option value="1" selected>Show</option>
        <option value="0">Hide</option>
      </select>
    </div>
    <div class="setrow">
      <div><div class="lab">Search results</div>
        <p class="d">How many rows a search shows before it stops. The server caps this
          at 300 whatever you put here.</p></div>
      <input type="number" id="s-limit" min="10" max="300" step="10" value="150">
    </div>
    <p class="note" id="s-where"></p>
  </section>
</div>
<script>
// Declared up here because poll() runs immediately, below, and the settings
// block that changes this sits further down the file.
var pollMs = +(localStorage.getItem("poll") || 500);
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
  timer = setTimeout(poll, pollMs);
}
// Come back immediately on return rather than waiting out the current timer.
document.addEventListener("visibilitychange", ()=>{ if(!document.hidden){ clearTimeout(timer); poll(); } });
poll();

/* ---- tabs ------------------------------------------------------------------
   The browse pages fetch on first open and on every keystroke, debounced. They are
   NOT part of the poll loop: the catalogue is baked into the binary and never
   changes while it runs, so re-fetching it twice a second would be pure waste. */
const S = {
  art: localStorage.getItem("art") !== "0",
  limit: +(localStorage.getItem("limit") || 150),
};
let artOK = false;

const esc = (t) => String(t ?? "").replace(/[&<>"']/g, (c) =>
  ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

function el(tag, cls, text){
  const n = document.createElement(tag);
  if(cls) n.className = cls;
  if(text != null) n.textContent = text;
  return n;
}

function itemRow(it){
  const row = el("div","row");
  if(S.art && artOK && it.gfx){
    const img = el("img","spr");
    img.src = "/sprite/" + encodeURIComponent(it.gfx);
    img.alt = "";
    img.loading = "lazy";
    // No art for this one: drop the box rather than leave a broken image.
    img.onerror = () => img.remove();
    row.appendChild(img);
  }
  const body = el("div","body");
  body.appendChild(el("span","n",it.name));
  const meta = el("span","m");
  meta.textContent = "#" + it.id + "  ·  " + it.kind
    + (it.pools.length ? "  ·  " + it.pools.join(", ") : "");
  body.appendChild(meta);
  row.appendChild(body);
  if(it.special) row.appendChild(el("span","pill special","special"));
  return row;
}

function enemyRow(e){
  const row = el("div","row");
  const body = el("div","body");
  body.appendChild(el("span","n",e.name));
  body.appendChild(el("span","m","type " + e.type + "." + e.variant));
  row.appendChild(body);
  if(e.boss) row.appendChild(el("span","pill boss","boss"));
  if(e.hp != null && e.hp > 0) row.appendChild(el("span","hp", e.hp + " hp"));
  return row;
}

function achRow(a){
  const row = el("div","row");
  const body = el("div","body");
  body.appendChild(el("span","n",a.name));
  if(a.condition) body.appendChild(el("span","cond",a.condition));
  row.appendChild(body);
  return row;
}

const PAGES = {
  items:   { url:"/api/items",        key:"items",        row:itemRow,  noun:"items" },
  enemies: { url:"/api/enemies",      key:"enemies",      row:enemyRow, noun:"enemies" },
  unlocks: { url:"/api/achievements", key:"achievements", row:achRow,   noun:"achievements" },
};

async function load(name){
  const cfg = PAGES[name];
  const q = document.getElementById("q-" + name).value;
  try {
    const r = await fetch(cfg.url + "?q=" + encodeURIComponent(q));
    const d = await r.json();
    if(typeof d.art === "boolean") { artOK = d.art; paintArtNote(); }
    const rows = (d[cfg.key] || []).slice(0, S.limit);
    const host = document.getElementById("r-" + name);
    host.replaceChildren(...rows.map(cfg.row));
    document.getElementById("c-" + name).textContent =
      q.trim()
        ? rows.length + " of " + d.total + " " + cfg.noun + " match \u201c" + q.trim() + "\u201d"
        : "showing " + rows.length + " of " + d.total + " " + cfg.noun;
  } catch (e) {
    document.getElementById("c-" + name).textContent = "could not load: " + e;
  }
}

function paintArtNote(){
  const d = document.getElementById("d-art");
  const w = document.getElementById("s-where");
  if(!d) return;
  d.textContent = artOK
    ? "Item art, read from your own copy of the game. Nothing is downloaded and no art ships with this program."
    : "No art found. Run the game's own tools\\ResourceExtractor.exe once and it will appear \u2014 the sprites are Nicalis's, so they cannot ship inside this download.";
  if(w) w.textContent = artOK ? "" : "Looked in the usual Steam folders for resources/gfx/items/collectibles.";
}

let debounce;
for(const name of Object.keys(PAGES)){
  const box = document.getElementById("q-" + name);
  box.addEventListener("input", ()=>{ clearTimeout(debounce); debounce = setTimeout(()=>load(name), 120); });
}

const loaded = new Set();
document.querySelectorAll(".tab").forEach((t)=>{
  t.onclick = ()=>{
    document.querySelectorAll(".tab").forEach((x)=>x.classList.toggle("on", x===t));
    const page = t.dataset.page;
    document.querySelectorAll(".page").forEach((p)=>
      p.classList.toggle("on", p.id === "page-" + page));
    if(PAGES[page] && !loaded.has(page)){ loaded.add(page); load(page); }
  };
});

/* Deep link: ?tab=items&q=brimstone opens a tab with a search already run. Handy for a
   bookmark, and it is the only way to drive this page from a headless browser, which is
   how the browse tabs get tested at all. */
{
  const params = new URLSearchParams(location.search);
  const tab = params.get("tab");
  if(tab && document.querySelector('.tab[data-page="' + tab + '"]')){
    const box = document.getElementById("q-" + tab);
    if(box && params.get("q")) box.value = params.get("q");
    document.querySelector('.tab[data-page="' + tab + '"]').click();
  }
}

/* ---- settings ---- */
{
  const pollSel = document.getElementById("s-poll");
  pollSel.value = String(pollMs);
  pollSel.onchange = ()=>{
    pollMs = +pollSel.value;
    localStorage.setItem("poll", pollSel.value);
    // Apply immediately rather than after the current interval expires.
    clearTimeout(timer);
    poll();
  };
  const art = document.getElementById("s-art");
  art.value = S.art ? "1" : "0";
  art.onchange = ()=>{ S.art = art.value === "1"; localStorage.setItem("art", art.value);
    loaded.forEach((p)=>load(p)); };
  const lim = document.getElementById("s-limit");
  lim.value = String(S.limit);
  lim.onchange = ()=>{ S.limit = Math.max(10, Math.min(300, +lim.value || 150));
    lim.value = String(S.limit); localStorage.setItem("limit", String(S.limit));
    loaded.forEach((p)=>load(p)); };
  paintArtNote();
}
</script>
"##;
