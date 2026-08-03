// UI layer. All data is pushed in from Swift via window.onAtlas / window.onCatalogue /
// window.onState; nothing here touches the network.

const send = (msg) => window.webkit?.messageHandlers?.app?.postMessage(msg);
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

// For the few places that build markup rather than set textContent. Most of this file
// uses el(tag, cls, text), which escapes for free; the update panel does not, because it
// needs a button inside the sentence -- and the version strings and error messages it
// interpolates come off the network.
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

let catalogue = [];
let byKey = new Map();
let atlas = null;

// ---- sprites -------------------------------------------------------------
// One sheet, positioned with CSS. `image-rendering: pixelated` matters: these are
// 32px pixel-art sprites and smooth scaling turns them to mush.
// Every sprite is returned already wrapped in its slot: the slot is the recessed
// tile, the inner node is the art that lifts out of it.
function slot(inner, cls) {
  const box = el("div", "slot" + (cls ? " " + cls : ""));
  box.appendChild(inner);
  return box;
}

// Pills are the one item with no icon of its own: the game reshuffles which colour
// carries which effect every run, so there is no such thing as "the red pill". The
// icon is therefore every colour, cycled -- one strip of 32px frames, stepped by CSS.
//
// The frame count comes from the strip itself rather than being written here as well.
// It was in three places (the harvest's prefix(), this file, and the steps() in the
// stylesheet) and nothing made them agree: a strip with fewer colours would have been
// stretched to the old width and every frame would have landed off-register, quietly.
const strips = {};
// Read once, from the stylesheet, so the period lives in exactly one place.
const PILL_CYCLE =
  parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--pill-cycle"))
  || 3400;
function pillSprite(scale) {
  const n = strips.pills.frames;
  const node = el("div", "sprite sheet-pills");
  const w = 32 * scale;
  node.style.width = node.style.height = w + "px";
  node.style.backgroundSize = `${w * n}px ${w}px`;
  node.style.setProperty("--strip-end", `-${w * n}px`);
  node.style.setProperty("--strip-steps", n);
  // Every pill on the same frame at the same moment. A CSS animation starts when its
  // element is created, and rows arrive in batches as you scroll, so a plain 0s delay
  // would leave each batch running in its own phase. Winding the clock back by however
  // far we already are into the current cycle puts a row created now exactly where one
  // created at page load would be.
  node.style.setProperty("--strip-d", `-${performance.now() % PILL_CYCLE}ms`);
  return slot(node);
}

function sprite(gfx, scale = 1) {
  // Only once the strip has actually arrived. A data directory built before the
  // strip existed still has a usable single pill frame in the item atlas, and
  // falling through to it beats rendering an empty tile with no missing-art marker.
  if (gfx === "pill.png" && strips.pills) return pillSprite(scale);
  const node = el("div", "sprite");
  const frame = atlas && gfx ? atlas.frames[gfx.toLowerCase()] : null;
  if (!frame) {
    node.classList.add("sprite-missing");
    node.style.width = node.style.height = 32 * scale + "px";
    return slot(node);
  }
  const size = atlas.cell * scale;
  node.classList.add("sheet-items");
  node.style.width = node.style.height = size + "px";
  node.style.backgroundSize = `${atlas.width * scale}px ${atlas.height * scale}px`;
  node.style.backgroundPosition = `-${frame[0] * scale}px -${frame[1] * scale}px`;
  return slot(node);
}

// The sheets are 0.3, 1.1 and 1.9 MB as base64 data URIs. Assigning one to
// element.style.backgroundImage per sprite meant rebuilding that entire string for
// every row drawn -- 400 achievement rows x 2.5 MB is why the list took over a second
// to redraw on each keystroke. Each sheet is now published once as a custom property
// and the per-element styles carry nothing but geometry.
function publishSheet(name, uri) {
  document.documentElement.style.setProperty("--atlas-" + name, `url(${uri})`);
  // Decode up front and off the critical path: otherwise the first row to scroll into
  // view pays for decoding a megapixel sheet, synchronously, mid-scroll.
  const img = new Image();
  img.src = uri;
  if (img.decode) img.decode().catch(() => {});
}

window.onAtlas = (payload) => {
  atlas = payload;
  if (payload && payload.uri) publishSheet("items", payload.uri);
  if (catalogue.length) renderResults();
};

// The achievement badges and the enemy art are separate sheets with their own cell
// sizes -- badges are 64px line art, enemies are cropped animation frames.
const icons = {};
// Cells are not square everywhere: an achievement badge is 263x176, so width and
// height have to be read separately or the art comes out squashed.
function icon(sheet, key, scale = 1, cls) {
  const a = icons[sheet];
  const frame = a && key ? a.frames[key.toLowerCase()] : null;
  const node = el("div", "sprite" + (frame ? "" : " sprite-missing"));
  // A cell can hold several frames side by side (the enemy sheet packs a short idle
  // loop into each), so the box is one FRAME wide, not one cell.
  const steps = (a && a.steps) || 1;
  const w = (a ? (a.cellW || a.cell) : 32) / steps;
  const h = a ? (a.cellH || a.cell) : 32;
  node.style.width = w * scale + "px";
  node.style.height = h * scale + "px";
  if (!frame) return slot(node, cls);
  node.classList.add("sheet-" + sheet);
  node.style.backgroundSize = `${a.width * scale}px ${a.height * scale}px`;
  node.style.backgroundPosition = `-${frame[0] * scale}px -${frame[1] * scale}px`;
  if (steps > 1) {
    // The idle plays by walking background-position-x across the cell. Start and end
    // go through custom properties so one @keyframes serves every sprite on the sheet.
    node.style.setProperty("--strip-x", `-${frame[0] * scale}px`);
    node.style.setProperty("--strip-end", `-${(frame[0] + w * steps) * scale}px`);
    node.style.setProperty("--strip-steps", steps);
    node.classList.add("sprite-anim");
  }
  return slot(node, cls);
}
// A sheet that is only ever one image -- no index, no cells, just a frame count.
// Published the same way so it costs one custom property instead of a data URI per
// element. Arrives with the atlas, but the catalogue may already be drawn, so rows
// that fell back to the atlas frame are redrawn once it lands.
window.onStrip = (name, payload) => {
  if (!payload || !payload.uri || !(payload.frames > 0)) return;
  strips[name] = payload;
  publishSheet(name, payload.uri);
  if (catalogue.length) renderResults();
  // The pill rows draw the sprite itself, so they need redrawing once it arrives.
  if (name === "pills" && typeof renderPills === "function") renderPills();
};
window.onIconAtlas = (name, payload) => {
  if (!payload) return;
  icons[name] = payload;
  publishSheet(name, payload.uri);
  if (name === "achievements" && achievements.length) renderAchievements();
  if (name === "monsters" && bestiary.length) renderBestiary();
};

/* ============================================================================
   SORT  —  one block, pasted verbatim into site.html's <script> (the same one
   that defines render/renderFoes) and into the end of app.js.  It wires only
   the selects the page actually has, so both surfaces run identical code.

   Renderers change by one token each — sort the rows you already filtered:
     site render()         paginate(list, Sort.apply("#qsort", out),     (it)=>{
     site renderFoes()     paginate(list, Sort.apply("#fsort", out),     (e)=>{
     app  renderResults()  paginate(list, Sort.apply("#isort", matches), (item)=>{
     app  renderBestiary() paginate(list, Sort.apply("#bsort", rows),    (e)=>{
   Filtering, scoring and the "N of M" counts are untouched: sorting happens
   after them, on a copy, and never changes the row count.
   ========================================================================== */
var Sort = (function () {
  "use strict";

  var COLL = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  var KEY = "sort.";

  function str(v) { return v == null ? "" : String(v); }
  /* null means "this row has no value for that key" and always sorts last. */
  function n(v) {
    var x = typeof v === "number" ? v : (v == null || v === "" ? NaN : +v);
    return isFinite(x) ? x : null;
  }
  /* Null-safe step. 0 means "indistinguishable", so the caller falls through
     to the next key. Missing values sink in BOTH directions, deliberately:
     an item with no devil price is not "the cheapest". */
  function step(x, y, dir) {
    if (x === y) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return x < y ? -dir : dir;
  }

  /* The two surfaces name three fields differently. Read either. */
  function charges(o) { return n(o.charges != null ? o.charges : o.maxCharges); }
  function devil(o) { return n(o.devil != null ? o.devil : o.devilPrice); }
  function isBoss(e) { return (e.boss != null ? e.boss : e.isBoss) ? 0 : 1; }

  /* Kind order is the app's own #kind menu, not alphabetical: passives and
     actives are what you look up mid-run, pills are what you never do. */
  var KINDS = ["passive", "active", "familiar", "trinket", "card", "pill"];
  function kind(o) { var i = KINDS.indexOf(o.kind); return i < 0 ? KINDS.length : i; }

  /* Shakiest data first — reorder this line to change the grouping.
     Values are Confidence.rawValue; anything unrecognised sorts last. */
  var CONF = ["singleSource", "nonNumeric", "conditional", "crossChecked", "verified"];
  function conf(o) { var i = CONF.indexOf(o.confidence); return i < 0 ? CONF.length : i; }

  /* Enemy HP at a reference floor. stageHP is added per floor, so base HP
     alone mis-ranks the 41 scaling enemies — Krampus reads 60 and fights like
     240 by floor 5. Floor 5 is exactly what both detail views already print
     ("60 base, +45 per floor — 240 on floor 5"), so the order agrees with the
     number on screen. Non-scaling enemies are unaffected (stageHP is 0). */
  var FLOOR = 5;
  function hp(e) {
    var base = n(e.hp);
    return base == null ? null : base + (n(e.stageHP) || 0) * (FLOOR - 1);
  }

  /* Every comparator ends here, so equal keys never shuffle between renders.
     Both halves of the chain are needed: 224 item ids repeat across kinds
     (collectible 4 and trinket 4), and 11 enemy names repeat across variants. */
  function tie(a, b) {
    return COLL.compare(str(a.name), str(b.name))
      || step(n(a.id), n(b.id), 1)
      || step(n(a.type), n(b.type), 1)
      || step(n(a.variant), n(b.variant), 1)
      || COLL.compare(str(a.kind), str(b.kind));
  }
  function byNum(get, dir) {
    return function (a, b) { return step(get(a), get(b), dir) || tie(a, b); };
  }
  function byText(get, dir) {
    return function (a, b) { return COLL.compare(str(get(a)), str(get(b))) * dir || tie(a, b); };
  }
  function name(o) { return o.name; }

  var CMP = {
    item: {
      "": null,                       /* null = leave the renderer's own order alone */
      "name": byText(name, 1),
      "name-desc": byText(name, -1),
      "id": function (a, b) { return step(kind(a), kind(b), 1) || step(n(a.id), n(b.id), 1) || tie(a, b); },
      "kind": function (a, b) { return step(kind(a), kind(b), 1) || tie(a, b); },
      "charge": byNum(charges, 1),
      "devil": byNum(devil, 1),
      "conf": byNum(conf, 1),
      /* app only: delta keys are display labels ("Damage", "Damage x", ...).
         Flat damage-ups only — a x2.3 multiplier is not comparable to a +40. */
      "dmg": byNum(function (o) { return o.delta ? n(o.delta["Damage"]) : null; }, -1)
    },
    foe: {
      "": null,
      "name": byText(name, 1),
      "hp-desc": byNum(hp, -1),
      "hp-asc": byNum(hp, 1),
      /* Bosses first, hardest first inside each group. */
      "boss": function (a, b) { return (isBoss(a) - isBoss(b)) || step(hp(a), hp(b), -1) || tie(a, b); },
      /* The spawn-console order: type, then variant. */
      "type": function (a, b) { return step(n(a.type), n(b.type), 1) || step(n(a.variant), n(b.variant), 1) || tie(a, b); }
    }
  };

  var wired = {};                     /* "#qsort" -> { el, kind } */

  function load(el) {
    var v = null;
    try { v = localStorage.getItem(KEY + el.id); } catch (e) { /* private mode */ }
    if (v == null || v === el.value) return false;
    for (var i = 0; i < el.options.length; i++) {
      if (el.options[i].value === v) { el.value = v; return true; }
    }
    return false;                     /* stored an option we no longer offer: ignore it */
  }

  function wire(selectSel, kindName, listSel, rerender) {
    var el = document.querySelector(selectSel);
    if (!el) return;                  /* the other surface — nothing to wire */
    wired[selectSel] = { el: el, kind: kindName };
    el.addEventListener("change", function () {
      try { localStorage.setItem(KEY + el.id, el.value); } catch (e) { /* private mode */ }
      rerender();
    });
    /* A restored choice only needs a redraw if this list was already drawn in
       the default order; lazily drawn views pick it up on their own. */
    var list = document.querySelector(listSel);
    if (load(el) && list && list.children.length) rerender();
  }

  function apply(selectSel, rows) {
    var w = wired[selectSel];
    if (!w) return rows;
    var cmp = CMP[w.kind][w.el.value];
    return cmp ? rows.slice().sort(cmp) : rows;   /* slice: never reorder D.items / catalogue */
  }

  return { wire: wire, apply: apply, cmp: CMP, hpAt: hp, floor: FLOOR };
})();

(function () {
  function go() {
    Sort.wire("#qsort", "item", "#list",    function () { render(); });          /* website items   */
    Sort.wire("#fsort", "foe",  "#flist",   function () { renderFoes(); });      /* website enemies */
    Sort.wire("#isort", "item", "#results", function () { renderResults(); });   /* app items       */
    Sort.wire("#bsort", "foe",  "#blist",   function () { renderBestiary(); });  /* app enemies     */
  }
  /* setTimeout, not a bare call: pasted mid-script the renderers may not be
     defined yet, and only the selects that exist here are ever touched. */
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go);
  else setTimeout(go, 0);
})();

// The colour vocabulary the sprite sampler produces, mapped back to something CSS can
// tint with. These are the same twelve names shown as swatches in the search chips.
const FX_HEX = {
  red: "#b81f22", orange: "#e2542b", gold: "#d9a441", yellow: "#e8cf5a",
  green: "#7e9c46", teal: "#4a9c95", blue: "#3f6fb5", purple: "#7a4a9c",
  pink: "#d98ca8", brown: "#7a5230", grey: "#8d8d8d", white: "#efe7d8",
  black: "#1a1414",
};

// Turns one item into the handful of scalars the background reads. Everything is
// derived from the item itself, so the same item always looks the same way and two
// poison items never look identical: the family sets the behaviour, these set the
// character.
function fxItemVars(el, obj) {
  if (!el || !obj) return;
  const h = fxHash((obj.name || "") + ":" + (obj.id != null ? obj.id : obj.type));
  const cols = (obj.colors || []).map((c) => FX_HEX[c]).filter(Boolean);
  el.style.setProperty("--i-hue", String(h % 360));
  el.style.setProperty("--i-seed", String(h % 101));
  el.style.setProperty("--i-speed", (0.7 + ((h >>> 8) % 71) / 100).toFixed(2));
  el.style.setProperty("--i-dense", String((h >>> 16) % 101));
  // The item's own sprite colours are what make the wash feel like THIS item.
  if (cols[0]) el.style.setProperty("--i-c1", cols[0]);
  if (cols[1]) el.style.setProperty("--i-c2", cols[1]);
}

// Rows stagger their idle so a list never breathes in lockstep.
function fxIdleVar(el, key) {
  // NEGATIVE, which is the whole point of the phase ladder this overrides: a negative
  // delay starts the row already mid-cycle. Positive was wrong twice over -- rows sat
  // dead still for up to 4s and then moved together, and once sprites started playing
  // their own frames it meant an enemy could stand frozen for four seconds before it
  // ever animated. `animation-delay` covers every slot on the element, so this one
  // number phases the bob and the sprite's frames together.
  el.style.setProperty("--idle-d", "-" + (fxHash(key || "") % 4000) + "ms");
}

// ---- effect animations ------------------------------------------------------
// Effects the game actually has, matched against the item's own EID description --
// it carries the game's {{markers}} plus the words it uses for tear behaviour.
const FX_RULES = [
  // The game's own {{status}} markers come first, ahead of any prose keyword. They
  // are the game stating the effect outright, so they beat a word that happens to
  // appear in the description -- Fire Mind is {{Burning}} whose tears also explode,
  // and matching "explos" first gave it the shock backdrop instead of the fire one.
  [/\{\{Burning\}\}/i,                          ["fxEmber"], true],
  [/\{\{BleedingOut\}\}/i,                      ["fxBloodSplat"], true],
  [/\{\{Poison\}\}|poison/i,                    ["fxCreep", "fxDrip"], true],
  [/\{\{Slow\}\}|slow(s|ing|ed)?\b|slowing/i,   ["fxSlow", "fxPuddle"], true],
  [/\{\{Fear\}\}|fear/i,                        ["fxFear"], true],
  [/\{\{Charm\}\}|charm/i,                      ["fxCharm"], true],
  [/\{\{Petrify\}\}|petrif|freeze|frozen/i,     ["fxPetrify"], true],
  [/\{\{Confusion\}\}|confus/i,                 ["fxConfuse"], true],
  [/\{\{Chargeable\}\}|chargeable|charge/i,     ["fxCharge"], true],
  [/explos|\{\{Bomb\}\}|bomb/i,                 ["fxBoom", "fxShockwave", "fxDebris"], true],
  [/brimstone/i,                                ["fxBrimstone"], true],
  [/laser|beam|technology/i,                    ["fxLaser", "fxBrimstone"], true],
  [/knife|scythe|blade|razor/i,                 ["fxScythe", "fxRazor"], true],
  [/pierc|needle/i,                             ["fxNeedle"], true],
  [/spectral|ghost|dimension/i,                 ["fxMultidim", "fxWarp"], true],
  [/homing/i,                                   ["fxHoming", "fxBoomerang"], true],
  [/bounc|rebound|boomerang/i,                  ["fxImpact", "fxBoomerang"], true],
  [/fire|burn|flame|ember/i,                    ["fxEmber"], true],
  [/creep/i,                                    ["fxCreep"], true],
  [/flight|hover|float/i,                       ["fxWisp", "fxBalloon"], true],
  [/orbital|orbit|ring of/i,                    ["fxOrbit"], true],
  [/\bfly\b|flies|spider|locust|beetle/i,       ["fxSkitter"], true],
  [/worm|leech|maggot/i,                        ["fxLeech"], true],
  [/\{\{Luck\}\}|luck/i,                        ["fxFireworks"], false],
  [/teleport|warp/i,                            ["fxWarp"], true],
  [/shield|block(s|ing)? (enemy|projectil)/i,   ["fxShield"], true],
  [/fart/i,                                     ["fxFart"], true],
  [/rock|stone|boulder/i,                       ["fxStone"], false],
  [/black ?hole|attract|magnet|pull/i,          ["fxBlackHole"], true],
  [/rocket|missile/i,                           ["fxRocket"], true],
  [/spike|nail/i,                               ["fxSpike"], true],
  [/tooth|teeth/i,                              ["fxTooth"], false],
  [/light|sky|holy|halo/i,                      ["fxCrackSky"], true],
  [/\{\{Coin\}\}|coin|penn(y|ies)|shop/i,       ["fxCoinFlip"], false],
  [/\{\{(Key|Card|Pill|Rune|Trinket)\}\}/i,     ["fxCoinFlip", "fxChest"], false],
  [/\bdevil\b|satan|demon|unholy/i,              ["fxDevil", "fxPentagram"], true],
  [/\bangel\b|holy|heaven|seraph/i,              ["fxHeavenDoor"], true],
  [/\{\{(Heart|HalfHeart|HealingRed|EmptyHeart)\}\}|health|heal/i, ["fxBloodSplat"], false],
  [/\{\{Tears\}\}|tear/i,                       ["fxTear", "fxDrip"], false],
  [/\{\{(Damage|Tearsize)\}\}/i,                ["fxStomp", "fxStone"], false],
  [/\{\{(Speed|Range|Shotspeed)\}\}/i,          ["fxNeedle", "fxRocket"], false],
  [/\{\{(Timer|Battery)\}\}/i,                  ["fxCharge"], false],
];

// Every item is a tear at heart, and the game draws 39 different ones. Giving each
// item its OWN three -- picked from its name, so the choice is stable but unshared --
// is what stops a screen of plain stat items all moving the same way. That was the
// bug: without it, anything whose description is just "+0.5 Damage" fell back to the
// same pair and the whole list read as one animation.
const FX_GENERIC = [
  "fxTear", "fxStone", "fxBone", "fxNeedle", "fxRazor", "fxScythe", "fxBalloon",
  "fxPop", "fxPupula", "fxHungry", "fxMultidim", "fxDarkMatter", "fxGlaucoma",
  "fxMetallic", "fxTooth", "fxImpact", "fxDebris", "fxPoof", "fxBloodSplat",
];
const FX_BADGE = ["fxCoinFlip", "fxChest", "fxFireworks", "fxWarp", "fxHeavenDoor",
  "fxPop", "fxImpact", "fxPoof", "fxPentagram"];

function fxHash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
// Deterministic sample without replacement, seeded by the row's own name.
function fxDraw(pool, seed, count) {
  const out = [], used = new Set();
  let h = seed || 1;
  while (out.length < Math.min(count, pool.length)) {
    h = Math.imul(h ^ (h >>> 15), 2246822519) >>> 0;
    let i = h % pool.length;
    while (used.has(i)) i = (i + 1) % pool.length;
    used.add(i); out.push(pool[i]);
  }
  return out;
}
function fxMatch(hay, realOnly) {
  const out = [];
  for (const [re, fx, isReal] of FX_RULES) {
    if (realOnly && !isReal) continue;
    if (re.test(hay)) out.push(...fx);
  }
  return out;
}
// A row's effects come in two kinds, and they are kept apart deliberately.
//   real    - the item genuinely does this. Ipecac IS poison, Brimstone IS a beam.
//             These never shuffle: the effect is the item's identity, so it is baked
//             in and plays the same way every time.
//   generic - filler drawn from the item's own name so a screen of plain stat items
//             still varies. Only ever used when minimalist mode is off.
function fxSplit(name, hay, extra) {
  const real = [...new Set(fxMatch(hay || "", true).concat(extra || []))];
  // Stat-driven matches are filler, not identity, so they join the generic pool.
  const stat = fxMatch(hay || "", false).filter((f) => !real.includes(f));
  const generic = [...new Set(stat.concat(fxDraw(FX_GENERIC, fxHash(name || ""), 3)))]
    .filter((f) => !real.includes(f)).slice(0, 4);
  return { real, generic, all: [...new Set(real.concat(generic))] };
}
function fxFor(name, text) { return fxSplit(name, text); }
function fxForEnemy(e) {
  return fxSplit(e.name, e.name + " " + (e.colors || []).join(" "),
    (e.isBoss || e.boss) ? ["fxStomp", "fxBoom", "fxShockwave"] : []);
}
// A badge has no in-game effect of its own, so everything it does is generic.
function fxForBadge(a) {
  const generic = fxDraw(FX_BADGE, fxHash(a.name + a.id), 4);
  return { real: [], generic, all: generic };
}

// Writes the three attributes every row is read through.
function fxApply(el, split) {
  el.dataset.fx = split.all.join(" ");
  el.dataset.fxReal = split.real.join(" ");
  if (split.real.length) el.dataset.effReal = FX_FAMILY[split.real[0]] || "blood";
}

const FX_FAMILY = {
  fxCreep: "creep", fxPuddle: "creep", fxDrip: "poison", fxSlow: "poison",
  fxEmber: "fire", fxRocket: "fire", fxCrackSky: "holy", fxHeavenDoor: "holy",
  fxBloodSplat: "blood", fxHungry: "blood", fxLeech: "blood", fxRazor: "blood",
  fxScythe: "blood", fxNeedle: "blood",
  fxBoom: "shock", fxShockwave: "shock", fxStomp: "shock", fxImpact: "shock",
  fxDebris: "smoke", fxPoof: "smoke", fxFart: "smoke",
  fxStone: "smoke", fxBone: "smoke", fxTooth: "smoke",
  fxBrimstone: "fire", fxLaser: "spark", fxMetallic: "spark", fxSpike: "spark",
  fxPetrify: "frost", fxGlaucoma: "frost", fxBalloon: "frost", fxWisp: "frost",
  fxCharm: "charm", fxPop: "charm", fxPupula: "charm",
  fxFireworks: "luck", fxCoinFlip: "luck", fxChest: "luck",
  fxBlackHole: "dark", fxDarkMatter: "dark", fxWarp: "dark", fxPentagram: "dark",
  fxDevil: "dark", fxConfuse: "dark", fxMultidim: "dark", fxFear: "dark",
  fxTear: "blood", fxSkitter: "poison", fxOrbit: "spark", fxHoming: "spark",
  fxBoomerang: "spark", fxCharge: "spark", fxShield: "holy",
};

// Chooses what a row plays when it comes into view.
//
// The rule that matters: an item's REAL effect is its identity, so it never shuffles.
// Ipecac is poison every single time. Only rows with nothing of their own draw from
// the generic pool, and only when minimalist mode is off -- with it on they stay
// completely still, so the effects you do see always mean something.
function fxPick(el) {
  const real = (el.dataset.fxReal || "").split(" ").filter(Boolean);
  if (real.length) {
    // Baked in. Stable across every appearance, not a random draw.
    return { anim: real[0], eff: el.dataset.effReal || "blood", real: true };
  }
  if (window.FX_MIN_ON) return null;          // nothing of its own: stay still
  const pool = (el.dataset.fx || "fxTear").split(" ").filter(Boolean);
  const anim = pool[(Math.random() * pool.length) | 0];
  return { anim, eff: FX_FAMILY[anim] || "blood", real: false };
}

// Replays a row's own effect on hover -- only rows that genuinely have one, so the
// hover is a hint that there is something to look at rather than noise on every row.
function fxHoverBind(el) {
  if (!el.dataset.fxReal) return;
  let busy = false;
  el.addEventListener("pointerenter", () => {
    if (busy || window.FX_ANIM_ON === false) return;
    const anim = (el.dataset.fxReal || "").split(" ")[0];
    if (!anim) return;
    busy = true;
    el.style.setProperty("--fx-run", "none");
    void el.offsetWidth;
    el.style.setProperty("--fx-run", `${anim} .5s var(--ease) both`);
    if (window.FX_EFF_ON !== false) el.dataset.eff = el.dataset.effReal || "blood";
    // Belt and braces: the contents move, not the row, so the pointer should never
    // leave -- but a lock means even a stray re-enter cannot start a second copy.
    setTimeout(() => { busy = false; }, 560);
  });
}

const FX_REDUCED = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Rows re-shuffle whenever they come back into view, so scrolling up and down deals a
// different hand each time rather than freezing whatever played first.
//
// Cost is bounded by how many may START at once rather than by how fast you scroll. A
// velocity gate was tried first and removed: it suppressed exactly the scroll-up-and-
// back motion this is meant to replay, and the effects were only ever worth ~12fps of
// a fling anyway -- the rest is batch loading and sprite rasterisation.
const FX_MAX_AT_ONCE = 26;
const fxIO = new IntersectionObserver((es) => {
  if (FX_REDUCED) return;
  const entering = [];
  for (const e of es) {
    e.target.style.setProperty("--fx-run", "none");  // wound back, ready to replay
    e.target.removeAttribute("data-eff");
    if (e.isIntersecting) entering.push(e.target);
  }
  if (!entering.length) return;
  // Restarting a CSS animation needs a reflow between clearing the name and setting
  // it. One read for the whole batch, instead of a synchronous layout per row.
  void document.body.offsetWidth;
  const n = Math.min(entering.length, FX_MAX_AT_ONCE);
  for (let i = 0; i < n; i++) {
    const el = entering[i];
    const choice = fxPick(el);
    if (!choice) continue;                // minimalist: nothing of its own to show
    // Two independent switches. The choice is made either way so the overlay still
    // matches what the row would have done with motion turned off.
    if (window.FX_ANIM_ON !== false)
      el.style.setProperty("--fx-run",
        `${choice.anim} .5s var(--ease) ${(Math.random() * 70) | 0}ms both`);
    if (window.FX_EFF_ON !== false) el.dataset.eff = choice.eff;
  }
}, { rootMargin: "0px 0px -6% 0px" });

// Rows that have scrolled out of view stop animating.
//
// A list keeps every row it has ever paged in, and each one carries a sprite that is
// now playing its own frames: the item index alone had 824 running animations, and a
// running animation ticks whether or not anyone can see it. Resting the off-screen
// ones is what buys back the headroom for the visible ones to move smoothly.
//
// `paused`, not `none`: none would rewind every sprite to frame 0, so scrolling back
// up would show a wall of enemies all restarting in step. Paused holds the frame the
// row was on, and it picks up exactly where it left off.
//
// The margin is generous on purpose -- a row wakes well before it can be seen, so it
// is already mid-cycle by the time it arrives, and the fade-out happens off-screen.
const restIO = new IntersectionObserver((es) => {
  for (const e of es) e.target.classList.toggle("rest", !e.isIntersecting);
}, { rootMargin: "280px 0px" });

// ---- incremental lists ------------------------------------------------------
// Building every row up front is why opening Items or Unlocks paused: the view had to
// lay out and rasterise 400 rows before it could paint one. Each list now renders just
// enough to fill the view and grows as you reach the end, so it opens instantly and
// each batch fades in as it arrives.
/* The Rows-per-load setting writes window.BATCH_SIZE; read it per batch rather
   than capturing it once, so changing the setting takes effect on the next scroll
   instead of needing a reload. */
const BATCH_DEFAULT = 24;
const pagers = new WeakMap();
function paginate(list, rows, makeRow) {
  pagers.get(list)?.disconnect();          // a new search supersedes the previous list
  list.querySelectorAll("li").forEach((el) => { fxIO.unobserve(el); restIO.unobserve(el); });
  list.textContent = "";
  let n = 0;
  const sentinel = el("li", "more");
  // The scroller is the <section>, not the window, so the observer needs it as root.
  const root = list.closest(".page") || null;
  const io = new IntersectionObserver(
    (es) => { if (es.some((e) => e.isIntersecting)) grow(); },
    { root, rootMargin: "600px 0px" });
  pagers.set(list, io);
  list.appendChild(sentinel);

  function grow() {
    // A new search wipes the list, but this pager may already have a top-up queued on
    // the next frame. Its sentinel is gone from the DOM by then, and insertBefore
    // throws NotFoundError. Bail rather than fight for a list we no longer own.
    if (!sentinel.isConnected) return;
    if (n >= rows.length) { io.disconnect(); sentinel.remove(); return; }
    const frag = document.createDocumentFragment();
    const end = Math.min(n + (window.BATCH_SIZE || BATCH_DEFAULT), rows.length);
    for (let i = n; i < end; i++) {
      const node = makeRow(rows[i], i);
      frag.appendChild(node);
      fxIO.observe(node);
      restIO.observe(node);
    }
    n = end;
    list.insertBefore(frag, sentinel);
    if (n >= rows.length) { io.disconnect(); sentinel.remove(); return; }
    // A tall window can swallow a whole batch without the sentinel ever leaving the
    // viewport, and the observer only fires on a CHANGE -- so top it up explicitly.
    requestAnimationFrame(() => {
      const box = root ? root.getBoundingClientRect().bottom : innerHeight;
      if (sentinel.getBoundingClientRect().top < box + 600) grow();
    });
  }
  io.observe(sentinel);
  grow();
}

// ---- tabs ----------------------------------------------------------------
document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
    document.querySelectorAll(".page").forEach((p) => p.classList.remove("active"));
    tab.classList.add("active");
    const target = $(tab.dataset.tab);
    if (target) target.classList.add("active");
  });
});
$("panel-toggle").addEventListener("click", () => send({ type: "togglePanel" }));
$("play").addEventListener("click", () => send({ type: "launchGame" }));

// Ask for a view's data the first time it is opened, and refresh unlocks each time —
// the game rewrites the save the moment you unlock something.
document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => {
  if (t.dataset.tab === "unlocks") send({ type: "achievements" });
  // The panel can be dragged or resized while another tab is open, so the preview
  // asks for fresh geometry rather than trusting whatever it last drew.
  if (t.dataset.tab === "overlay") send({ type: "panelGeometry" });
  if (t.dataset.tab === "bestiary" && !bestiary.length) send({ type: "bestiary" });
  // Not a fresh check -- just the current state, so the row is never stale-looking
  // when you open the tab. Checking is on its own schedule.
  if (t.dataset.tab === "settings") send({ type: "updateState" });
  if (t.dataset.tab === "history") send({ type: "history" });
}));

// ---- unlocks ---------------------------------------------------------------
let achievements = [];
let saveSource = null;

function achievementRow(a, asPin) {
  const li = el("li", (a.unlocked ? "done " : "") + "clickable");
  // A badge is a card the game deals you, so it flips, drops or glints in rather
  // than pretending to be a tear effect.
  fxApply(li, fxForBadge(a));
  fxIdleVar(li, a.name);
  li.addEventListener("click", (e) => {
    // The pin button lives inside the row; its own handler must win.
    if (e.target.closest("button")) return;
    window.fxFrom = li.querySelector(".sprite");
    showAchievement(a);
  });
  const body = el("div", "grow");
  const head = el("div");
  head.appendChild(el("span", "name", a.name));
  head.appendChild(el("span", "pill " + (a.unlocked ? "verified" : ""), a.unlocked ? "unlocked" : "locked"));
  body.appendChild(head);
  // The condition is the whole point; when the game never stated one, say so plainly
  // rather than leaving the row looking blank.
  body.appendChild(el("div", a.known ? "desc" : "desc cut", a.condition));
  if (a.unlocks.length) {
    body.appendChild(el("div", "desc pools", "Gives: " + a.unlocks.join(", ")));
  }
  const badge = icon("achievements", a.gfx, 0.25, "badge-art");
  // The badges are dark line art drawn for the game's parchment card; on either
  // theme's background they otherwise disappear.
  if (!a.unlocked) badge.classList.add("badge-art-locked");
  li.appendChild(badge);
  li.appendChild(body);

  // The pinned row ALWAYS gets its button: pin something, then unlock it, and
  // otherwise there would be no way to clear it.
  if (!a.unlocked || asPin) {
    const btn = el("button", "ghost pinbtn", asPin || a.pinned ? "Unpin" : "Pin");
    btn.title = a.pinned ? "Stop tracking this" : "Keep this one in view while you play";
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      send({ type: "pin", id: a.pinned ? null : a.id });
    });
    li.appendChild(btn);
  }
  return li;
}

function renderAchievements() {
  const q = $("aq").value.trim().toLowerCase();
  const mode = $("afilter").value;
  const pin = achievements.find((a) => a.pinned);

  const pinBox = $("pinned");
  pinBox.textContent = "";
  if (pin) {
    pinBox.appendChild(el("h2", null, pin.unlocked ? "Chasing \u2014 done" : "Chasing"));
    const list = el("ul", "results");
    list.appendChild(achievementRow(pin, true));
    pinBox.appendChild(list);
  }

  let rows = achievements;
  if (mode === "locked") rows = rows.filter((a) => !a.unlocked);
  if (mode === "unlocked") rows = rows.filter((a) => a.unlocked);
  if (q) {
    rows = rows.filter((a) =>
      a.name.toLowerCase().includes(q) || a.condition.toLowerCase().includes(q)
      || a.unlocks.some((u) => u.toLowerCase().includes(q)));
  }
  const total = achievements.length;
  const got = achievements.filter((a) => a.unlocked).length;
  $("acount").textContent =
    `${got} of ${total} unlocked \u00b7 showing ${rows.length}` + (saveSource
      ? ` \u00b7 read from ${saveSource}`
      : " \u00b7 no save file found \u2014 unlock state unknown");

  const list = $("alist");
  list.textContent = "";
  if (!rows.length) {
    pagers.get(list)?.disconnect();
    list.appendChild(el("li", "empty", "Nothing matches."));
    return;
  }
  paginate(list, rows, (a) => achievementRow(a));
}

window.onAchievements = (payload) => {
  // Older shape was a bare array; the object adds the save-file provenance.
  achievements = Array.isArray(payload) ? payload : payload.rows;
  saveSource = Array.isArray(payload) ? null : payload.source;
  renderAchievements();
};
["aq", "afilter"].forEach((id) => $(id).addEventListener("input", renderAchievements));

// ---- bestiary --------------------------------------------------------------
let bestiary = [];
function renderBestiary() {
  const q = $("bq").value.trim().toLowerCase();
  // Eleven effect rows carry boss="1" upstream (Crack The Sky, BlackHoleRay) with
  // 0 HP, so "bosses" has to mean fightable bosses or those reappear.
  const mode = $("bfilter").value;
  let rows = bestiary;
  if (mode === "boss") rows = rows.filter((e) => e.isBoss && e.fightable);
  else if (mode !== "all") rows = rows.filter((e) => e.fightable);
  // Colours come from the sprite pixels, so "grey spider" finds it by description
  // even though nothing in the game files describes what an enemy looks like.
  if (q) {
    const terms = q.split(/\s+/);
    rows = rows.filter((e) => {
      const hay = (e.name + " " + (e.colors || []).join(" ")).toLowerCase();
      return terms.every((t) => hay.includes(t));
    });
  }
  $("bcount").textContent = `${rows.length} of ${bestiary.length}`;
  const list = $("blist");
  list.textContent = "";
  if (!rows.length) {
    pagers.get(list)?.disconnect();
    list.appendChild(el("li", "empty", "Nothing matches."));
    return;
  }
  paginate(list, Sort.apply("#bsort", rows), (e) => {
    const li = el("li", "clickable");
    fxApply(li, fxForEnemy(e));
    fxItemVars(li, e);
    fxIdleVar(li, e.name);
    if (e.isBoss && e.fightable) li.dataset.boss = "1";
    fxHoverBind(li);
    const body = el("div", "grow");
    const head = el("div");
    head.appendChild(el("span", "name", e.name));
    if (e.isBoss && e.fightable) head.appendChild(el("span", "pill conditional", "boss"));
    if (!e.fightable) head.appendChild(el("span", "pill", "not an enemy"));
    if (!e.blocksClear) {
      const p = el("span", "pill", "does not block");
      p.title = "This does not hold the doors shut — clearing the room ignores it.";
      head.appendChild(p);
    }
    body.appendChild(head);
    const bits = [`${e.hp} HP`];
    // stageHP is added per floor, so baseHP alone is not what you actually fight.
    if (e.stageHP > 0) bits.push(`+${e.stageHP} per floor`);
    bits.push(`type ${e.type}.${e.variant}`);
    body.appendChild(el("div", "desc mono", bits.join("   ")));
    if (e.colors && e.colors.length) {
      body.appendChild(el("div", "desc pools", e.colors.join(", ")));
    }
    li.appendChild(icon("monsters", e.art, 0.375));
    li.appendChild(body);
    li.addEventListener("click", () => { window.fxFrom = li.querySelector(".sprite"); showEnemy(e); });
    return li;
  });
}
window.onBestiary = (rows) => { bestiary = rows; renderBestiary(); };
["bq", "bfilter", "bsort"].forEach((id) => {
  const el = $(id); if (el) el.addEventListener("input", renderBestiary);
});

// ---- theme -----------------------------------------------------------------
// Devil is the default; Angel is the light room. Persisted in localStorage so the
// choice survives a relaunch without a round trip through Swift.
const THEMES = {
  devil: { glyph: "\u26E7", name: "Devil" },   // ⛧
  angel: { glyph: "\u271D", name: "Angel" },   // ✝
};
/// `notify` MUST be false when Swift is the caller. Notifying unconditionally makes
/// the two sides ping-pong: page -> setTheme -> revision++ -> push -> page -> ...
function applyTheme(next, { animate = false, notify = false } = {}) {
  const t = THEMES[next] ? next : "devil";
  const root = document.documentElement;
  // Suppress transitions for the swap itself — see .no-transition in the CSS.
  root.classList.add("no-transition");
  // Devil is the stylesheet's default, so it carries no attribute at all.
  if (t === "devil") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", t);
  // Two frames: one for the attribute to take, one for styles to settle.
  requestAnimationFrame(() =>
    requestAnimationFrame(() => root.classList.remove("no-transition")));
  if (notify) send({ type: "setTheme", theme: t });
  if (animate) {
    document.body.classList.remove("theming");
    void document.body.offsetWidth;          // restart the animation
    document.body.classList.add("theming");
  }
  $("theme-toggle").querySelector(".glyph").textContent = THEMES[t].glyph;
  $("theme-name").textContent = THEMES[t].name;
  try { localStorage.setItem("theme", t); } catch (e) { /* private mode */ }
}
$("theme-toggle").addEventListener("click", () => {
  const now = document.documentElement.getAttribute("data-theme") === "angel";
  applyTheme(now ? "devil" : "angel", { animate: true, notify: true });
});
// Swift calls this on load with the stored value; localStorage is only the
// fallback for the dev preview, where there is no bridge.
window.applyTheme = applyTheme;
try { applyTheme(localStorage.getItem("theme") || "devil"); } catch (e) { applyTheme("devil"); }

// ---- change tracking -------------------------------------------------------
// The run view re-renders on every log line. Animating entry unconditionally
// would flicker the whole list several times a second, so only genuinely new or
// changed content is marked.
const seenUIDs = new Set();
const deadUIDs = new Set();
let lastStats = {};
// The whole last push, kept because lastStats is a side-effect of RENDERING the six
// stat cards -- tear delay is computed but never drawn, so it is absent from there. A
// comparison table must read the data, not what the UI happened to paint.
let lastState = null;
let firstRender = true;
let lastSeed = null;

// ---- shared bits ---------------------------------------------------------
const STAT_ORDER = [
  ["damage", "Damage"],
  ["tears", "Tears"],
  ["range", "Range"],
  ["shotSpeed", "Shot speed"],
  ["speed", "Speed"],
  ["luck", "Luck"],
];

// "#" is EID's line separator and {{Icon}} its sprite markup.
const clean = (text) => (text || "").replace(/\{\{[^}]*\}\}/g, "").replace(/#/g, "\n").trim();

const CONFIDENCE_TITLE = {
  verified: "EID's typed data and its description text agree",
  crossChecked: "Present in both sources; only one carries numbers",
  singleSource: "Extracted from the description text only",
  conditional: "Real effect, but timed/triggered/conditional — no permanent number",
  nonNumeric: "Changes no stat",
};

function confidencePill(conf) {
  if (!conf || conf === "nonNumeric") return null;
  const pill = el("span", "pill " + conf, conf === "crossChecked" ? "cross-checked" : conf);
  pill.title = CONFIDENCE_TITLE[conf] || "";
  return pill;
}

function deltaLine(item) {
  const parts = Object.entries(item.delta || {}).map(([k, v]) => {
    if (k.endsWith(" x")) return `${k.slice(0, -2)} ×${v}`;
    return `${k} ${v > 0 ? "+" : ""}${v}`;
  });
  if (item.shots) parts.push(`+${item.shots} shots`);
  return parts.join("   ");
}

// ---- run view ------------------------------------------------------------
// Damage is NOT base + sum-of-item-deltas: it runs through a square-root curve and
// multipliers. So the "+" shown is the stat's ACTUAL movement (total - base), which
// always reconciles on screen, rather than the raw inputs, which would not.
const NONLINEAR = {
  damage: "Damage runs through a square-root curve and multipliers, so the "
    + "contribution is the real effect on the stat, not the sum of the item numbers.",
  tears: "Tears come from tear delay, which is non-linear, so the contribution is "
    + "the real effect on the stat, not the sum of the item numbers.",
};

/* Decimal places come from the setting; rounding first keeps 2.675 from landing on
   2.67 through binary float, the way a bare toFixed would. */
const fmt = (n) => {
  const d = window.STAT_DECIMALS || 2;
  const p = Math.pow(10, d);
  return (Math.round(n * p) / p).toFixed(d);
};

function renderStats(state) {
  const box = $("stats");
  box.textContent = "";
  // With no run there is nothing measured, but the engine still happily returns a
  // character's base stats. Printing those would be indistinguishable from a real
  // readout, so the rail keeps its shape and says outright that it has no numbers.
  const live = state.gameRunning && state.hasRun;
  if (!live || !state.stats || !Object.keys(state.stats).length) {
    lastStats = {};
    for (const [, label] of STAT_ORDER) {
      const card = el("div", "stat pending");
      card.appendChild(el("div", "label", label));
      card.appendChild(el("div", "value", "\u2014"));
      card.appendChild(el("div", "meter flat"));
      card.appendChild(el("div", "breakdown",
        state.gameRunning ? "scanning\u2026" : "no game"));
      box.appendChild(card);
    }
    const note = el("p", "empty");
    note.textContent = state.gameRunning
      ? "Game is running \u2014 waiting for a run to start. Items are picked up automatically."
      : state.hasRun
        ? "The game is closed. These are the items from your last session, kept for "
          + "reference \u2014 the stats are not being measured."
        : "Press Play to start the game. Nothing is measured until a run begins.";
    box.appendChild(note);
    return;
  }
  for (const [key, label] of STAT_ORDER) {
    const stat = state.stats[key];
    if (!stat) continue;
    // `hot` = your damage number, the one thing that gets the ember treatment.
    // `est` = the engine flagged this as order-dependent.
    const cls = ["stat", key === "damage" ? "hot" : "", stat.approx ? "est" : ""]
      .filter(Boolean).join(" ");
    const card = el("div", cls);
    const labelNode = el("div", "label");
    const glyph = hudIcon(key, 14);
    if (glyph) labelNode.appendChild(glyph);
    labelNode.appendChild(el("span", null, label));
    card.appendChild(labelNode);
    const valueNode = el("div", "value", (stat.approx ? "~" : "") + fmt(stat.value));
    if (!firstRender && lastStats[key] !== undefined
        && Math.abs(lastStats[key] - stat.value) > 0.005) {
      valueNode.classList.add("is-changed");
    }
    lastStats[key] = stat.value;
    card.appendChild(valueNode);

    // The meter is what you read without focusing: length is how far the items have
    // moved you from your character's base, colour is which direction.
    const delta = stat.fromItems;
    const denom = Math.abs(stat.base) > 0.001 ? Math.abs(stat.base) : 1;
    const pct = Math.max(0, Math.min(100, (Math.abs(delta) / denom) * 100));
    const meter = el("div", "meter " + (delta > 0.005 ? "up" : delta < -0.005 ? "down" : "flat"));
    const fill = el("i");
    fill.style.width = (Math.abs(delta) < 0.005 ? 0 : Math.max(5, pct)) + "%";
    meter.appendChild(fill);
    card.appendChild(meter);

    const parts = el("div", "breakdown");
    parts.appendChild(el("span", "base", fmt(stat.base)));
    if (Math.abs(delta) >= 0.005) {
      parts.appendChild(el("span", "op", delta > 0 ? "+" : "\u2212"));
      parts.appendChild(el("span", delta > 0 ? "up" : "down", fmt(Math.abs(delta))));
    } else {
      parts.appendChild(el("span", "muted", "unchanged"));
    }
    card.appendChild(parts);

    const notes = [stat.reason, NONLINEAR[key] && delta !== 0 ? NONLINEAR[key] : null]
      .filter(Boolean);
    if (notes.length) card.title = notes.join(" ");
    box.appendChild(card);
  }
  if (state.shots > 1) {
    const card = el("div", "stat");
    card.appendChild(el("div", "label", "Shots"));
    card.appendChild(el("div", "value", String(state.shots)));
    const meter = el("div", "meter up");
    const fill = el("i");
    fill.style.width = Math.min(100, (state.shots - 1) * 25) + "%";
    meter.appendChild(fill);
    card.appendChild(meter);
    const parts = el("div", "breakdown");
    parts.appendChild(el("span", "base", "1"));
    parts.appendChild(el("span", "op", "+"));
    parts.appendChild(el("span", "up", String(state.shots - 1)));
    card.appendChild(parts);
    box.appendChild(card);
  }
}

function heldRow(held) {
  const full = byKey.get(held.id + ":" + held.kind);
  const li = el("li");
  if (held.dead) li.classList.add("dead");
  if (!firstRender && !seenUIDs.has(held.uid)) li.classList.add("is-new");
  // An item that died since the last render draws its own strike-through.
  if (held.dead && !firstRender && seenUIDs.has(held.uid) && !deadUIDs.has(held.uid)) {
    li.classList.add("just-died");
  }
  seenUIDs.add(held.uid);
  if (held.dead) deadUIDs.add(held.uid); else deadUIDs.delete(held.uid);
  li.appendChild(sprite(held.gfx));

  const body = el("div", "grow");
  const head = el("div");
  head.appendChild(el("span", "name", held.name));
  const pill = confidencePill(held.confidence);
  if (pill) head.appendChild(pill);
  if (held.manual) head.appendChild(el("span", "pill manual", "manual"));
  body.appendChild(head);
  // The reason it is dead outranks its own description — that is the thing you
  // need, and the description is now mostly irrelevant.
  if (held.deadReason) body.appendChild(el("div", "desc cut", held.deadReason));
  const desc = clean(held.text);
  if (desc) body.appendChild(el("div", "desc", desc));
  if (full && full.pools && full.pools.length) {
    body.appendChild(
      el("div", "desc pools", "Pools: " + full.pools.map((p) => p.pool).join(", "))
    );
  }
  li.appendChild(body);

  const remove = el("button", "remove", "\u00d7");
  remove.title = "Remove (use after a reroll the log didn't record)";
  remove.addEventListener("click", () => send({ type: "manualRemove", uid: held.uid }));
  li.appendChild(remove);
  return li;
}

// Everything stays on one screen; the sections are headings, not tabs or panes. The
// point is being able to see the whole build at a glance.
function renderHeld(state) {
  const box = $("sections");
  box.textContent = "";
  $("count").textContent = state.items.length ? `(${state.items.length})` : "";

  const grouped = new Map();
  for (const held of state.items) {
    if (!grouped.has(held.section)) grouped.set(held.section, []);
    grouped.get(held.section).push(held);
  }

  for (const section of state.sections || []) {
    const rows = grouped.get(section.id) || [];
    // Manual-only sections stay visible when empty so their note explains why they
    // are empty; auto-tracked ones just disappear.
    const manualOnly = section.id === "trinkets" || section.id === "consumables";
    if (!rows.length && !manualOnly) continue;

    const group = el("section", "group");
    const head = el("div", "group-head");
    // Slotted sections show "1/2" so a widened slot is visible at a glance; the rest
    // just show how many you have.
    const slotted = section.capacity > 1 || manualOnly;
    head.appendChild(el("h3", null, section.title + (section.capacity > 1 ? "s" : "")));
    head.appendChild(
      el("span", "muted count", slotted ? `${rows.length}/${section.capacity}` : String(rows.length))
    );
    if (section.capacity > 1 && section.grantedBy && section.grantedBy.length) {
      const why = el("span", "slot-grant");
      why.textContent = `+1 slot from ${section.grantedBy.join(", ")}`;
      head.appendChild(why);
    }
    group.appendChild(head);
    if (section.note) group.appendChild(el("p", "muted small", section.note));

    if (!rows.length) {
      group.appendChild(el("p", "empty small", "Nothing recorded."));
    } else {
      const list = el("ul", "held");
      // Newest first within a section.
      for (const held of [...rows].reverse()) list.appendChild(heldRow(held));
      group.appendChild(list);
    }
    box.appendChild(group);
  }
}

// ---- verdicts ------------------------------------------------------------
const VERDICT_CLASS = {
  overridden: "bad",
  redundant: "bad",
  overrides: "good",
  synergy: "good",
  multishot: "neutral",
  transformation: "neutral",
  "transformation-complete": "good",
};

function renderVerdicts(box, item, verdicts) {
  box.textContent = "";
  const head = el("div", "detail-head");
  head.appendChild(sprite(item.gfx, 2));
  const titles = el("div", "grow");
  titles.appendChild(el("h3", null, item.name));
  const desc = clean(item.text);
  if (desc) titles.appendChild(el("div", "desc", desc));
  head.appendChild(titles);
  box.appendChild(head);

  if (!verdicts.length) {
    box.appendChild(el("p", "muted", "No interactions with what you're carrying."));
    return;
  }
  const list = el("ul", "verdicts");
  for (const v of verdicts) {
    const li = el("li", VERDICT_CLASS[v.kind] || "neutral");
    li.appendChild(el("span", "dot"));
    li.appendChild(el("span", null, v.text));
    list.appendChild(li);
  }
  box.appendChild(list);
}

$("scan").addEventListener("click", () => {
  $("scan-status").textContent = "Looking at the game window…";
  send({ type: "scanRoom" });
});

window.onScan = (result) => {
  const status = $("scan-status");
  if (result.error) {
    status.textContent = result.error;
    return;
  }
  if (!result.matches.length) {
    status.textContent = "Couldn't identify the pedestal — type the name instead.";
    return;
  }
  // Confidence is shown rather than hidden: a shaky match should look shaky.
  const best = result.matches[0];
  const item = catalogue.find((i) => i.id === best.id && ["passive", "active", "familiar"].includes(i.kind));
  if (!item) {
    status.textContent = "Matched an unknown item.";
    return;
  }
  status.textContent =
    `Read "${item.name}" off the screen (${Math.round(best.confidence * 100)}% match)` +
    (result.matches.length > 1 ? ` · ${result.matches.length} pedestals` : "");
  pendingCheck = item;
  send({ type: "verdicts", id: item.id, kind: item.kind });
};

let pendingCheck = null;
$("check").addEventListener("change", (e) => {
  const name = e.target.value.trim().toLowerCase();
  const match = catalogue.find((i) => i.kind !== "trinket" && i.name.toLowerCase() === name);
  const box = $("check-result");
  if (!match) {
    // Clear the pending target too, or a later reply repopulates a box the user
    // deliberately emptied.
    pendingCheck = null;
    box.textContent = "";
    $("scan-status").textContent = "";
    return;
  }
  pendingCheck = match;
  send({ type: "verdicts", id: match.id, kind: match.kind });
  send({ type: "reroll", id: match.id });
});

window.onReroll = (advice) => {
  const box = $("reroll");
  box.textContent = "";
  if (!advice) return;

  const pct = (n) => (n > 0 ? "+" : "") + n.toFixed(1) + "%";
  const line = el("p", "note");
  line.appendChild(el("span", "label-inline", `${advice.pool} pool · `));
  line.appendChild(el("span", null, `${advice.poolSize} items left, a re-roll averages `));
  line.appendChild(el("span", advice.expectedGain > 0 ? "up" : "down", pct(advice.expectedGain)));
  line.appendChild(el("span", null, " DPS"));
  box.appendChild(line);

  if (advice.candidate) {
    const c = advice.candidate;
    const verdict = el("p", "note");
    if (!c.scorable) {
      // Weapon replacers cannot be scored on stats — saying "re-roll Brimstone"
      // because its recorded delta is a tears downgrade would be actively wrong.
      verdict.classList.add("bad");
      verdict.appendChild(el("span", "strong", c.name));
      verdict.appendChild(
        el("span", null, " replaces your shot, so a DPS score can't rank it — judge it yourself.")
      );
    } else {
      verdict.appendChild(el("span", "strong", c.name));
      verdict.appendChild(el("span", null, " is "));
      verdict.appendChild(el("span", c.gain > 0 ? "up" : "down", pct(c.gain)));
      verdict.appendChild(
        el("span", null, advice.rerollLooksBetter ? " — a re-roll averages better" : " — better than average, keep it")
      );
    }
    box.appendChild(verdict);
  }

  if (advice.best && advice.best.length) {
    const best = el("p", "note");
    best.appendChild(el("span", "label-inline", "Best left: "));
    best.appendChild(el("span", null, advice.best.map((b) => `${b.name} ${pct(b.gain)}`).join("   ")));
    box.appendChild(best);
  }

  const caveat = el("p", "muted small");
  caveat.textContent =
    `DPS-only score, covering ${advice.coverage}% of the pool by weight — ` +
    "items that replace your shot are excluded rather than mis-ranked.";
  box.appendChild(caveat);
};

window.onVerdicts = (id, verdicts) => {
  // Two consumers: the pedestal check on the run tab and the open item card.
  if (pendingCheck && pendingCheck.id === id) {
    renderVerdicts($("check-result"), pendingCheck, verdicts);
  }
  if (detailItem && detailItem.id === id) {
    const box = $("detail-verdicts");
    if (box) {
      box.textContent = "";
      if (verdicts.length) {
        box.appendChild(el("h4", null, "With your current run"));
        const list = el("ul", "verdicts");
        for (const v of verdicts) {
          const li = el("li", VERDICT_CLASS[v.kind] || "neutral");
          li.appendChild(el("span", "dot"));
          li.appendChild(el("span", null, v.text));
          list.appendChild(li);
        }
        box.appendChild(list);
      }
    }
  }
};

function renderBuildNotes(state) {
  const box = $("build-notes");
  box.textContent = "";

  if (state.activeWeapon) {
    const line = el("p", "note");
    line.appendChild(el("span", "label-inline", "Firing: "));
    line.appendChild(el("span", "strong", state.activeWeapon));
    box.appendChild(line);
  }

  for (const c of state.conflicts || []) {
    const line = el("p", "note bad");
    line.appendChild(el("span", "dot"));
    line.appendChild(el("span", "strong", c.item));
    line.appendChild(el("span", null, " — " + c.text));
    box.appendChild(line);
  }

  if (state.bosses && state.bosses.length) {
    const line = el("p", "note");
    line.appendChild(el("span", "label-inline", "Bosses: "));
    line.appendChild(el("span", null, state.bosses.join("   ")));
    box.appendChild(line);
  }

  // The run is over. This is the one thing you want to know afterwards.
  if (state.death) {
    const line = el("p", "note bad");
    line.appendChild(el("span", "label-inline", "Died to: "));
    line.appendChild(el("span", "strong", state.death));
    box.appendChild(line);
  }

  const active = (state.transformations || []).filter((t) => t.have > 0);
  if (active.length) {
    const line = el("p", "note");
    line.appendChild(el("span", "label-inline", "Transformations: "));
    line.appendChild(
      el(
        "span",
        null,
        active.map((t) => `${t.name} ${t.have}/${t.need}`).join("   ")
      )
    );
    box.appendChild(line);
  }
}

window.onState = (state) => {
  lastState = state;
  // Every character has non-zero base stats, so rendering them with no run in
  // progress prints a plausible-looking readout of nothing. Only claim a character
  // once the log has actually named one.
  const liveRun = state.gameRunning && state.hasRun;
  $("character").textContent = liveRun ? (state.character || "\u2014")
    : state.gameRunning ? "Waiting for a run"
    : state.hasRun ? (state.character || "\u2014") : "No run yet";
  $("seed").textContent = !state.seed
    ? (state.gameRunning ? "watching the log" : "start the game to begin tracking")
    : liveRun ? "seed " + state.seed
    : "last session \u00b7 seed " + state.seed;
  // Stage survives a log rewrite; showing it with no run reads as a live position.
  // The separator belongs to the floor, not the markup: with no floor to show, a
  // literal " · " in the HTML leaves a dangling bullet.
  $("floor").textContent = liveRun && state.stage ? " \u00b7 floor " + state.stage : "";
  $("curses").textContent = (state.curses || []).length
    ? " \u00b7 " + state.curses.join(" \u00b7 ") : "";
  $("flight").hidden = !state.flight;

  const warn = $("char-warning");
  // The warning is about the character's numbers; with no run there are none.
  if (liveRun && state.characterUnverified && state.characterUnverified.length) {
    warn.textContent =
      "Unverified base stats for this character (" +
      state.characterUnverified.join(", ") +
      "). Numbers below may be off until they're checked against the in-game HUD." +
      (state.characterNotes ? " " + state.characterNotes : "");
    warn.classList.remove("hidden");
  } else {
    warn.classList.add("hidden");
  }

  const live = $("live");
  live.textContent = !state.gameRunning ? "game not running"
    : state.hasRun ? "live" : "scanning\u2026";
  live.classList.toggle("on", !!(state.gameRunning && state.hasRun));
  live.classList.toggle("scanning", !!(state.gameRunning && !state.hasRun));

  $("play").textContent = state.gameRunning ? "Game running" : "Play";
  $("play").classList.toggle("on", !!state.gameRunning);

  const lerr = $("launch-error");
  lerr.textContent = state.launchError || "";
  lerr.classList.toggle("hidden", !state.launchError);

  const room = $("roomtag");
  if (state.roomOffersChoice) {
    room.textContent = state.room + (state.pedestals ? ` · ${state.pedestals} pedestal(s)` : "");
    room.classList.remove("hidden");
    room.classList.add("choice");
  } else {
    room.classList.add("hidden");
  }

  $("warnings").textContent = (state.warnings || []).join("  ·  ");
  // A new seed is a new run: forget what we had seen so the next build animates in.
  if (state.seed !== lastSeed) {
    seenUIDs.clear();
    deadUIDs.clear();
    lastStats = {};
    firstRender = true;
    lastSeed = state.seed;
  }

  renderBuildNotes(state);
  if (state.roomOffersChoice) send({ type: "reroll", id: null });
  else $("reroll").textContent = "";
  // Verdicts are relative to the build, so a pickup makes any open panel stale.
  // Re-ask for whatever is currently on screen.
  if (pendingCheck) send({ type: "verdicts", id: pendingCheck.id, kind: pendingCheck.kind });
  if (detailItem) send({ type: "verdicts", id: detailItem.id, kind: detailItem.kind });
  renderStats(state);
  renderHeld(state);
  firstRender = false;
  // Keep the HUD comparison in step with the live numbers.
  if (verifyOn) renderVerify();
};

// ---- manual add ----------------------------------------------------------
const KIND_LABEL = { trinket: "trinket", card: "card", pill: "pill" };
let addableByLabel = new Map();

$("add").addEventListener("change", (e) => {
  const typed = e.target.value.trim().toLowerCase();
  const match =
    addableByLabel.get(typed) ||
    // Bare name typed without the "(card)" suffix: prefer a collectible, since that
    // is what the datalist shows unsuffixed.
    catalogue.find((i) => i.kind !== "trinket" && !KIND_LABEL[i.kind] && i.name.toLowerCase() === typed);
  if (match) {
    send({ type: "manualAdd", id: match.id, kind: match.kind });
    e.target.value = "";
  }
});

// ---- the index card --------------------------------------------------------
// One overlay reused for items, enemies and achievements. It sits over the page
// without touching the document flow, so the list behind it stays exactly where you
// scrolled to -- which is the whole point. The old panel rendered ABOVE the list and
// called scrollIntoView, which is what yanked you back to the top.
//
// This is deliberately NOT a <dialog>/showModal(). That version worked, but tearing
// down WebKit's top layer left the view with a stale frame: the next tab click
// updated the DOM and never repainted, so the old page stayed on screen with two
// tabs looking active. A plain fixed overlay has no top layer to tear down.
/* The open card wears the item's own effect as a living backdrop -- but only when the
   item genuinely has one, so the background is information rather than decoration.
   Turning animated backgrounds off keeps the backdrop and just stops it moving. */
/* ============================================================================
   fxZoomInto(sourceEl, targetEl) — the row's icon travels into the card.

   FLIP, in the smallest form that works: measure the row sprite, measure the
   card sprite, put one throwaway node in flight between them, delete it. The
   row and the card are never transformed, so this cannot disturb either layout;
   the only state it touches is the target's inline `visibility`, and that is
   restored on every exit path.

   The flyer is built at the TARGET's size and scaled DOWN to the row's size,
   never the other way round. A raster made at 28px and blown up to 128px is
   smeared whatever image-rendering says — rasterise at the big size and the
   frame it finally lands on is pixel-exact against the sprite it replaces.
   ========================================================================== */
var fxZoomInto = (function () {
  "use strict";

  var DUR  = 340;                          /* ~1.7x --t: long enough to read as travel */
  var EASE = "cubic-bezier(.2,.8,.2,1)";   /* --ease, spelled out: element.animate()
                                              cannot resolve a var() */
  /* Copied off the TARGET, not the source. The flyer has to be indistinguishable
     from the thing it becomes on the last frame or the hand-off blinks — and
     that includes image-rendering (badge sheets are line art, not pixel art)
     and the card sprite's own drop-shadows. */
  var COPY = ["backgroundImage", "backgroundSize", "backgroundPosition",
              "backgroundRepeat", "backgroundColor", "border", "borderRadius",
              "filter", "imageRendering"];

  var inFlight = null;   /* the one cleanup that may still be pending */

  function motionOff() {
    return window.FX_ANIM_ON === false
      || document.documentElement.getAttribute("data-fx-anim") === "off"
      || (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function zoom(sourceEl, targetEl) {
    /* A second click lands the first flight immediately. Two flyers arguing
       over one target's visibility is how you get a sprite that never comes
       back — and the loser would be the one that restores it. */
    if (inFlight) inFlight();

    if (!sourceEl || !targetEl || !targetEl.isConnected) return Promise.resolve();
    if (!targetEl.animate || motionOff()) return Promise.resolve();

    var to   = targetEl.getBoundingClientRect();
    var from = sourceEl.getBoundingClientRect();
    /* Zero size means the card is still display:none (measured too early) or the
       sheet never loaded. Either way there is nothing to fly to. */
    if (!to.width || !to.height || !from.width || !from.height) return Promise.resolve();

    /* A modal <dialog> lives in the top layer: nothing outside it paints over it
       at any z-index, so the flyer must be parented inside the dialog itself.
       Everywhere else document.body is the safe parent — the app's #card carries
       a backdrop-filter, which makes it the containing block for a fixed child
       and would drag the flyer around with the overlay. */
    var host = (targetEl.closest && targetEl.closest("dialog")) || document.body;
    var dlg  = host.tagName === "DIALOG" ? host : null;

    var fly = document.createElement("div");
    fly.className = "fx-flyer";
    var cs = getComputedStyle(targetEl);
    for (var i = 0; i < COPY.length; i++) if (cs[COPY[i]]) fly.style[COPY[i]] = cs[COPY[i]];
    fly.style.width  = to.width + "px";
    fly.style.height = to.height + "px";
    host.appendChild(fly);

    /* Where does an untransformed fixed child of this host actually sit, and is
       anything above it scaling? Measuring beats assuming: one transformed
       ancestor would silently offset every landing, and the bug would only show
       up on whichever surface grew the transform. k is 1 in the common case. */
    var base = fly.getBoundingClientRect();
    var k  = base.width / to.width || 1;
    var x0 = (from.left - base.left) / k, y0 = (from.top - base.top) / k;
    var x1 = (to.left   - base.left) / k, y1 = (to.top   - base.top) / k;
    var s0 = from.width / to.width / k,   s1 = 1 / k;

    /* A straight line between two boxes reads as a slide; a shallow arc reads as
       something being carried. Capped, so a short hop stays flat. */
    var lift = Math.min(26, Math.hypot(x1 - x0, y1 - y0) * 0.09);
    function tf(x, y, s) {
      return "translate(" + x + "px," + y + "px) scale(" + s + ")";
    }

    var prev = targetEl.style.visibility;
    targetEl.style.visibility = "hidden";   /* the flyer IS the sprite until it lands */

    /* The middle keyframe carries the arc only: its scale is the exact midpoint
       of the other two, so the size ramp is identical to a two-frame animation
       and the eased timing stays smooth across the join. */
    var anim = fly.animate([
      { transform: tf(x0, y0, s0), opacity: 0.82 },
      { transform: tf((x0 + x1) / 2, (y0 + y1) / 2 - lift, (s0 + s1) / 2),
        opacity: 1, offset: 0.5 },
      { transform: tf(x1, y1, s1), opacity: 1 }
    ], { duration: DUR, easing: EASE, fill: "both" });

    return new Promise(function (resolve) {
      var timer = 0, done = false;

      function cleanup() {
        if (done) return;                    /* every exit funnels here exactly once */
        done = true;
        clearTimeout(timer);
        if (inFlight === cleanup) inFlight = null;
        if (dlg) dlg.removeEventListener("close", cleanup);
        anim.cancel();                       /* a detached node keeps animating otherwise */
        fly.remove();
        targetEl.style.visibility = prev;    /* harmless if the card was rebuilt under us */
        resolve();
      }

      inFlight = cleanup;
      /* A backgrounded tab freezes the document timeline, so onfinish may never
         arrive. This timer is the guarantee that no flyer outlives its flight. */
      timer = setTimeout(cleanup, DUR + 500);
      anim.onfinish = cleanup;
      anim.oncancel = cleanup;
      /* Closing a <dialog> mid-flight: the flyer is inside it, so it would be
         torn out of the top layer and stranded. */
      if (dlg) dlg.addEventListener("close", cleanup);
    });
  }

  /* For surfaces with no `close` event of their own (the app's plain overlay). */
  zoom.cancel = function () { if (inFlight) inFlight(); };

  return zoom;
})();
window.fxZoomInto = fxZoomInto;

function fxDressCard(split, subject) {
  const panel = document.querySelector("#card .cardpanel");
  if (!panel) return;
  panel.classList.add("fxbg");
  if (subject) fxItemVars(panel, subject);
  panel.classList.toggle("no-bg-anim", window.FX_BG_ON === false);
  if (split && split.real.length && window.FX_EFF_ON !== false)
    panel.dataset.effReal = FX_FAMILY[split.real[0]] || "blood";
  else panel.removeAttribute("data-eff-real");
}

function openCard(build) {
  const box = $("cardbody");
  box.textContent = "";
  build(box);
  $("card").hidden = false;
  box.scrollTop = 0;
  // The row's icon travels into the card and becomes the big sprite.
  fxZoomInto(window.fxFrom, box.querySelector(".detail-head .sprite"));
  window.fxFrom = null;
}
function closeCard() {
  $("card").hidden = true;
  detailItem = null;
}
$("cardx").addEventListener("click", closeCard);
// Clicking the backdrop closes; clicking inside the card must not. The target is the
// wrapper itself only when the click landed outside the panel.
$("card").addEventListener("click", (e) => { if (e.target.id === "card") closeCard(); });
// showModal() gave Escape for free; a plain overlay has to handle it.
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("card").hidden) { e.preventDefault(); closeCard(); }
});

// ---- browser -------------------------------------------------------------
let detailItem = null;

function showDetail(item) {
  openCard((box) => buildItemCard(box, item));
}

function buildItemCard(box, item) {
  detailItem = item;
  fxDressCard(fxFor(item.name, item.text + " " + item.kind), item);
  const head = el("div", "detail-head");
  head.appendChild(sprite(item.gfx, 4));
  const titles = el("div", "grow");
  const h = el("h3", null, item.name);
  titles.appendChild(h);
  const tags = el("div", "tagrow");
  tags.appendChild(el("span", "pill", item.kind));
  tags.appendChild(el("span", "pill", "#" + item.id));
  if (item.special) {
    const p = el("span", "pill", "special");
    p.title = "Flagged `special` in items.xml — AB+'s only in-game item flag. "
      + "AB+ has no item quality; that is a Repentance concept.";
    tags.appendChild(p);
  }
  if (item.maxCharges) tags.appendChild(el("span", "pill", item.maxCharges + " charges"));
  if (item.devilPrice) tags.appendChild(el("span", "pill", item.devilPrice + " heart(s)"));
  const pill = confidencePill(item.confidence);
  if (pill) tags.appendChild(pill);
  titles.appendChild(tags);
  head.appendChild(titles);
  box.appendChild(head);

  const desc = clean(item.text);
  if (desc) box.appendChild(el("p", "desc", desc));

  const deltas = deltaLine(item);
  if (deltas) {
    box.appendChild(el("h4", null, "Stat changes"));
    box.appendChild(el("p", "mono", deltas));
  } else if (item.confidence === "conditional") {
    box.appendChild(
      el("p", "warn", "No permanent stat change — this item's effect is timed, "
        + "triggered, or conditional, which is why the game still flags it as touching "
        + "these stats: " + (item.cache || []).join(", "))
    );
  }

  if (item.unlock) {
    box.appendChild(el("h4", null, "How you unlock it"));
    const u = el("p", item.unlockKnown ? "desc" : "desc cut", item.unlock);
    box.appendChild(u);
  }

  if (item.pools && item.pools.length) {
    box.appendChild(el("h4", null, "Item pools"));
    const table = el("table", "pools");
    for (const p of item.pools) {
      const tr = el("tr");
      tr.appendChild(el("td", null, p.pool));
      tr.appendChild(el("td", "num", "weight " + p.weight));
      table.appendChild(tr);
    }
    box.appendChild(table);
  } else if (item.kind !== "trinket") {
    box.appendChild(el("h4", null, "Item pools"));
    box.appendChild(el("p", "muted", "Not in any pool — unlocked or granted another way."));
  }

  const verdictBox = el("div");
  verdictBox.id = "detail-verdicts";
  box.appendChild(verdictBox);
  send({ type: "verdicts", id: item.id, kind: item.kind });
}

// ---- enemy card ------------------------------------------------------------
function showEnemy(e) {
  openCard((box) => {
    fxDressCard(fxForEnemy(e), e);
    const head = el("div", "detail-head");
    head.appendChild(icon("monsters", e.art, 1));
    const titles = el("div", "grow");
    titles.appendChild(el("h3", null, e.name));
    const tags = el("div", "tagrow");
    if (e.isBoss && e.fightable) tags.appendChild(el("span", "pill conditional", "boss"));
    if (!e.fightable) {
      const p = el("span", "pill", "not an enemy");
      p.title = "An effect, pickup, familiar or projectile — listed so the numbers in "
        + "a log line can be looked up, but not something you fight.";
      tags.appendChild(p);
    }
    tags.appendChild(el("span", "pill", `${e.type}.${e.variant}`));
    titles.appendChild(tags);
    head.appendChild(titles);
    box.appendChild(head);

    box.appendChild(el("h4", null, "Health"));
    // stageHP is added per floor, so baseHP alone is not what you actually fight.
    box.appendChild(el("p", "mono", e.stageHP > 0
      ? `${e.hp} base, +${e.stageHP} per floor`
      : `${e.hp}`));
    if (e.stageHP > 0) {
      box.appendChild(el("p", "muted",
        `On floor 5 that is ${e.hp + e.stageHP * 4} HP.`));
    }

    box.appendChild(el("h4", null, "Room clear"));
    box.appendChild(el("p", "desc", e.blocksClear
      ? "Holds the doors shut — the room is not clear until it is dead."
      : "Does not hold the doors shut. Clearing the room ignores it."));

    if (e.colors && e.colors.length) {
      box.appendChild(el("h4", null, "Colours"));
      box.appendChild(el("p", "desc pools", e.colors.join(", ")));
      box.appendChild(el("p", "muted",
        "Measured from the sprite's own pixels — nothing in the game files "
        + "describes what an enemy looks like."));
    }
  });
}

// ---- achievement card ------------------------------------------------------
function showAchievement(a) {
  openCard((box) => {
    fxDressCard(null);
    const head = el("div", "detail-head");
    head.appendChild(icon("achievements", a.gfx, 1, "badge-art"));
    const titles = el("div", "grow");
    titles.appendChild(el("h3", null, a.name));
    const tags = el("div", "tagrow");
    tags.appendChild(el("span", "pill " + (a.unlocked ? "verified" : ""),
      a.unlocked ? "unlocked" : "locked"));
    tags.appendChild(el("span", "pill", "#" + a.id));
    titles.appendChild(tags);
    head.appendChild(titles);
    box.appendChild(head);

    box.appendChild(el("h4", null, "How you get it"));
    box.appendChild(el("p", a.known ? "desc" : "desc cut", a.condition));

    if (a.unlocks.length) {
      box.appendChild(el("h4", null, "What it gives you"));
      box.appendChild(el("p", "desc pools", a.unlocks.join(", ")));
    }

    // a.pinned matters even when unlocked: pin something, unlock it, and the card
    // still needs to offer the way out.
    if (!a.unlocked || a.pinned) {
      const btn = el("button", "ghost", a.pinned ? "Stop tracking this" : "Track this one");
      btn.addEventListener("click", () => {
        send({ type: "pin", id: a.pinned ? null : a.id });
        closeCard();
      });
      box.appendChild(el("h4", null, "Tracking"));
      box.appendChild(btn);
    }
  });
}

function renderResults() {
  const q = $("q").value.trim().toLowerCase();
  const kind = $("kind").value;
  const stat = $("stat").value;
  const pool = $("pool").value;

  const matches = catalogue.filter((item) => {
    if (kind && item.kind !== kind) return false;
    if (stat && !(item.cache || []).includes(stat)) return false;
    if (pool && !(item.pools || []).some((p) => p.pool === pool)) return false;
    if (!q) return true;
    if (item.name.toLowerCase().includes(q) || String(item.id) === q) return true;
    // Opt-in, because matching every description turns a two-letter query into
    // half the catalogue and the name match is what people actually want.
    return !!window.SEARCH_TEXT && (item.text || "").toLowerCase().includes(q);
  });

  $("browse-count").textContent = `${matches.length} of ${catalogue.length} items`;
  const list = $("results");
  if (!matches.length) {
    pagers.get(list)?.disconnect();
    list.textContent = "";
    list.appendChild(el("li", "empty", "Nothing matches."));
    return;
  }
  paginate(list, Sort.apply("#isort", matches), (item) => {
    const li = el("li");
    fxApply(li, fxFor(item.name, item.text + " " + item.kind));
    fxItemVars(li, item);
    fxIdleVar(li, item.name);
    fxHoverBind(li);
    li.classList.add("clickable");
    li.appendChild(sprite(item.gfx));
    const body = el("div", "grow");
    const head = el("div");
    head.appendChild(el("span", "name", item.name));
    head.appendChild(el("span", "pill", item.kind));
    if (item.special) head.appendChild(el("span", "pill", "special"));
    const pill = confidencePill(item.confidence);
    if (pill) head.appendChild(pill);
    body.appendChild(head);
    const deltas = deltaLine(item);
    if (deltas) body.appendChild(el("div", "desc mono", deltas));
    const desc = clean(item.text);
    if (desc) body.appendChild(el("div", "desc", desc));
    li.appendChild(body);
    li.addEventListener("click", () => { window.fxFrom = li.querySelector(".sprite"); showDetail(item); });
    return li;
  });
}

["q", "kind", "stat", "pool", "isort"].forEach((id) => {
  const el = $(id); if (el) el.addEventListener("input", renderResults);
});

window.onCatalogue = (rows) => {
  setTimeout(() => window.fxPaintMenu && window.fxPaintMenu(), 0);
  catalogue = rows;
  byKey = new Map(rows.map((r) => [r.id + ":" + r.kind, r]));

  const datalist = $("allitems");
  datalist.textContent = "";
  for (const item of rows) {
    if (!["passive", "active", "familiar"].includes(item.kind)) continue;
    const opt = el("option");
    opt.value = item.name;
    datalist.appendChild(opt);
  }

  const addable = $("alladdable");
  addable.textContent = "";
  addableByLabel = new Map();
  for (const item of rows) {
    // Suffix non-collectibles so "The Fool" the card is distinguishable from a
    // collectible of the same name, and so the kind survives the round trip.
    const label = KIND_LABEL[item.kind] ? `${item.name} (${KIND_LABEL[item.kind]})` : item.name;
    addableByLabel.set(label.toLowerCase(), item);
    const opt = el("option");
    opt.value = label;
    addable.appendChild(opt);
  }

  // Pool list comes from the data, not a hardcoded list — AB+ has exactly 26 and
  // hardcoding them would be one more place to drift from the game.
  const pools = [...new Set(rows.flatMap((r) => (r.pools || []).map((p) => p.pool)))].sort();
  const select = $("pool");
  for (const name of pools) {
    const opt = el("option");
    opt.value = name;
    opt.textContent = name;
    select.appendChild(opt);
  }

  renderResults();
};

// ---- settings ------------------------------------------------------------
// Two switches, two keys, no shared state: turning one off must leave the other
// exactly where it was. Reduced motion decides the DEFAULT for both, but a choice
// the user has actually made always wins over it.
/* The four motion switches used to be wired here, from two different mechanisms
   reading two different localStorage key formats. They are now entries in the
   SETTINGS list at the end of this file, which owns loading, applying and
   persisting all of them -- one source of truth instead of three.

   Reduced motion still decides the DEFAULT, and a choice the user actually made
   still wins over it; that logic moved into settingsBoot's defaults. */
function fxPrefOn(key) {
  let v = null;
  try { v = localStorage.getItem("set." + key); } catch (e) { /* private mode */ }
  if (v === "true") return true;
  if (v === "false") return false;
  return !matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/* ===== Items tab dropdown — shared by site + app ===== */
(function () {
  'use strict';

  var GRACE = 160;            // ms of forgiveness after pointer leaves
  var navigating = false;     // reentrancy guard around tab.click()

  /* ---------------------------------------------------------------
   * THE ONE FUNCTION YOU POINT AT EACH RENDERER.
   * kind is "" | passive | active | familiar | trinket | card | pill
   * Both branches are guarded, so either surface may be absent.
   * ------------------------------------------------------------- */
  function applyKind(kind) {
    // --- APP: <select id="kind"> + renderResults() ---
    var sel = document.getElementById('kind');
    if (sel && sel.tagName === 'SELECT') {
      sel.value = kind;
      if (typeof window.renderResults === 'function') window.renderResults();
      else sel.dispatchEvent(new Event('change', { bubbles: true }));
    }
    // --- SITE: a filter variable + render() ---
    // Change `window.kindFilter` to whatever render() actually reads.
    if (typeof window.render === 'function') {
      window.kindFilter = kind;
      window.render();
    }
  }

  /* Switch to the Items view using whatever the surface already has. */
  function goItems(tab) {
    if (typeof window.show === 'function' && tab.dataset.v) { window.show(tab.dataset.v); return; }
    if (typeof window.showTab === 'function' && tab.dataset.tab) { window.showTab(tab.dataset.tab); return; }
    if (typeof window.switchTab === 'function' && tab.dataset.tab) { window.switchTab(tab.dataset.tab); return; }
    navigating = true;                       // fall back to the tab's own handler
    try { tab.click(); } finally { navigating = false; }
  }

  /* Counts. Auto-derives from an array of items with .kind, if it can find one.
     Override at any time with ItemsMenu.setCounts({passive:196, ...}). */
  function findData() {
    var c = [window.ITEMS_MENU_DATA, window.ITEMS, window.items, window.ALL_ITEMS,
             window.DATA && window.DATA.items];
    for (var i = 0; i < c.length; i++) if (Array.isArray(c[i])) return c[i];
    return null;
  }
  var manualCounts = null;
  function counts() {
    if (manualCounts) return manualCounts;
    var d = findData();
    if (!d) return null;
    var out = { '': d.length };
    for (var i = 0; i < d.length; i++) {
      var k = d[i] && d[i].kind;
      if (k) out[k] = (out[k] || 0) + 1;
    }
    return out;
  }

  var menus = [];

  function build(wrap) {
    var tab = wrap.querySelector('.tab');
    var menu = wrap.querySelector('.tabmenu');
    if (!tab || !menu) return;
    var items = Array.prototype.slice.call(menu.querySelectorAll('.tabmenu-i'));
    var navEl = wrap.closest('nav') || wrap.parentElement;
    var timer = null, coarse = false, open = false;

    function paintCounts() {
      var c = counts();
      items.forEach(function (it) {
        var n = it.querySelector('[data-count]');
        if (!n) return;
        var v = c ? c[it.dataset.kind] : undefined;
        n.textContent = (typeof v === 'number') ? String(v) : '';
      });
    }

    function markCurrent(kind) {
      items.forEach(function (it) {
        if (it.dataset.kind === kind) it.setAttribute('aria-current', 'true');
        else it.removeAttribute('aria-current');
      });
    }

    function show() {
      clearTimeout(timer);
      if (open) return;
      open = true;
      paintCounts();
      menu.classList.add('open');
      tab.setAttribute('aria-expanded', 'true');
      if (navEl) navEl.classList.add('menu-open');
    }

    function hide(refocus) {
      clearTimeout(timer);
      if (!open) { if (refocus) tab.focus(); return; }
      open = false;
      menu.classList.remove('open');
      tab.setAttribute('aria-expanded', 'false');
      if (navEl) navEl.classList.remove('menu-open');
      items.forEach(function (i) { i.classList.remove('here'); });
      if (refocus) tab.focus();
    }

    function scheduleHide() {
      clearTimeout(timer);
      timer = setTimeout(function () {
        if (wrap.contains(document.activeElement) && document.activeElement !== document.body) return;
        hide(false);
      }, GRACE);
    }

    function focusItem(i) {
      if (!items.length) return;
      var n = (i + items.length) % items.length;
      items.forEach(function (el) { el.classList.remove('here'); });
      items[n].classList.add('here');
      items[n].focus();
    }
    function indexOfActive() { return items.indexOf(document.activeElement); }

    function choose(it, viaKeyboard) {
      goItems(tab);
      applyKind(it.dataset.kind);
      markCurrent(it.dataset.kind);
      hide(!!viaKeyboard);
    }

    /* --- pointer: mouse hovers, touch never enters a hover state --- */
    wrap.addEventListener('pointerdown', function (e) {
      coarse = e.pointerType !== 'mouse';
      if (coarse) hide(false);                 // a tap just navigates
    });
    wrap.addEventListener('pointerenter', function (e) {
      if (e.pointerType && e.pointerType !== 'mouse') return;
      coarse = false;
      show();
    });
    wrap.addEventListener('pointermove', function (e) {
      if (e.pointerType && e.pointerType !== 'mouse') return;
      clearTimeout(timer);
    });
    wrap.addEventListener('pointerleave', function (e) {
      if (e.pointerType && e.pointerType !== 'mouse') return;
      scheduleHide();
    });

    /* --- plain click on the tab still just navigates --- */
    tab.addEventListener('click', function () {
      if (navigating) return;
      hide(false);                             // its own handler does the switching
    });

    /* --- keyboard entry: focusing the tab opens the menu --- */
    tab.addEventListener('focus', function () {
      if (coarse) return;
      var fv = true;
      try { fv = tab.matches(':focus-visible'); } catch (err) { fv = true; }
      if (fv) show();
    });

    wrap.addEventListener('focusout', function (e) {
      if (!wrap.contains(e.relatedTarget)) hide(false);
    });

    wrap.addEventListener('keydown', function (e) {
      var k = e.key;
      if (k === 'Escape' || k === 'Esc') {
        if (open) { e.preventDefault(); e.stopPropagation(); hide(true); }
        return;
      }
      if (k === 'Tab') { hide(false); return; }

      if (e.target === tab) {
        if (k === 'ArrowDown' || k === 'Down') { e.preventDefault(); show(); focusItem(0); }
        else if (k === 'ArrowUp' || k === 'Up') { e.preventDefault(); show(); focusItem(items.length - 1); }
        return;
      }

      var i = indexOfActive();
      if (i < 0) return;
      if (k === 'ArrowDown' || k === 'Down') { e.preventDefault(); focusItem(i + 1); }
      else if (k === 'ArrowUp' || k === 'Up') { e.preventDefault(); focusItem(i - 1); }
      else if (k === 'Home') { e.preventDefault(); focusItem(0); }
      else if (k === 'End') { e.preventDefault(); focusItem(items.length - 1); }
      else if (k === 'ArrowLeft' || k === 'Left' || k === 'ArrowRight' || k === 'Right') { e.preventDefault(); hide(true); }
      else if (k === 'Enter' || k === ' ' || k === 'Spacebar') { e.preventDefault(); choose(items[i], true); }
    });

    items.forEach(function (it) {
      it.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        choose(it, false);
      });
      it.addEventListener('mouseenter', function () {
        items.forEach(function (el) { el.classList.remove('here'); });
      });
    });

    paintCounts();
    menus.push({ wrap: wrap, hide: hide, paintCounts: paintCounts, markCurrent: markCurrent });
  }

  function init() {
    document.querySelectorAll('.tabwrap[data-menu="items"]').forEach(build);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  window.ItemsMenu = {
    // ItemsMenu.setCounts({'':508, passive:341, active:56, ...}) — pass null to auto-derive
    setCounts: function (c) { manualCounts = c || null; menus.forEach(function (m) { m.paintCounts(); }); },
    refresh: function () { menus.forEach(function (m) { m.paintCounts(); }); },
    // call after the user changes the kind filter elsewhere, to keep the dot in sync
    sync: function (kind) { menus.forEach(function (m) { m.markCurrent(kind || ''); }); },
    closeAll: function () { menus.forEach(function (m) { m.hide(false); }); },
    applyKind: applyKind
  };
})();

/* Menu icons and counts come from the catalogue, so they can never drift from what
   the list actually shows. One representative sprite per kind. */
(function menuIcons(){
  const PICK = { "": "The D6", passive: "The Sad Onion", active: "The Bible",
    familiar: "Brother Bobby", trinket: "Swallowed Penny",
    card: "0 - The Fool", pill: "Bad Gas" };
  function paint(){
    if (!catalogue.length || !atlas) return;
    const counts = {};
    for (const it of catalogue) counts[it.kind] = (counts[it.kind] || 0) + 1;
    counts[""] = catalogue.length;
    document.querySelectorAll(".tabmenu-i").forEach((b) => {
      const kind = b.dataset.kind || "";
      const n = b.querySelector(".tabmenu-n");
      if (n) n.textContent = counts[kind] != null ? counts[kind] : "";
      const el = b.querySelector(".tabmenu-ic");
      const src = catalogue.find((i) => i.name === PICK[kind])
        || catalogue.find((i) => i.kind === kind);
      const frame = src && atlas.frames[(src.gfx || "").toLowerCase()];
      if (!el || !frame) return;
      el.style.backgroundImage = `url(${atlas.uri})`;
      el.style.backgroundSize = `${atlas.width}px ${atlas.height}px`;
      el.style.backgroundPosition = `-${frame[0]}px -${frame[1]}px`;
      el.style.imageRendering = "pixelated";
    });
  }
  window.fxPaintMenu = paint;
  paint();
})();

/* ============================================================================
   FLOATING PANEL SETTINGS

   Every other switch on this page owns its own value in localStorage. These do
   not: the panel is a native window, Swift persists it, and the page is only a
   view onto that. So the flow is one-directional in both directions --
   onPanelSettings paints the controls from Swift, and a change posts exactly
   one field back. Nothing here keeps a copy, which is why the panel and this
   page can never disagree about what is switched on.

   Sending one field rather than the whole object is deliberate: the page only
   knows about the controls it was built with, and shipping a whole object back
   would quietly reset any setting a newer panel had that this page did not.
   ========================================================================== */

const PANEL_UNIT = {
  "%": (v) => Math.round(v * 100) + "%",
  "px": (v) => Math.round(v) + "px",
  "x": (v) => (+v).toFixed(2) + "×",
  "": (v) => String(Math.round(v)),
};

function panelFormat(node, v) {
  return (PANEL_UNIT[node.dataset.unit] || String)(v);
}

window.onPanelSettings = (settings, screens) => {
  if (!settings) return;
  // The panel controls moved to their own tab; this used to mark #settings.
  const page = $("overlay");
  if (page) page.classList.toggle("ct-on", !!settings.clickThrough);

  // The display picker is the one control whose OPTIONS come from the machine
  // rather than from the markup, so it is rebuilt before values are applied.
  const screenSel = document.querySelector('[data-panel="screenIndex"]');
  if (screenSel && Array.isArray(screens)) {
    const want = screens.map((s) => s.index + " " + s.name + " " + s.width + "x" + s.height).join("|");
    if (screenSel.dataset.built !== want) {
      screenSel.dataset.built = want;
      screenSel.textContent = "";
      for (const s of screens) {
        const o = el("option");
        o.value = String(s.index);
        o.textContent = s.name + " · " + s.width + "×" + s.height;
        screenSel.appendChild(o);
      }
    }
  }

  for (const node of document.querySelectorAll("[data-panel]")) {
    const key = node.dataset.panel;
    if (!(key in settings)) continue;
    const v = settings[key];
    if (node.type === "checkbox") node.checked = !!v;
    else node.value = String(v);
    const out = document.querySelector('[data-out="' + key + '"]');
    if (out) out.textContent = panelFormat(node, v);
  }
  // The Overlay tab's preview is a second view onto the same settings.
  ovSet = settings;
  ovDraw();
};

(function wirePanelSettings() {
  for (const node of document.querySelectorAll("[data-panel]")) {
    const key = node.dataset.panel;
    // `input`, not `change`: a slider that only reported on release would make
    // "how wide is 300px" a guessing game.
    node.addEventListener("input", () => {
      let value;
      if (node.type === "checkbox") value = node.checked;
      else if (node.type === "range") value = parseFloat(node.value);
      else if (key === "screenIndex") value = parseInt(node.value, 10);
      else value = node.value;
      const out = document.querySelector('[data-out="' + key + '"]');
      if (out) out.textContent = panelFormat(node, value);
      send({ type: "setPanelField", key: key, value: value });
    });
  }
  const show = $("panel-show");
  if (show) show.addEventListener("click", () => send({ type: "showPanel" }));
  const reset = $("panel-reset");
  if (reset) reset.addEventListener("click", () => send({ type: "resetPanel" }));
})();

/* ============================================================================
   OVERLAY TAB — the mini screen

   A scale model of the display with the panel drawn inside it. Everything here
   is driven by the real window frame that Swift pushes, so the rectangle is
   where the panel IS: drag the real panel and this moves, drag this and the
   real panel moves. Nothing is simulated except the type, which at a tenth of
   size would only ever be mush -- so each line is a bar whose width stands in
   for its content, and the SHAPE of the readout is what the preview conveys.
   ========================================================================== */

let ovGeom = null;      // last geometry push from Swift
let ovSet = null;       // last settings push from Swift

/* The readout, in the order the panel draws it. `key` is the settings field the
   chip toggles; the stat rows share one entry each so the preview and the
   palette cannot disagree about what exists. */
const OV_PARTS = [
  { key: "showCharacter", name: "Character", row: "title" },
  { key: "showSeed", name: "Seed", row: "line" },
  { key: "showUnverified", name: "Unverified note", row: "line" },
  { key: "showTags", name: "Curses / flight / room", row: "tag" },
  { key: "showDamage", name: "Damage", row: "stat" },
  { key: "showTears", name: "Tears", row: "stat" },
  { key: "showRange", name: "Range", row: "stat" },
  { key: "showShotSpeed", name: "Shot speed", row: "stat" },
  { key: "showSpeed", name: "Speed", row: "stat" },
  { key: "showLuck", name: "Luck", row: "stat" },
  { key: "showShots", name: "Shot count", row: "stat" },
  { key: "showLast", name: "Last pickup", row: "line" },
  { key: "showRecent", name: "Recent pickups", row: "line" },
  { key: "showFooter", name: "Status strip", row: "line" },
];
/* Which settings field each stat row's accent should read from. */
const OV_ACCENT_OF = {
  showDamage: "Damage", showTears: "Tears", showRange: "Range",
  showShotSpeed: "Shot speed", showSpeed: "Speed", showLuck: "Luck",
};

window.onPanelGeometry = (g) => { ovGeom = g; ovDraw(); };

/* Called from onPanelSettings too, so the preview repaints on any change. */
function ovDraw() {
  const box = $("ovscreen");
  if (!box || !ovSet) return;

  const screens = (ovGeom && ovGeom.screens) || [];
  const sc = screens[ovSet.screenIndex] || screens[0];
  if (sc) {
    box.style.aspectRatio = sc.w + " / " + sc.h;
    const label = $("ovscreen-label");
    if (label) label.textContent = sc.name + " · " + Math.round(sc.w) + "×" + Math.round(sc.h);
  }

  const el2 = $("ovpanel");
  if (!el2) return;
  const p = ovGeom && ovGeom.panel;
  if (sc && p) {
    // Screen coordinates are desktop-wide; make them relative to this screen.
    // geometryJSON already flipped y to top-left, so the screen's own top edge
    // is measured the same way before subtracting.
    const deskTop = ovGeom.deskTop != null ? ovGeom.deskTop : sc.y + sc.h;
    const screenTop = deskTop - (sc.y + sc.h);
    el2.style.left = (((p.x - sc.x) / sc.w) * 100) + "%";
    el2.style.top = (((p.y - screenTop) / sc.h) * 100) + "%";
    el2.style.width = ((p.w / sc.w) * 100) + "%";
    el2.style.height = ((p.h / sc.h) * 100) + "%";
    el2.classList.toggle("hidden-panel", !ovGeom.visible);
  } else {
    // No window yet: draw it where the settings say it would land.
    el2.style.width = "22%";
    el2.style.height = "34%";
    el2.style.left = ovSet.corner.endsWith("Right") ? "72%" : "6%";
    el2.style.top = ovSet.corner.startsWith("bottom") ? "60%" : "6%";
    el2.classList.add("hidden-panel");
  }

  const hint = $("ovhint");
  if (hint) {
    hint.textContent = !ovGeom || !ovGeom.visible
      ? "The panel is not open — press Show it to place it."
      : ovSet.corner !== "free"
        ? "Snapped to " + ovSet.corner.replace(/([A-Z])/g, " $1").toLowerCase()
          + ". Choose Free to drag it."
        : "Drag the readout to move the real panel.";
  }

  ovDrawInner();
  ovDrawChips();
  for (const c of document.querySelectorAll("[data-corner]")) {
    c.classList.toggle("on", c.dataset.corner === ovSet.corner);
  }
}

/* The miniature readout: one bar per row that is switched on. */
function ovDrawInner() {
  const host = $("ovpanel-inner");
  if (!host) return;
  host.textContent = "";
  const compact = !!ovSet.compact;
  let statsDone = false;

  for (const part of OV_PARTS) {
    if (!ovSet[part.key]) continue;
    const isStat = part.row === "stat" && part.key in OV_ACCENT_OF;
    // Compact mode puts every stat on one line, so the preview draws one bar
    // for the lot rather than pretending they are still separate rows.
    if (compact && isStat) {
      if (statsDone) continue;
      statsDone = true;
      const line = el("div", "ovline");
      for (let i = 0; i < 4; i++) line.appendChild(el("i"));
      host.appendChild(line);
      continue;
    }
    if (part.key === "showTags" && ovSet.border) host.appendChild(el("div", "ovrule"));
    const line = el("div", "ovline " + (part.row === "title" ? "title" : part.row === "tag" ? "tag" : ""));
    if (isStat && OV_ACCENT_OF[part.key] === ovSet.accent) line.classList.add("accent");
    if (part.row === "title" || part.row === "tag") {
      line.appendChild(el("i"));
    } else if (isStat) {
      line.appendChild(el("i", "k"));
      line.appendChild(el("i", "v"));
      if (ovSet.showDeltas) line.appendChild(el("i", "d"));
    } else {
      line.appendChild(el("i", "k"));
    }
    host.appendChild(line);
    if (part.key === "showFooter" && ovSet.border) host.insertBefore(el("div", "ovrule"), line);
  }
}

/* Two lists: what is on the panel, and what is off it. Clicking moves a chip
   between them, which is the same thing as flipping its switch in the settings
   below -- both write the one field, so they can never disagree. */
function ovDrawChips() {
  const on = $("ovchips-on"), off = $("ovchips-off");
  if (!on || !off) return;
  on.textContent = ""; off.textContent = "";
  for (const part of OV_PARTS) {
    const chip = el("button", "chip" + (ovSet[part.key] ? " on" : ""));
    chip.type = "button";
    chip.textContent = part.name;
    chip.title = ovSet[part.key] ? "Take it off the panel" : "Put it back";
    chip.addEventListener("click", () => {
      send({ type: "setPanelField", key: part.key, value: !ovSet[part.key] });
    });
    (ovSet[part.key] ? on : off).appendChild(chip);
  }
}

/* Drag the miniature to move the real window. Percentages of the mini screen map
   straight onto the real display, so a drag of a third of the way across the
   preview is a third of the way across the monitor. */
(function ovDragging() {
  const el2 = $("ovpanel"), box = $("ovscreen");
  if (!el2 || !box) return;
  let from = null;

  el2.addEventListener("pointerdown", (e) => {
    if (!ovGeom || !ovGeom.panel || !ovGeom.visible) return;
    const screens = ovGeom.screens || [];
    const sc = screens[(ovSet && ovSet.screenIndex) || 0] || screens[0];
    if (!sc) return;
    from = {
      px: e.clientX, py: e.clientY,
      x: ovGeom.panel.x, y: ovGeom.panel.y,
      rect: box.getBoundingClientRect(), sc,
    };
    el2.classList.add("dragging");
    el2.setPointerCapture(e.pointerId);
    // A snapped panel cannot be dragged anywhere -- it would jump straight back
    // on the next settings push -- so a drag means you want it free.
    if (ovSet && ovSet.corner !== "free") send({ type: "setPanelField", key: "corner", value: "free" });
    e.preventDefault();
  });

  el2.addEventListener("pointermove", (e) => {
    if (!from) return;
    const scaleX = from.sc.w / from.rect.width;
    const scaleY = from.sc.h / from.rect.height;
    const x = from.x + (e.clientX - from.px) * scaleX;
    const y = from.y + (e.clientY - from.py) * scaleY;
    send({ type: "movePanel", x, y });
  });

  const stop = (e) => {
    if (!from) return;
    from = null;
    el2.classList.remove("dragging");
    try { el2.releasePointerCapture(e.pointerId); } catch (err) { /* already gone */ }
  };
  el2.addEventListener("pointerup", stop);
  el2.addEventListener("pointercancel", stop);
})();

/* Corner buttons under the preview, the same field the select in the settings
   below writes. */
for (const c of document.querySelectorAll("[data-corner]")) {
  c.addEventListener("click", () => {
    send({ type: "setPanelField", key: "corner", value: c.dataset.corner });
  });
}

/* ============================================================================
   SETTINGS

   Declarative on purpose. Every entry below is {id, type, label, desc, def} plus
   an `apply` that does the actual work, and the page is rendered FROM that list --
   so adding a setting is one object, not a block of markup plus a wiring call plus
   a localStorage line that someone forgets.

   The rule the list enforces: nothing here is decorative. Every switch either sets
   a CSS custom property, flips a data attribute the stylesheet reads, or changes a
   value the renderers already consult. A setting that looked like it did something
   and did not would be worse than not offering it.
   ========================================================================== */

const SET_KEY = "set.";
const setStore = {};

function setGet(id) { return setStore[id]; }

function setSave(id, v) {
  setStore[id] = v;
  try { localStorage.setItem(SET_KEY + id, JSON.stringify(v)); } catch (e) { /* private mode */ }
}

/* Shorthands for the three ways a setting reaches the page. */
const root = () => document.documentElement;
const cssVar = (name) => (v) => root().style.setProperty(name, v);
const dataAttr = (name) => (v) =>
  v === true || v === "on" ? root().removeAttribute(name)
    : root().setAttribute(name, v === false ? "off" : String(v));

const SETTINGS = [
  {
    group: "Appearance",
    blurb: "How the app itself looks. Nothing here touches your game or your save.",
    items: [
      { id: "theme", type: "seg", label: "Theme", def: "devil",
        opts: [["devil", "Devil"], ["angel", "Angel"]],
        desc: "Both rooms from the game. Devil is the dark one.",
        apply: (v) => { if (typeof applyTheme === "function") applyTheme(v, { notify: true }); } },

      { id: "density", type: "seg", label: "Row density", def: "comfortable",
        opts: [["comfortable", "Comfortable"], ["compact", "Compact"]],
        desc: "Compact tightens every list row so more fits on screen.",
        apply: (v) => root().setAttribute("data-density", v) },

      { id: "spriteScale", type: "range", label: "Sprite size", def: 1,
        min: 0.7, max: 1.8, step: 0.05, unit: "x",
        desc: "Scales the item and enemy art in lists.",
        apply: cssVar("--spr-scale") },

      { id: "radius", type: "range", label: "Corner rounding", def: 3,
        min: 0, max: 14, step: 1, unit: "px",
        desc: "Applies to rows, cards and tiles.",
        apply: (v) => cssVar("--ui-radius")(v + "px") },

      { id: "pixelArt", type: "switch", label: "Crisp pixel art", def: true,
        desc: "Nearest-neighbour scaling, so sprites stay sharp instead of blurring. "
          + "Off uses smooth resampling.",
        apply: dataAttr("data-pixel") },

      { id: "scanlines", type: "switch", label: "Scanline overlay", def: true,
        desc: "The faint CRT lines over the whole app.",
        apply: dataAttr("data-scan") },
    ],
  },

  {
    group: "Lists",
    blurb: "What each row shows, and how many of them arrive at a time.",
    items: [
      { id: "showTags", type: "switch", label: "Tags on rows", def: true,
        desc: "The kind, <span class='pill'>special</span> and confidence pills next to a name.",
        apply: dataAttr("data-tags") },

      { id: "showDeltas", type: "switch", label: "Stat changes on rows", def: true,
        desc: "The monospaced line of what an item actually changes.",
        apply: dataAttr("data-deltas") },

      { id: "descLines", type: "seg", label: "Description length", def: "2",
        opts: [["1", "One line"], ["2", "Two"], ["3", "Three"], ["0", "Full"]],
        desc: "How much of an item's text a row shows before it is cut.",
        apply: (v) => cssVar("--desc-lines")(v === "0" ? "unset" : v) },

      { id: "batch", type: "seg", label: "Rows per load", def: "24",
        opts: [["12", "12"], ["24", "24"], ["48", "48"], ["96", "96"]],
        desc: "Lists grow as you scroll. Bigger batches mean fewer steps and more work per step.",
        apply: (v) => { window.BATCH_SIZE = parseInt(v, 10) || 24; } },

      { id: "searchText", type: "switch", label: "Search descriptions too", def: false,
        desc: "Off matches names and ids only, which is faster and rarely wrong. "
          + "On also looks inside what an item does.",
        apply: (v) => { window.SEARCH_TEXT = v; if (typeof renderResults === "function" && catalogue.length) renderResults(); } },
    ],
  },

  {
    group: "Motion",
    blurb: "Two independent switches: the entry animation a row makes, and the effect "
      + "wash that fades over it. Turning either off leaves the other alone.",
    items: [
      { id: "fxAnim", type: "switch", label: "Entry animations", def: fxPrefOn("fxAnim"),
        desc: "The motion each row makes as it scrolls into view.",
        apply: (v) => { window.FX_ANIM_ON = v; root().setAttribute("data-fx-anim", v ? "on" : "off"); } },

      { id: "fxEff", type: "switch", label: "Effect overlays", def: fxPrefOn("fxEff"),
        desc: "The poison, fire and blood wash that fades over a row.",
        apply: (v) => { window.FX_EFF_ON = v; root().setAttribute("data-fx-eff", v ? "on" : "off"); } },

      { id: "fxMin", type: "switch", label: "Minimalist effects", def: false,
        desc: "Only items and enemies that really have the effect show one; everything "
          + "else stays still.",
        apply: (v) => { window.FX_MIN_ON = v; root().setAttribute("data-fx-min", v ? "on" : "off"); } },

      { id: "fxBg", type: "switch", label: "Animated backgrounds", def: true,
        desc: "An item's effect drifts behind its detail card. Off keeps the backdrop "
          + "but freezes it.",
        apply: (v) => { window.FX_BG_ON = v; root().setAttribute("data-fx-bg", v ? "on" : "off"); } },

      { id: "spriteFrames", type: "switch", label: "Sprites play their idle", def: true,
        desc: "Enemy art steps through the frames from the game's own animation files, "
          + "and pills cycle every colour.",
        apply: dataAttr("data-frames") },

      { id: "motionSpeed", type: "range", label: "Motion speed", def: 1,
        min: 0.4, max: 2, step: 0.1, unit: "x",
        desc: "Multiplies every idle and sprite animation. Lower is calmer.",
        apply: (v) => cssVar("--motion-k")(1 / (v || 1)) },
    ],
  },

  {
    group: "Run view",
    blurb: "The live readout while you play.",
    items: [
      { id: "decimals", type: "seg", label: "Decimal places", def: "2",
        opts: [["1", "1"], ["2", "2"], ["3", "3"]],
        desc: "How precisely the stat numbers read.",
        apply: (v) => { window.STAT_DECIMALS = parseInt(v, 10) || 2;
          if (typeof lastStateJSON === "object" && lastStateJSON) window.onState(lastStateJSON); } },

      { id: "showBreakdown", type: "switch", label: "Base + change under each stat", def: true,
        desc: "Shows what your character started with and what the items added.",
        apply: dataAttr("data-breakdown") },

      { id: "showNotes", type: "switch", label: "Build conflict notes", def: true,
        desc: "Warnings when something you are carrying overrides something else.",
        apply: dataAttr("data-notes") },
    ],
  },

  {
    group: "Data",
    blurb: "Where the item data comes from, and how much disk it keeps.",
    items: [
      { id: "storageMode", type: "seg", label: "Storage", def: "compact",
        opts: [["compact", "Compact"], ["cached", "Cached"]],
        desc: "Compact throws the 570&nbsp;MB extraction away once it has what it needs. "
          + "Cached keeps it so a rebuild skips the one-minute extract. Both produce "
          + "identical data &#8212; it trades disk for rebuild speed, never features.",
        native: true,
        apply: (v) => send({ type: "setStorageMode", mode: v }) },

      { id: "rebuild", type: "action", label: "Rebuild the data", action: "Rebuild now",
        busy: "Rebuilding\u2026",
        confirm: "Rebuild the item data from your game install? This takes about a minute.",
        desc: "Re-reads everything from your own copy of the game. The storage choice "
          + "above takes effect on the next rebuild, so use this after changing it &#8212; "
          + "and any time the game updates.",
        native: true,
        apply: () => send({ type: "rebuildData" }) },
    ],
  },

  {
    group: "Updates",
    blurb: "Checking is automatic; installing never is. Nothing is installed that does "
      + "not match the checksum published with the release and carry the same signature "
      + "as the copy you are running.",
    items: [
      { id: "updateAuto", type: "switch", label: "Check automatically", def: true,
        desc: "Once shortly after launch, then daily. It only ever checks &#8212; you "
          + "decide whether to install.",
        native: true,
        apply: (v) => send({ type: "setUpdateField", key: "auto", value: v }) },

      { id: "updateBeta", type: "switch", label: "Include pre-releases", def: false,
        desc: "Offers beta and release-candidate builds too. Off means tagged releases "
          + "only.",
        native: true,
        apply: (v) => send({ type: "setUpdateField", key: "beta", value: v }) },

      { id: "verifyHUD", type: "switch", label: "Compare against the in-game HUD", def: false,
        desc: "Adds a table to the Run tab for typing in what Isaac's own HUD shows, next "
          + "to what this computes. Needs <code>FoundHUD=1</code> in your "
          + "<code>options.ini</code>. Off unless you are checking the numbers.",
        apply: (v) => { verifyOn = v; renderVerify(); } },

      { id: "updateCheck", type: "action", label: "Check for updates", action: "Check now",
        busy: "Checking…",
        desc: "<span id='update-status'>&#8212;</span>",
        native: true,
        apply: () => send({ type: "checkUpdate" }) },
    ],
  },
];

/* ---- updates ---------------------------------------------------------------
   One push carries the whole state, so the row below the button is always telling
   the truth about what the updater is actually doing. The install button only ever
   appears once a download has been verified. */
window.onUpdate = (u) => {
  // The two preferences are Swift's, not localStorage's, so reflect them onto the
  // switches rather than letting the page keep its own idea of them.
  for (const [id, val] of [["updateAuto", u.auto], ["updateBeta", u.beta]]) {
    if (typeof val !== "boolean") continue;
    setStore[id] = val;
    const item = SETTINGS.flatMap((g) => g.items).find((i) => i.id === id);
    if (item && item.node && item.node.type === "checkbox") item.node.checked = val;
  }
  const status = $("update-status");
  const btn = (SETTINGS.flatMap((g) => g.items).find((i) => i.id === "updateCheck") || {}).node;
  if (btn) { btn.disabled = u.status === "checking" || u.status === "downloading"; }
  if (btn && u.status !== "checking" && u.status !== "downloading") {
    btn.textContent = "Check now";
  }
  if (!status) return;

  const rel = (t) => {
    if (!t) return "";
    const d = Math.round((Date.now() - new Date(t).getTime()) / 60000);
    if (d < 1) return " Checked just now.";
    if (d < 60) return ` Checked ${d} min ago.`;
    return ` Checked ${Math.round(d / 60)} h ago.`;
  };

  const say = (html) => { status.innerHTML = html; };
  const ver = esc(u.version || "");
  switch (u.status) {
    case "checking": say("Checking…"); break;
    case "current":
      say(`You are on <b>${esc(u.current)}</b>, the newest version.${rel(u.lastChecked)}`);
      break;
    case "available":
      say(`<b>${ver}</b> is available (you have ${esc(u.current)}). `
        + `<button class="chip" id="update-get">Download it</button>`);
      break;
    case "downloading":
      say(`Downloading and verifying… ${Math.round((u.fraction || 0) * 100)}%`);
      break;
    case "ready":
      say(u.waitingForGame
        ? `<b>${ver}</b> is verified and ready, but Isaac is running &#8212; it will not `
          + `swap itself out mid-run. Quit the game, then `
          + `<button class="chip" id="update-go">install it</button>.`
        : `<b>${ver}</b> is verified and ready. `
          + `<button class="chip" id="update-go">Install and restart</button>`);
      break;
    case "failed": say(`<span class="bad">${esc(u.error || "Update check failed.")}</span>`); break;
    default:
      say(`You are on <b>${esc(u.current)}</b>.`);
  }
  if (u.dataStale) {
    status.innerHTML += `<br><span class="warn">The game has been updated since your item `
      + `data was built, so some numbers may be wrong. Rebuild the data above.</span>`;
  }
  const get = $("update-get"); if (get) get.onclick = () => send({ type: "downloadUpdate" });
  const go = $("update-go"); if (go) go.onclick = () => send({ type: "installUpdate" });
};

/* Swift answers when the rebuild finishes, so the button can stop saying "Rebuilding". */
window.onRebuilt = (ok) => {
  const item = SETTINGS.flatMap((g) => g.items).find((i) => i.id === "rebuild");
  if (!item || !item.node) return;
  item.node.disabled = false;
  item.node.textContent = ok ? "Rebuilt" : "Rebuild failed \u2014 try again";
  setTimeout(() => { if (item.node) item.node.textContent = item.action; }, 4000);
};

/* ---- rendering -------------------------------------------------------------
   Built from the list above rather than written out in index.html, so the markup
   and the behaviour cannot drift apart. */
function setControl(item) {
  const wrap = el("div", "set-control");
  if (item.type === "switch") {
    const lab = el("label", "switch");
    const box = el("input"); box.type = "checkbox"; box.checked = !!setGet(item.id);
    const track = el("span", "switch-track"); track.appendChild(el("span", "switch-knob"));
    lab.append(box, track);
    box.addEventListener("change", () => { setSave(item.id, box.checked); item.apply(box.checked); });
    wrap.appendChild(lab);
  } else if (item.type === "seg") {
    const seg = el("div", "seg");
    for (const [value, label] of item.opts) {
      const b = el("button", "seg-b" + (String(setGet(item.id)) === value ? " on" : ""), label);
      b.type = "button";
      b.addEventListener("click", () => {
        setSave(item.id, value);
        [...seg.children].forEach((c) => c.classList.toggle("on", c === b));
        item.apply(value);
      });
      seg.appendChild(b);
    }
    wrap.appendChild(seg);
  } else if (item.type === "action") {
    const b = el("button", "ghost", item.action);
    b.type = "button";
    b.addEventListener("click", () => {
      if (item.confirm && !confirm(item.confirm)) return;
      b.disabled = true;
      b.textContent = item.busy || "Working\u2026";
      item.apply();
    });
    item.node = b;
    wrap.appendChild(b);
  } else if (item.type === "range") {
    const r = el("input"); r.type = "range";
    r.min = item.min; r.max = item.max; r.step = item.step; r.value = setGet(item.id);
    const out = el("output", "", fmtSetting(item, r.value));
    r.addEventListener("input", () => {
      const v = parseFloat(r.value);
      setSave(item.id, v); item.apply(v); out.textContent = fmtSetting(item, v);
    });
    wrap.append(r, out);
  }
  return wrap;
}

function fmtSetting(item, v) {
  if (item.unit === "x") return (+v).toFixed(2) + "×";
  if (item.unit === "px") return Math.round(v) + "px";
  return String(v);
}

function renderSettings() {
  const host = $("set-body");
  const nav = $("set-nav");
  if (!host || !nav) return;
  host.textContent = ""; nav.textContent = "";

  for (const group of SETTINGS) {
    const id = "set-" + group.group.toLowerCase().replace(/\s+/g, "-");

    const link = el("button", "set-navi", group.group);
    link.type = "button";
    link.addEventListener("click", () => {
      const t = $(id);
      if (t) t.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    nav.appendChild(link);

    const sec = el("section", "set-group"); sec.id = id;
    sec.appendChild(el("h2", "", group.group));
    if (group.blurb) {
      const b = el("p", "set-blurb"); b.innerHTML = group.blurb; sec.appendChild(b);
    }
    for (const item of group.items) {
      const row = el("div", "set-row");
      row.dataset.search = (item.label + " " + item.desc).toLowerCase().replace(/<[^>]+>/g, "");
      const text = el("div", "set-text");
      text.appendChild(el("div", "set-label", item.label));
      const d = el("p", "set-desc"); d.innerHTML = item.desc; text.appendChild(d);
      row.append(text, setControl(item));
      sec.appendChild(row);
    }
    host.appendChild(sec);
  }
}

/* ---- load, apply, filter ---------------------------------------------------- */
function settingsBoot() {
  for (const group of SETTINGS) {
    for (const item of group.items) {
      let v = item.def;
      try {
        const raw = localStorage.getItem(SET_KEY + item.id);
        if (raw !== null) v = JSON.parse(raw);
      } catch (e) { /* private mode, or something hand-edited: fall back to the default */ }
      setStore[item.id] = v;
      // Native-backed settings are applied by Swift on its own schedule; applying
      // them here would post a message back for a value that came FROM there.
      if (!item.native) { try { item.apply(v); } catch (e) { /* a missing hook must not stop the rest */ } }
    }
  }
  renderSettings();

  const search = $("set-search");
  if (search) {
    search.addEventListener("input", () => {
      const q = search.value.trim().toLowerCase();
      for (const row of document.querySelectorAll(".set-row")) {
        row.hidden = !!q && !row.dataset.search.includes(q);
      }
      for (const sec of document.querySelectorAll(".set-group")) {
        const any = [...sec.querySelectorAll(".set-row")].some((r) => !r.hidden);
        sec.hidden = !any;
      }
    });
  }

  const reset = $("set-reset");
  if (reset) {
    reset.addEventListener("click", () => {
      for (const group of SETTINGS) {
        for (const item of group.items) {
          setSave(item.id, item.def);
          if (!item.native) { try { item.apply(item.def); } catch (e) { /* as above */ } }
        }
      }
      renderSettings();
    });
  }
}

/* Swift owns the storage mode, so the page reflects what it reports rather than
   keeping its own idea of it. */
window.onStorageMode = (mode) => {
  setStore.storageMode = mode;
  const seg = document.querySelector('#set-data .seg');
  if (!seg) return;
  [...seg.children].forEach((b, i) =>
    b.classList.toggle("on", SETTINGS.find(g => g.group === "Data").items[0].opts[i][0] === mode));
};

settingsBoot();

/* ---- history ---------------------------------------------------------------
   Past runs. Everything here comes from the archive on disk, not from the live
   run, so it survives quitting the app -- which is the whole point. */
let historyData = { runs: [], totals: {} };
let histFilter = "all";

const OUTCOME = {
  won: ["Won", "good"],
  died: ["Died", "bad"],
  abandoned: ["Abandoned", "dim"],
  inProgress: ["In progress", "warn"],
};

function histDuration(seconds) {
  if (seconds == null) return "";
  const m = Math.round(seconds / 60);
  if (m < 60) return m + " min";
  return Math.floor(m / 60) + " h " + (m % 60) + " min";
}

function histWhen(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return "";
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
    + " " + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

function histRow(r) {
  const li = el("li", "hist-row");
  const [label, tone] = OUTCOME[r.outcome] || ["?", "dim"];

  const head = el("div", "hist-head");
  head.append(el("span", "hist-char", r.character));
  head.append(el("span", "pill " + tone, label));
  head.append(el("span", "hist-meta",
    "Floor " + r.stage + (r.duration ? "  ·  " + histDuration(r.duration) : "")
    + (r.seed ? "  ·  " + r.seed : "")));
  head.append(el("span", "hist-when", histWhen(r.startedAt)));
  li.appendChild(head);

  if (r.death) li.appendChild(el("div", "hist-death", r.death));

  // The build, in pickup order -- the order the stat model composes in.
  if (r.items.length) {
    const items = el("div", "hist-items");
    for (const it of r.items) {
      const chip = el("span", "hist-item" + (it.manual ? " manual" : ""), it.name);
      chip.title = it.manual ? "added by hand" : "#" + it.id;
      items.appendChild(chip);
    }
    li.appendChild(items);
  }

  const stats = el("div", "hist-stats");
  for (const s of r.stats) {
    const cell = el("span", "hist-stat");
    cell.append(el("span", "k", s.key));
    cell.append(el("span", "v", (s.approx ? "~" : "") + fmt(s.value)));
    stats.appendChild(cell);
  }
  li.appendChild(stats);

  const del = el("button", "hist-del", "Delete");
  del.title = "Remove this run from the history";
  del.onclick = () => { if (confirm("Delete this run from your history?"))
    send({ type: "deleteRun", id: r.id }); };
  li.appendChild(del);
  return li;
}

function renderHistory() {
  const list = $("hist-list"), empty = $("hist-empty"), totals = $("hist-totals");
  if (!list) return;
  const runs = historyData.runs.filter(
    (r) => histFilter === "all" || r.outcome === histFilter);
  list.replaceChildren(...runs.map(histRow));
  if (empty) empty.hidden = historyData.runs.length > 0;

  const t = historyData.totals || {};
  if (!totals) return;
  if (!t.runs) { totals.replaceChildren(); return; }
  const rate = t.runs ? Math.round((t.wins / t.runs) * 100) : 0;
  const cells = [
    ["Runs", t.runs],
    ["Wins", t.wins + "  (" + rate + "%)"],
    ["Deaths", t.deaths],
    ["Deepest", "Floor " + t.deepestStage],
    ["Played", histDuration(t.totalTime)],
  ];
  const box = el("div", "hist-totalrow");
  for (const [k, v] of cells) {
    const c = el("div", "hist-total");
    c.append(el("span", "k", k), el("span", "v", String(v)));
    box.appendChild(c);
  }
  const extra = el("div", "hist-lists");
  if ((t.favouriteItems || []).length) {
    const d = el("div", "hist-fav");
    d.appendChild(el("h3", null, "Most-taken items"));
    const ul = el("ul");
    for (const f of t.favouriteItems.slice(0, 8)) {
      const li = el("li");
      li.append(el("span", "n", f.name), el("span", "c", f.count + " runs"));
      ul.appendChild(li);
    }
    d.appendChild(ul); extra.appendChild(d);
  }
  if ((t.byCharacter || []).length) {
    const d = el("div", "hist-fav");
    d.appendChild(el("h3", null, "By character"));
    const ul = el("ul");
    for (const c of t.byCharacter.slice(0, 8)) {
      const li = el("li");
      li.append(el("span", "n", c.name),
        el("span", "c", c.runs + " runs, " + c.wins + " won"));
      ul.appendChild(li);
    }
    d.appendChild(ul); extra.appendChild(d);
  }
  totals.replaceChildren(box, extra);
}

window.onHistory = (data) => {
  historyData = data || { runs: [], totals: {} };
  renderHistory();
};

{
  const f = $("hist-filter");
  if (f) f.addEventListener("change", () => { histFilter = f.value; renderHistory(); });
  const ex = $("hist-export");
  if (ex) ex.onclick = () => send({ type: "exportHistory" });
  const clear = $("hist-clear");
  if (clear) clear.onclick = () => {
    if (confirm("Delete every run from your history? This cannot be undone."))
      send({ type: "deleteAllRuns" });
  };
}

/* ---- comparing against the in-game HUD -------------------------------------
   The app's whole claim is that these seven numbers are your real ones, and they
   came from a mod's data files rather than from the game. Nothing here has ever
   been checked against what Isaac itself displays.

   The tolerance per stat is the game's own display precision, not an arbitrary
   epsilon: the HUD rounds, so agreeing to within half a displayed step is
   agreement, and anything wider is a real disagreement worth chasing. */
// The key is what Swift actually sends, which for tear delay is "delay" -- "tearDelay"
// is the Swift-side property name and using it here meant that row silently never
// populated. Exactly the sort of quiet nothing this table exists to catch.
//
// `onHUD` marks the six the game itself displays. Isaac's HUD has no tear-delay
// readout: delay is what the model computes internally and tears/second is what you
// see, so delay is shown for context and not compared against anything.
const VERIFY_ROWS = [
  { key: "damage", label: "Damage", tol: 0.05, onHUD: true },
  { key: "tears", label: "Tears/s", tol: 0.05, onHUD: true },
  { key: "range", label: "Range", tol: 0.5, onHUD: true },
  { key: "shotSpeed", label: "Shot speed", tol: 0.05, onHUD: true },
  { key: "speed", label: "Speed", tol: 0.005, onHUD: true },
  { key: "luck", label: "Luck", tol: 0.05, onHUD: true },
  { key: "delay", label: "Tear delay", tol: 0.5, onHUD: false },
];

let verifyOn = false;

// Persisted, because these are readings taken by hand off a screen and there is no way
// to get them back. A relaunch mid-session used to lose the lot.
const HUD_KEY = "isaac.hudValues";
const hudValues = (() => {
  try { return JSON.parse(localStorage.getItem(HUD_KEY) || "{}"); } catch (e) { return {}; }
})();
function saveHudValues() {
  try { localStorage.setItem(HUD_KEY, JSON.stringify(hudValues)); } catch (e) { /* private mode */ }
}

function renderVerify() {
  const host = $("vrows");
  const box = $("verify");
  if (!host || !box) return;
  box.hidden = !verifyOn;
  if (!verifyOn) return;

  host.replaceChildren(...VERIFY_ROWS.map(({ key, label, tol, onHUD }) => {
    const tr = el("tr");
    const name = el("td");
    const wrap = el("span", "vname");
    const glyph = hudIcon(key, 24);
    if (glyph) wrap.appendChild(glyph);
    wrap.appendChild(el("span", null, label));
    name.appendChild(wrap);
    tr.appendChild(name);

    const computed = lastState?.stats?.[key]?.value ?? null;
    tr.appendChild(el("td", "num", computed == null ? "—" : fmt(computed)));

    const td = el("td");
    if (onHUD) {
      const input = el("input");
      input.type = "text";
      input.inputMode = "decimal";
      input.placeholder = "HUD";
      input.value = hudValues[key] ?? "";
      input.addEventListener("input", () => {
        hudValues[key] = input.value;
        saveHudValues();
        paintVerdict(tr, key, tol, computed, input.value);
      });
      td.appendChild(input);
    } else {
      td.appendChild(el("span", "vwait", "not on the HUD"));
    }
    tr.appendChild(td);

    tr.appendChild(el("td"));
    if (onHUD) paintVerdict(tr, key, tol, computed, hudValues[key] ?? "");
    return tr;
  }));
}

function paintVerdict(tr, key, tol, computed, typed) {
  const cell = tr.lastChild;
  const n = parseFloat(typed);
  if (computed == null || typed === "" || Number.isNaN(n)) {
    cell.replaceChildren(el("span", "vwait", "—"));
    return;
  }
  const diff = Math.abs(n - computed);
  cell.replaceChildren(
    diff <= tol
      ? el("span", "vok", "matches")
      : el("span", "vbad", "off by " + fmt(diff)));
}

/* A report worth pasting somewhere, rather than a screenshot of a table. */
function verifyReport() {
  const lines = ["Isaac Companion — stats vs the in-game HUD", ""];
  lines.push("character: " + ($("character")?.textContent || "?"));
  lines.push("seed: " + ($("seed")?.textContent || "?"));
  const names = [...document.querySelectorAll(".held li .name")].map((n) => n.textContent);
  if (names.length) lines.push("build: " + names.join(", "));
  lines.push("");
  for (const { key, label, tol, onHUD } of VERIFY_ROWS) {
    const computed = lastState?.stats?.[key]?.value ?? null;
    const typed = hudValues[key];
    const n = parseFloat(typed);
    let verdict = onHUD ? "not compared" : "derived, not on the HUD";
    if (computed != null && typed && !Number.isNaN(n)) {
      const diff = Math.abs(n - computed);
      verdict = diff <= tol ? "matches" : "MISMATCH by " + fmt(diff);
    }
    lines.push(
      label.padEnd(12)
      + "computed " + (computed == null ? "—" : fmt(computed)).padEnd(10)
      + "hud " + (typed || "—").padEnd(10) + verdict);
  }
  return lines.join("\n");
}

{
  const copy = $("v-copy");
  if (copy) copy.onclick = async () => {
    try {
      await navigator.clipboard.writeText(verifyReport());
      const hint = $("v-hint");
      if (hint) { hint.textContent = "Copied."; setTimeout(() => (hint.textContent = ""), 2500); }
    } catch (e) {
      const hint = $("v-hint");
      if (hint) hint.textContent = "Could not copy: " + e;
    }
  };
  const clear = $("v-clear");
  if (clear) clear.onclick = () => {
    for (const { key } of VERIFY_ROWS) delete hudValues[key];
    saveHudValues();
    renderVerify();
  };
}

/* ---- the game's own stat icons ---------------------------------------------
   Isaac's HUD labels its six stats with glyphs and no words, so "which row is
   range and which is shot speed" is a real question. These are the game's own
   icons, read off your install at data-build time -- not redrawn approximations,
   so the thing next to Range here is exactly the thing next to Range in game.

   The sheet is 16x16 cells, four per row, in the order hudstats.anm2 lists them.
   Frames 6-8 are the angel and devil marks and one the app has no use for. */
let hudStats = null;

const HUD_ICON = {
  speed: 0,       // a boot with speed lines
  tears: 1,       // an eye, firing
  range: 2,       // dashes at three distances
  shotSpeed: 3,   // a tear with a motion trail
  damage: 4,      // a sword
  luck: 5,        // a four-leaf clover
};

/* One 16px cell, scaled up and kept crisp. Returns null when the sheet is absent,
   so every caller degrades to text rather than leaving a hole. */
function hudIcon(stat, size = 16) {
  const frame = HUD_ICON[stat];
  if (!hudStats || frame == null) return null;
  const cols = hudStats.cols || 4;
  const cell = hudStats.cell || 16;
  const i = el("i", "hudicon");
  const scale = size / cell;
  i.style.width = size + "px";
  i.style.height = size + "px";
  i.style.backgroundImage = "url(" + hudStats.uri + ")";
  i.style.backgroundSize = (cols * cell * scale) + "px auto";
  i.style.backgroundPosition =
    (-(frame % cols) * cell * scale) + "px " + (-Math.floor(frame / cols) * cell * scale) + "px";
  i.title = "what the game's HUD shows for this stat";
  return i;
}

window.onHudStats = (data) => {
  hudStats = data;
  if (!data) return;
  // Anything already on screen was drawn before the sheet arrived.
  if (typeof renderVerify === "function") renderVerify();
  if (lastState && typeof window.onState === "function") window.onState(lastState);
};

/* ---- pills -----------------------------------------------------------------
   What auto-detection can and cannot do here, because the limit is the game's,
   not ours:

     the log says a pill SPAWNED, and that the pocket slot was USED
     the screen says what COLOUR the pill is
     nothing anywhere says what that colour DOES

   The game reshuffles colour -> effect every run and writes it down nowhere the
   app can reach. So the colour is identified automatically, and the effect is
   answered once per colour and then applied for the rest of the run -- the second
   orange pill of a run is named without being asked about. */
let pillData = { seen: [], catalogue: [] };

function pillSwatch(colour, size = 26) {
  const pillStrip = strips["pills"];
  if (!pillStrip) return null;
  const i = el("i", "pillswatch");
  const frames = pillStrip.frames || 13;
  i.style.width = size + "px";
  i.style.height = size + "px";
  i.style.backgroundImage = "url(" + pillStrip.uri + ")";
  i.style.backgroundSize = (frames * size) + "px " + size + "px";
  i.style.backgroundPosition = (-colour * size) + "px 0";
  return i;
}

function renderPills() {
  const host = document.getElementById("pill-list");
  if (!host) return;
  host.textContent = "";
  if (!pillData.seen.length) {
    host.appendChild(el("p", "muted small", "No pills seen yet this run."));
    return;
  }
  for (const row of pillData.seen) {
    const line = el("div", "pillrow");
    const sw = pillSwatch(row.colour);
    if (sw) line.appendChild(sw);

    const body = el("div", "pillbody");
    if (row.name) {
      body.appendChild(el("div", "pillname", row.name));
      const why = row.source === "identified" ? "you named it" : "worked out from a stat change";
      body.appendChild(el("div", "muted small", why));
    } else {
      body.appendChild(el("div", "pillname muted", "Not known yet"));
      const pick = el("select", "pillpick");
      pick.appendChild(el("option", null, "What did it do?"));
      for (const p of pillData.catalogue) {
        const o = el("option", null, p.name);
        o.value = p.id;
        pick.appendChild(o);
      }
      pick.addEventListener("change", () => {
        if (!pick.value) return;
        send({ type: "identifyPill", colour: row.colour, effectID: Number(pick.value) });
      });
      body.appendChild(pick);
    }
    line.appendChild(body);

    if (row.name) {
      const clear = el("button", "ghost small", "Wrong?");
      clear.addEventListener("click", () => send({ type: "forgetPill", colour: row.colour }));
      line.appendChild(clear);
    }
    host.appendChild(line);
  }
}

window.onPills = (data) => {
  if (data) pillData = data;
  renderPills();
};

window.onPillScan = (result) => {
  const status = document.getElementById("pill-status");
  if (!status) return;
  if (result.error) { status.textContent = result.error; return; }
  if (!result.found || !result.found.length) {
    status.textContent = "No pill in the pocket slot.";
    return;
  }
  const held = result.found[0];
  status.textContent =
    "Found a pill — " + Math.round(held.confidence * 100) + "% sure of the colour.";
};

document.getElementById("pill-scan")?.addEventListener("click", () => {
  const status = document.getElementById("pill-status");
  if (status) status.textContent = "Looking…";
  send({ type: "scanPills" });
});
