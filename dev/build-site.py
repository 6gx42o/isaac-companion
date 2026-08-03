#!/usr/bin/env python3
"""Assembles the public site: home page + item index, one self-contained file.

Data comes from `ingestctl sitedata`, which measures each sprite's dominant colours
off the atlas — that is what makes "grey" or "gold" work as a search term when you
cannot remember an item's name.
"""
import base64, io, json, pathlib, sys, urllib.request

from PIL import Image

HERE = pathlib.Path(__file__).parent
data = json.loads((HERE / "site-data.json").read_text())


def to_webp(uri):
    """Re-encode a base64 PNG data URI as LOSSLESS WebP.

    The three sprite sheets are the bulk of this page. As RGBA PNG they are 0.3, 1.1
    and 1.9 MB, and base64 adds a third again -- about 4.4 MB of the file. Lossless
    WebP is pixel-identical and roughly a third the size. It is done here rather than
    in `ingestctl sitedata` because macOS can read WebP but not write it: it is absent
    from CGImageDestinationCopyTypeIdentifiers, so ImageIO has no encoder for it.

    Every browser that can run this page has supported WebP since 2020 (Safari 14).
    """
    if not uri or not uri.startswith("data:image/png;base64,"):
        return uri
    src = Image.open(io.BytesIO(base64.b64decode(uri.split(",", 1)[1]))).convert("RGBA")
    buf = io.BytesIO()
    src.save(buf, format="WEBP", lossless=True, quality=100, method=6)
    # Trust nothing: prove the round trip is exact before shipping it.
    if list(Image.open(io.BytesIO(buf.getvalue())).convert("RGBA").get_flattened_data()) \
            != list(src.get_flattened_data()):
        return uri
    return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()


data["atlas"] = to_webp(data["atlas"])
for key in ("monsters", "badges", "pills"):
    if data.get(key):
        data[key]["uri"] = to_webp(data[key]["uri"])

# Trim the payload: the page never uses these, and every byte is inlined.
for it in data["items"]:
    it["text"] = it["text"][:240]

blob = json.dumps(data, separators=(",", ":"))

REPO_SLUG = "6gx42o/isaac-companion"

# Downloads point at the GitHub Release rather than being inlined as base64.
#
# They used to be inlined, which made the page genuinely self-contained -- but four
# installers is ~9.6 MB of base64 in a page whose actual content is under 2 MB, so five
# sixths of every visit was spent downloading binaries the visitor had not asked for yet.
# The URLs are resolved HERE, at build time, so the page still makes no network request
# of its own: it just contains ordinary links, and the browser fetches only what is
# clicked.
#
# The three Mac formats all carry the SAME universal binary (arm64 + x86_64), so which
# one you take is a question of how you like to install, never of which Mac you own. The
# .exe is a different program -- see win/ -- running the same log parser and the same
# Afterbirth+ stat model.
SUFFIX = {
    "zip": ".zip",
    "dmg": ".dmg",
    "pkg": ".pkg",
    "exe": "-windows-x64.exe",
}


def release_assets():
    """{kind: {url, mb}} for the latest release, or {} if it cannot be reached.

    Never raises: a site build should not fail because GitHub is unreachable or because
    no release exists yet. The caller falls back to the Releases page, which is a link
    that always works, rather than to a dead button.
    """
    api = f"https://api.github.com/repos/{REPO_SLUG}/releases/latest"
    try:
        req = urllib.request.Request(api, headers={"User-Agent": "isaac-site-build"})
        with urllib.request.urlopen(req, timeout=15) as r:
            rel = json.load(r)
    except Exception as e:                       # noqa: BLE001 - any failure is the same
        print(f"  ! could not reach the Releases API ({e}); linking the Releases page")
        return {}, None
    out = {}
    for a in rel.get("assets", []):
        for kind, suffix in SUFFIX.items():
            if a["name"].endswith(suffix):
                out[kind] = {
                    "url": a["browser_download_url"],
                    "mb": f"{a['size'] / 1048576:.1f}",
                }
    return out, rel.get("tag_name")


ASSETS, TAG = release_assets()
RELEASES_URL = f"https://github.com/{REPO_SLUG}/releases"
DOWNLOADS = {
    kind: {
        "url": ASSETS.get(kind, {}).get("url", RELEASES_URL),
        "mb": ASSETS.get(kind, {}).get("mb", "?"),
    }
    for kind in SUFFIX
}
missing = [k for k in SUFFIX if k not in ASSETS]
if missing:
    print(f"  ! release is missing: {', '.join(missing)} (those buttons link to Releases)")
else:
    print(f"  downloads -> {TAG} " + " ".join(f"{k}:{v['mb']}MB" for k, v in DOWNLOADS.items()))

ICON_B64 = base64.b64encode((HERE / "icon256.png").read_bytes()).decode() \
    if (HERE / "icon256.png").exists() else ""

REPO = "https://github.com/6gx42o/isaac-companion"

HTML = r"""<title>Isaac Companion &#8212; know what you just picked up</title>
<style>
:root{
  color-scheme:dark;
  --void:#080405;--pit:#0e0709;--panel:#150b0e;--panel2:#1b0f13;--rule:#331a1f;--rule2:#4a2229;
  --ash:#e8d9c6;--dim:#9a7f75;--faint:#6b5450;
  --mark:#b81f22;--hot:#e2542b;--warn:#d9a441;--good:#7e9c46;
  --glowTop:rgba(184,31,34,.17);--glowBot:rgba(0,0,0,.8);--scan:rgba(0,0,0,.26);
  --bloom:rgba(232,217,198,.15);--bloomHot:rgba(226,84,43,.38);
  --goodLine:#3d4a24;--markLine:#5c1c1e;
  --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
  --serif:ui-serif,"New York",Georgia,serif;
  --sans:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
  --t:200ms;--tS:420ms;--ease:cubic-bezier(.2,.8,.2,1);
}
:root[data-theme="angel"]{
  color-scheme:light;
  --void:#f4f1e9;--pit:#efeade;--panel:#fbf8f1;--panel2:#f5f0e4;--rule:#ddd4c0;--rule2:#cabfa5;
  --ash:#2c2620;--dim:#6d6455;--faint:#948a76;
  --mark:#a02b26;--hot:#b8860f;--warn:#a9741a;--good:#5c7a34;
  --glowTop:rgba(226,195,106,.34);--glowBot:rgba(255,255,255,.55);--scan:rgba(120,105,70,.05);
  --bloom:rgba(44,38,32,.07);--bloomHot:rgba(184,134,15,.22);
  --goodLine:#a8bd86;--markLine:#d9a9a3;
}
.noT,.noT *,.noT *::before,.noT *::after{transition:none!important}
*{box-sizing:border-box}
html{background:var(--void)}
body{margin:0;background:var(--void);color:var(--ash);font-family:var(--sans);font-size:15px;
  line-height:1.6;-webkit-font-smoothing:antialiased;overflow-x:hidden}
body::before{content:"";position:fixed;inset:0;pointer-events:none;z-index:0;
  background:radial-gradient(58% 34% at 50% -8%,var(--glowTop),transparent 70%),
             radial-gradient(95% 65% at 50% 112%,var(--glowBot),transparent 62%)}
body::after{content:"";position:fixed;inset:0;pointer-events:none;z-index:900;
  background:repeating-linear-gradient(0deg,var(--scan) 0 1px,transparent 1px 3px)}
#rain{position:fixed;inset:0;z-index:0;pointer-events:none;opacity:.5}

/* ---- chrome ---- */
nav{position:sticky;top:0;z-index:50;display:flex;align-items:center;gap:6px;
  padding:10px 22px;background:color-mix(in srgb,var(--void) 88%,transparent);
  border-bottom:1px solid var(--rule2);backdrop-filter:blur(10px)}
.brand{font-family:var(--serif);font-size:15px;margin-right:14px}
.brand b{color:var(--mark)}
nav button,nav a.navlink{background:none;border:1px solid transparent;color:var(--faint);
  padding:5px 11px;border-radius:2px;font-family:var(--mono);font-size:10px;letter-spacing:.16em;
  text-transform:uppercase;cursor:pointer;text-decoration:none;
  transition:color var(--t) var(--ease),border-color var(--t) var(--ease),background-color var(--t) var(--ease)}
nav button.on{background:var(--panel);color:var(--ash);border-color:var(--rule2)}
nav button:hover,nav a.navlink:hover{color:var(--ash);border-color:var(--mark)}
nav .sp{flex:1}
:focus-visible{outline:2px solid var(--hot);outline-offset:2px}

.view{display:none;position:relative;z-index:1}
.view.on{display:block}
.wrap{max-width:1080px;margin:0 auto;padding:0 22px}

/* ---- hero ---- */
.hero{min-height:min(82vh,720px);display:grid;align-content:center;gap:22px;padding:70px 0 60px;position:relative}
.eyebrow{font-family:var(--mono);font-size:10.5px;letter-spacing:.28em;text-transform:uppercase;
  color:var(--mark);opacity:0;animation:fadeUp .7s var(--ease) .1s forwards}
h1{font-family:var(--serif);font-size:clamp(38px,7.6vw,86px);line-height:.98;margin:0;
  letter-spacing:-.025em;text-wrap:balance;text-shadow:0 0 40px var(--bloomHot)}
h1 span{display:inline-block;white-space:pre;opacity:0;transform:translateY(22px) rotate(-2deg);
  animation:drop .8s var(--ease) forwards}
h1 em{font-style:normal;color:var(--hot)}
.sell{max-width:56ch;font-size:17.5px;color:var(--dim);margin:0;
  opacity:0;animation:fadeUp .7s var(--ease) .75s forwards}
.sell b{color:var(--ash);font-weight:600}
.cta{display:flex;gap:11px;flex-wrap:wrap;opacity:0;animation:fadeUp .7s var(--ease) .95s forwards}
.btn{font-family:var(--mono);font-size:11px;letter-spacing:.16em;text-transform:uppercase;
  padding:13px 22px;border:1px solid var(--mark);color:var(--ash);background:var(--panel);
  text-decoration:none;border-radius:2px;cursor:pointer;position:relative;overflow:hidden;
  transition:transform var(--t) var(--ease),border-color var(--t) var(--ease)}
.btn:hover{transform:translateY(-2px);border-color:var(--hot)}
.btn::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,transparent,
  color-mix(in srgb,var(--hot) 26%,transparent),transparent);transform:translateX(-120%)}
.btn:hover::after{animation:shine .75s var(--ease)}
.btn.ghost{border-color:var(--rule2);background:none;color:var(--dim)}
.btn.ghost:hover{color:var(--ash)}

@keyframes drop{to{opacity:1;transform:none}}
@keyframes fadeUp{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
@keyframes shine{to{transform:translateX(120%)}}
@keyframes pulseDot{0%,62%{opacity:1}63%,100%{opacity:.25}}
@keyframes floaty{0%,100%{transform:translateY(0)}50%{transform:translateY(-7px)}}

/* the hero's live specimen */
.specimen{position:absolute;right:2%;top:50%;transform:translateY(-50%);
  width:190px;height:190px;display:grid;place-items:center;opacity:0;
  animation:fadeUp .9s var(--ease) 1.1s forwards}
.specimen .halo{position:absolute;inset:0;border-radius:50%;
  background:radial-gradient(circle,color-mix(in srgb,var(--hot) 26%,transparent),transparent 68%);
  animation:floaty 5s ease-in-out infinite}
.specimen .spr{width:96px;height:96px;image-rendering:pixelated;animation:floaty 5s ease-in-out infinite;
  filter:drop-shadow(0 0 16px color-mix(in srgb,var(--hot) 45%,transparent))}
.specimen .cap{position:absolute;bottom:-4px;font-family:var(--mono);font-size:9px;
  letter-spacing:.16em;text-transform:uppercase;color:var(--faint);white-space:nowrap}
@media(max-width:900px){.specimen{display:none}}

/* ---- reveal on scroll ---- */
.rv{opacity:0;transform:translateY(20px);transition:opacity .65s var(--ease),transform .65s var(--ease)}
.rv.in{opacity:1;transform:none}

section.band{padding:74px 0;border-top:1px solid var(--rule)}
h2{font-family:var(--serif);font-size:clamp(24px,3.4vw,36px);margin:0 0 10px;letter-spacing:-.015em;text-wrap:balance}
.lead{color:var(--dim);max-width:62ch;margin:0 0 30px;font-size:16px}
.grid{display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule);
  grid-template-columns:repeat(auto-fit,minmax(238px,1fr))}
.card{background:var(--panel);padding:20px 20px 22px;transition:background-color var(--t) var(--ease)}
.card:hover{background:var(--panel2)}
.card .n{font-family:var(--mono);font-size:9px;letter-spacing:.2em;color:var(--mark);text-transform:uppercase}
.card h3{font-family:var(--serif);font-size:19px;margin:9px 0 7px;font-weight:400}
.card p{margin:0;color:var(--dim);font-size:13.5px;line-height:1.55}

/* the fake app readout used on the home page */
.demo{border:1px solid var(--rule2);background:var(--pit);border-radius:3px;overflow:hidden;
  box-shadow:0 26px 70px -30px color-mix(in srgb,var(--mark) 40%,transparent)}
.demo .bar{display:flex;gap:7px;align-items:center;padding:9px 13px;background:var(--void);
  border-bottom:1px solid var(--rule2)}
.demo .bar i{width:9px;height:9px;border-radius:50%;display:block}
.demo .bar span{margin-left:7px;font-family:var(--mono);font-size:9px;letter-spacing:.2em;
  text-transform:uppercase;color:var(--faint)}
.demo .in{padding:16px 18px 20px}
.rail{display:grid;grid-template-columns:repeat(auto-fit,minmax(96px,1fr));gap:1px;
  background:var(--rule);border:1px solid var(--rule)}
.cellx{background:var(--panel);padding:9px 11px 11px}
.cellx .k{font-family:var(--mono);font-size:8px;letter-spacing:.2em;text-transform:uppercase;color:var(--faint)}
.cellx .v{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:21px;margin-top:3px;
  text-shadow:0 0 12px var(--bloom)}
.cellx.hot .v{color:var(--hot);text-shadow:0 0 14px var(--bloomHot)}
.mtr{height:4px;margin-top:8px;background:color-mix(in srgb,var(--rule) 70%,transparent);
  border:1px solid var(--rule2);position:relative;overflow:hidden}
.mtr i{position:absolute;inset:0 auto 0 0;display:block;background:var(--good);width:0;
  transition:width 1.1s var(--ease)}
.mtr.dn i{background:var(--warn)}
.mini{margin-top:13px;display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule)}
.mrow{background:var(--panel);display:flex;gap:10px;padding:8px 10px;align-items:flex-start}
.mrow.dead{background:color-mix(in srgb,var(--mark) 12%,var(--panel));box-shadow:inset 3px 0 0 var(--mark)}
.mrow.dead .nm{color:var(--dim);text-decoration:line-through;text-decoration-color:var(--mark)}
.mrow .nm{font-family:var(--serif);font-size:14px}
.mrow .ds{color:var(--dim);font-size:11.5px;margin-top:2px}
.mrow .ds.cut{color:var(--warn)}
.spr{width:28px;height:28px;flex:none;image-rendering:pixelated;background-repeat:no-repeat;
  background-image:var(--sheet-items)}
.foe{background-image:var(--sheet-mon)}
.badge{background-image:var(--sheet-bdg)}
.pillspr{background-image:var(--sheet-pills)}

/* ---- sprites that play their own frames ----
   One @keyframes for both cases: the endpoints are custom properties set per
   element, so walking a 3-frame enemy cell and cycling 13 pill colours are the
   same rule with different numbers. The frames are already in a sheet the page
   has loaded, so this costs no extra bytes and no script.
   background-position-x alone -- the y offset picks the atlas ROW and must not
   move, and animating the shorthand would reset it every frame. */
@keyframes spriteStrip{
  from{background-position-x:var(--strip-x,0px)}
  to{background-position-x:var(--strip-end)}
}
/* Enemies: deliberately slower than the game's 30fps. Forty rows each twitching
   at 30fps is a wall of noise; this reads as breathing. */
.sprite-anim{--strip-run:spriteStrip .72s steps(var(--strip-steps,3)) infinite}
/* Pills: slower still. It is a colour cycle, not motion. The real step count
   arrives on the element as --strip-steps (pillInto reads it off the strip). The
   literal is not a second source of truth -- it is only there because an
   unresolvable var() inside steps() invalidates the whole `animation` shorthand,
   taking the idle bob with it. pillInto always sets it, so it is never used.

   Every pill runs the SAME cycle in the SAME phase. Nothing about a pill's colour
   is per-pill -- the game reshuffles the mapping each run -- so pills showing
   different colours from each other implies a distinction that does not exist.
   A shared clock makes the list read as one deck being riffled. A 0s delay is not
   enough on its own: a CSS animation starts when its element is created and rows
   arrive in batches as you scroll, so pillInto sets --strip-d to a negative offset
   from a common origin. --pill-cycle is the single place the period is written. */
:root{--pill-cycle:3400ms}
.pillspr{--strip-run:spriteStrip var(--pill-cycle) steps(var(--strip-steps,13)) infinite}

/* The detail card's sprite sits outside the list idle rules, so it declares its
   own animation to play the same frames. */
#dbody .top :is(.spr,.foe){animation:var(--strip-run,none 0s)}


/* ---- open source ---- */
.osslead{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(190px,auto);gap:30px;
  align-items:start}
@media(max-width:760px){.osslead{grid-template-columns:1fr}}
.ossfacts{display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule)}
.ossfact{background:var(--panel);padding:13px 16px;display:flex;align-items:baseline;gap:9px}
.ossfact b{font-family:var(--mono);font-size:21px;color:var(--hot);
  font-variant-numeric:tabular-nums}
.ossfact span{font-family:var(--mono);font-size:9px;letter-spacing:.18em;
  text-transform:uppercase;color:var(--faint)}
.btn.ghost{border-color:var(--rule2);background:none;color:var(--dim)}
.btn.ghost:hover{color:var(--ash);border-color:var(--mark)}

/* ---- get it: icon, platform check, download cards ---- */
.getlead{display:flex;gap:20px;align-items:flex-start;margin-bottom:22px}
.appicon{flex:0 0 auto;border-radius:20px;image-rendering:auto;
  filter:drop-shadow(0 10px 26px rgba(0,0,0,.55))}
@media(max-width:640px){.getlead{gap:14px}.appicon{width:64px;height:64px}}

/* What we think you are on. Amber while unknown, green on a Mac, red where the app
   cannot run at all -- the same three-state vocabulary as the run badge. */
.detect{display:inline-flex;align-items:center;gap:9px;margin:0 0 18px;
  padding:8px 13px;border:1px solid var(--rule2);border-radius:3px;background:var(--panel);
  font-family:var(--mono);font-size:11px;letter-spacing:.08em;color:var(--dim)}
.detect .dot{width:6px;height:6px;border-radius:50%;background:var(--warn);flex:none}
.detect.ok .dot{background:var(--good)}
.detect.no .dot{background:var(--mark)}
.detect.no{border-color:var(--markLine)}
.detect b{color:var(--ash);font-weight:600}

/* The one button. Big enough that it is the first thing you reach for and the only
   thing you have to understand -- it names the exact build you are getting and how
   big it is, so nothing is hidden behind the size of it. */
.dlhero{margin:4px 0 0}
.dlmain{display:flex;align-items:center;gap:18px;width:100%;max-width:520px;
  text-decoration:none;
  padding:20px 26px;cursor:pointer;text-align:left;
  background:var(--panel);color:var(--ash);
  border:1px solid var(--mark);border-radius:3px;position:relative;overflow:hidden;
  transition:transform var(--t) var(--ease),border-color var(--t) var(--ease),
             background-color var(--t) var(--ease),box-shadow var(--t) var(--ease)}
.dlmain:hover{transform:translateY(-2px);border-color:var(--hot);background:var(--panel2);
  box-shadow:0 16px 40px -18px color-mix(in srgb,var(--mark) 70%,transparent)}
.dlmain:active{transform:translateY(0)}
.dlmain:focus-visible{outline:2px solid var(--hot);outline-offset:3px}
/* the sheen the other buttons on this page use, so it belongs to the same family */
.dlmain::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,
  transparent,color-mix(in srgb,var(--hot) 22%,transparent),transparent);
  transform:translateX(-120%)}
.dlmain:hover::after{animation:shine .75s var(--ease)}
.dlmain-arrow{flex:0 0 auto;width:38px;height:38px;display:grid;place-items:center;
  border:1px solid var(--rule2);border-radius:50%;font-size:17px;color:var(--hot);
  transition:border-color var(--t) var(--ease),transform var(--t) var(--ease)}
.dlmain:hover .dlmain-arrow{border-color:var(--hot);transform:translateY(2px)}
.dlmain-text{display:flex;flex-direction:column;gap:3px;min-width:0}
.dlmain-title{font-family:var(--mono);font-size:13px;letter-spacing:.14em;
  text-transform:uppercase;color:var(--ash)}
.dlmain-sub{font-family:var(--mono);font-size:10.5px;letter-spacing:.08em;
  color:var(--faint);font-variant-numeric:tabular-nums}
.dlmain-note{color:var(--dim);font-size:12.5px;margin:11px 0 0;max-width:56ch}

/* Everything else, deliberately quiet: present for the people who want a pkg or are
   downloading for another machine, invisible as a decision for everyone else. */
.dlalt{display:flex;flex-wrap:wrap;align-items:center;gap:7px;margin:22px 0 0}
.dlalt-label{font-family:var(--mono);font-size:9px;letter-spacing:.18em;
  text-transform:uppercase;color:var(--faint);margin-right:3px}
.chip.dlopt.current{border-color:var(--hot);color:var(--ash)}
.chip.dlopt.current::after{content:" \2713";color:var(--hot)}

/* ---- item index ---- */
.searchwrap{position:sticky;top:49px;z-index:40;padding:20px 0 12px;
  background:linear-gradient(var(--void) 72%,transparent)}
#q,#fq,#aq{width:100%;background:var(--panel);border:1px solid var(--rule2);color:var(--ash);
  padding:14px 16px;font-size:16px;font-family:inherit;border-radius:2px;
  transition:border-color var(--t) var(--ease),box-shadow var(--t) var(--ease)}
#q:focus,#fq:focus,#aq:focus{border-color:var(--hot);box-shadow:0 0 0 3px color-mix(in srgb,var(--hot) 18%,transparent);outline:none}
#q::placeholder,#fq::placeholder,#aq::placeholder{color:var(--faint)}
.chips{display:flex;flex-wrap:wrap;gap:5px;margin-top:10px}
.chip{font-family:var(--mono);font-size:9.5px;letter-spacing:.12em;text-transform:uppercase;
  padding:4px 9px;border:1px solid var(--rule2);color:var(--faint);cursor:pointer;border-radius:2px;
  background:none;transition:all var(--t) var(--ease)}
.chip:hover{color:var(--ash);border-color:var(--dim)}
.chip.on{color:var(--ash);border-color:var(--hot);background:var(--panel)}
.chip .sw{display:inline-block;width:7px;height:7px;margin-right:6px;vertical-align:0;border-radius:1px;
  border:1px solid rgba(128,128,128,.45)}
.count{font-family:var(--mono);font-size:10px;letter-spacing:.1em;color:var(--faint);margin:10px 0 14px}

.items{display:grid;gap:1px;background:var(--rule);border:1px solid var(--rule);
  grid-template-columns:repeat(auto-fill,minmax(268px,1fr));padding-bottom:60px}
/* Tried content-visibility:auto here to skip off-screen rows. It made things worse,
   measurably: it defers each row's rasterization into the scroll itself, and with a
   megapixel sheet behind every sprite that cost lands frame by frame -- enemies fell
   from 118fps to 46, achievements to 28. The upfront cost is the cheaper trade. */
.it{background:var(--panel);padding:11px 12px;display:flex;gap:11px;align-items:flex-start;
  cursor:pointer;transition:background-color var(--t) var(--ease)}
.it:hover{background:var(--panel2)}
.it:hover .spr{transform:scale(1.14)}
.it .spr{transition:transform var(--t) var(--ease)}
.it .nm{font-family:var(--serif);font-size:14.5px;line-height:1.2}
.it .meta{font-family:var(--mono);font-size:9px;letter-spacing:.1em;text-transform:uppercase;
  color:var(--faint);margin-top:3px}
.it .ds{color:var(--dim);font-size:11.5px;margin-top:4px;line-height:1.45;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.dots{display:flex;gap:3px;margin-top:5px}
.lock{color:var(--warn)}
.pools.unknown{color:var(--faint);font-style:italic}
.dots i{width:8px;height:8px;border-radius:1px;display:block;border:1px solid rgba(128,128,128,.4)}
.none{padding:50px 0;color:var(--faint);text-align:center}
.more{grid-column:1/-1;height:1px}
/* =========================================================
   EFFECT-SIGNATURE BACKGROUNDS — append AFTER the per-item
   variation block. The background is the signature of the
   EFFECT, so every poison item looks identical.

   This block does two jobs:
     A. neutralises the per-item variation layer (the --i-*
        props may still be inline on the element; they are
        read here nowhere and their outputs are overwritten);
     B. redraws all twelve families so each one has its own
        motion character, composition and colour identity.

   Specificity note: the per-item rules are
     .fxbg[data-eff-real]:not([data-eff-real=""])::before   -> 0-3-1
   so every rule below carries a fourth, always-true
   [class] term (the element must have .fxbg to be here at
   all) -> 0-4-1. Order alone would be enough; this makes it
   robust if the blocks are ever reordered.

   Still one ::before, still transform + opacity only, peak
   opacity 0.10-0.22, .no-bg-anim / reduced-motion still
   freeze via --eff-still / --eff-still-o.
   ========================================================= */

/* ---- A. neutralise the per-item layer -------------------- */

/* The old chain ends at --e1/--e2/--e3; point them at the family
   colours so even that dead output is family-only. Nothing below
   reads --i-hue / --i-seed / --i-speed / --i-dense / --i-c1 /
   --i-c2 or any of the --_* intermediates. */
.fxbg[class][data-eff-real]:not([data-eff-real=""]){
  --e1: var(--f1);
  --e2: var(--f2);
  --e3: var(--f3, var(--f2));
}

/* Every geometric/temporal knob the per-item rule set is reset
   here. background-position / background-size are additionally
   reset by each family's `background:` shorthand below. */
.fxbg[class][data-eff-real]:not([data-eff-real=""])::before{
  translate: none;
  rotate: none;
  scale: none;
  transform-origin: 50% 50%;
  background-position: 0 0;
  background-size: auto auto;
  background-repeat: no-repeat;
  filter: none;
  animation-delay: 0s;
  animation-iteration-count: infinite;
  animation-fill-mode: none;
  animation-play-state: running;
}

/* ---- B. the twelve signatures ----------------------------

   The previous set gave each family its own hue and its own
   keyframes, and they still read as one effect twelve times:
   nine of the twelve were soft radial blobs drifting a few
   percent, so the only thing that actually changed between
   poison and smoke and blood was the colour.

   What separates them now is not colour, it is BEHAVIOUR —
   each family gets a different form, a different direction of
   travel and a different rhythm, taken from what the effect
   does in the game:

     poison  bubbles rise           up, steady        seamless scroll
     fire    tongues lick           anchored, fast    stepped flicker
     blood   drips run              down, steady      seamless scroll
     creep   a puddle spreads       outward, once     scale from floor
     frost   ice holds, then cracks still, rare       stepped blink
     charm   a heartbeat            pulse from centre double beat
     luck    glints twinkle         nowhere, discrete stepped opacity
     shock   arcs snap              nowhere, instant  steps(1) poses
     smoke   billows drift          sideways, slow    seamless scroll
     dark    everything is pulled   inward            scale down + spin
     holy    light falls in beams   static            width breathe
     spark   a beam sweeps          across, fast      seamless scroll

   The scrolling families (poison, blood, smoke, spark) tile
   every layer on ONE background-size and travel exactly one
   tile per cycle, so the loop is seamless and the motion stays
   on `transform` — one composited layer, no per-frame repaint,
   which is what keeps this affordable on the card.
   ========================================================= */

/* POISON — bile bubbles rising through the card.
   Four bubbles per tile at four sizes; the whole layer scrolls
   up exactly one tile, so they never visibly wrap. */
.fxbg[class][data-eff-real="poison"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, var(--good) 80%, var(--ash));
  --f2: var(--good);
  --f3: color-mix(in oklab, var(--good) 46%, var(--void));
  --eff-still: translate3d(0, -34px, 0);
  --eff-still-o: .18;
}
.fxbg[class][data-eff-real="poison"]:not([data-eff-real=""])::before{
  background:
    radial-gradient(circle at 22% 20%, var(--f1) 0 2.6%, transparent 3.4%),
    radial-gradient(circle at 68% 44%, var(--f2) 0 4.2%, transparent 5.2%),
    radial-gradient(circle at 41% 74%, var(--f1) 0 3.1%, transparent 3.9%),
    radial-gradient(circle at 86% 86%, var(--f3) 0 5.6%, transparent 6.8%);
  background-size: 168px 168px;
  background-repeat: repeat;
  animation: bgPoisonRise 9s linear infinite;
}
@keyframes bgPoisonRise{
  0%   { transform: translate3d(0, 0, 0);      opacity: .13; }
  50%  { transform: translate3d(0, -84px, 0);  opacity: .21; }
  100% { transform: translate3d(0, -168px, 0); opacity: .13; }
}

/* FIRE — tongues anchored to the bottom edge, licking upward.
   Nothing travels: the height pulses and the brightness
   flickers on a stepped curve, which is what fire does. */
.fxbg[class][data-eff-real="fire"]:not([data-eff-real=""]){
  --f1: var(--hot);
  --f2: var(--warn);
  --f3: color-mix(in oklab, var(--mark) 72%, var(--hot));
  --eff-still: scaleY(1.06);
  --eff-still-o: .19;
}
.fxbg[class][data-eff-real="fire"]:not([data-eff-real=""])::before{
  /* 81%, not 100%. ::before is inset:-30%, so its box is 160% of the card and the
     card's own bottom edge sits at 130/160 = 81.25% of it. Anchoring to 100% put
     the flames a third of a card BELOW anything anyone can see. */
  transform-origin: 50% 81%;
  background:
    radial-gradient(22% 26% at 18% 81%, var(--f1) 0%, transparent 72%),
    radial-gradient(16% 37% at 38% 81%, var(--f2) 0%, transparent 70%),
    radial-gradient(26% 22% at 58% 81%, var(--f1) 0%, transparent 74%),
    radial-gradient(14% 33% at 79% 81%, var(--f2) 0%, transparent 70%),
    radial-gradient(72% 16% at 50% 84%, var(--f3) 0%, transparent 76%);
  animation: bgFireLick 2.8s steps(1, end) infinite;
}
@keyframes bgFireLick{
  0%   { transform: scaleY(1.00) scaleX(1.00); opacity: .10; }
  14%  { transform: scaleY(1.22) scaleX(0.97); opacity: .21; }
  28%  { transform: scaleY(1.06) scaleX(1.03); opacity: .13; }
  42%  { transform: scaleY(1.31) scaleX(0.99); opacity: .19; }
  56%  { transform: scaleY(1.02) scaleX(1.02); opacity: .11; }
  70%  { transform: scaleY(1.25) scaleX(0.98); opacity: .22; }
  86%  { transform: scaleY(1.10) scaleX(1.01); opacity: .14; }
  100% { transform: scaleY(1.00) scaleX(1.00); opacity: .10; }
}

/* BLOOD — thin drips running DOWN. Same seamless-tile trick as
   poison, travelling the other way and much slower. */
.fxbg[class][data-eff-real="blood"]:not([data-eff-real=""]){
  --f1: var(--mark);
  --f2: color-mix(in oklab, var(--mark) 58%, var(--void));
  --eff-still: translate3d(0, 46px, 0);
  --eff-still-o: .16;
}
.fxbg[class][data-eff-real="blood"]:not([data-eff-real=""])::before{
  /* Tall thin ellipses. A linear-gradient cannot be narrow AND long at once: it
     spans its whole tile on one axis, so vertical stripes tiled across x merged
     back into continuous horizontal bands. An ellipse is bounded on both axes,
     so each one is a single drip with dark either side of it. */
  background:
    radial-gradient(2.4% 19% at 17% 22%, var(--f1) 0%, transparent 76%),
    radial-gradient(1.9% 14% at 43% 58%, var(--f2) 0%, transparent 74%),
    radial-gradient(2.8% 23% at 66% 12%, var(--f1) 0%, transparent 78%),
    radial-gradient(2.0% 16% at 88% 66%, var(--f2) 0%, transparent 74%),
    radial-gradient(3.6% 2.8% at 43% 76%, var(--f1) 0%, transparent 70%),
    radial-gradient(3.0% 2.4% at 17% 44%, var(--f1) 0%, transparent 70%);
  background-size: 220px 220px;
  background-repeat: repeat;
  animation: bgBloodDrip 17s linear infinite;
}
@keyframes bgBloodDrip{
  0%   { transform: translate3d(0, 0, 0);      opacity: .15; }
  50%  { transform: translate3d(0, 110px, 0);  opacity: .24; }
  100% { transform: translate3d(0, 220px, 0);  opacity: .15; }
}

/* CREEP — a puddle spreading across the floor. Grows from the
   bottom edge and holds near full for most of the cycle, the
   way creep pools and then just sits there. */
.fxbg[class][data-eff-real="creep"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, var(--mark) 62%, var(--good));
  --f2: color-mix(in oklab, var(--good) 52%, var(--pit));
  --eff-still: scale(1.18);
  --eff-still-o: .17;
}
.fxbg[class][data-eff-real="creep"]:not([data-eff-real=""])::before{
  /* Anchored to the card's floor at 81%, see FIRE. */
  transform-origin: 50% 81%;
  background:
    radial-gradient(30% 6% at 26% 72%, var(--f1) 0%, transparent 68%),
    radial-gradient(24% 5% at 62% 76%, var(--f2) 0%, transparent 70%),
    radial-gradient(18% 4% at 82% 69%, var(--f1) 0%, transparent 66%),
    radial-gradient(40% 8% at 46% 80%, var(--f2) 0%, transparent 74%);
  animation: bgCreepSpread 15s cubic-bezier(.14, .82, .32, 1) infinite;
}
@keyframes bgCreepSpread{
  0%   { transform: scale(.55);  opacity: .08; }
  38%  { transform: scale(1.16); opacity: .21; }
  76%  { transform: scale(1.30); opacity: .18; }
  92%  { transform: scale(1.34); opacity: .07; }
  100% { transform: scale(.55);  opacity: .08; }
}

/* FROST — a frozen lattice that mostly does not move at all,
   then cracks. The long dead stretch IS the effect; anything
   continuous would read as drifting fog instead of ice. */
.fxbg[class][data-eff-real="frost"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, #8fd3ff 66%, var(--ash));
  --f2: color-mix(in oklab, #d6ecff 50%, var(--ash));
  --eff-still: rotate(.4deg) scale(1.04);
  --eff-still-o: .15;
}
.fxbg[class][data-eff-real="frost"]:not([data-eff-real=""])::before{
  background:
    repeating-linear-gradient(58deg, transparent 0 30px, var(--f1) 30px 31px, transparent 31px 62px),
    repeating-linear-gradient(-58deg, transparent 0 38px, var(--f1) 38px 39px, transparent 39px 78px),
    repeating-linear-gradient(0deg, transparent 0 54px, var(--f2) 54px 55px, transparent 55px 110px),
    radial-gradient(58% 48% at 50% 44%, var(--f2) 0%, transparent 76%);
  animation: bgFrostCrack 13s steps(1, end) infinite;
}
@keyframes bgFrostCrack{
  0%   { transform: rotate(0deg) scale(1.02);   opacity: .13; }
  70%  { transform: rotate(0deg) scale(1.02);   opacity: .13; }  /* held: ice does nothing */
  73%  { transform: rotate(.5deg) scale(1.05);  opacity: .22; }  /* crack */
  76%  { transform: rotate(-.3deg) scale(1.03); opacity: .11; }
  79%  { transform: rotate(.2deg) scale(1.06);  opacity: .20; }
  84%  { transform: rotate(0deg) scale(1.02);   opacity: .13; }
  100% { transform: rotate(0deg) scale(1.02);   opacity: .13; }
}

/* CHARM — a heartbeat. Two beats close together, then a rest;
   the double beat is what makes it read as a heart and not as
   a generic pulse. */
.fxbg[class][data-eff-real="charm"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, #ff8ec2 64%, var(--mark));
  --f2: color-mix(in oklab, #ffc7e2 54%, var(--ash));
  --eff-still: scale(1.10);
  --eff-still-o: .17;
}
.fxbg[class][data-eff-real="charm"]:not([data-eff-real=""])::before{
  transform-origin: 50% 52%;
  background:
    radial-gradient(19% 21% at 41% 42%, var(--f1) 0%, transparent 70%),
    radial-gradient(19% 21% at 59% 42%, var(--f1) 0%, transparent 70%),
    radial-gradient(26% 30% at 50% 56%, var(--f1) 0%, transparent 68%),
    radial-gradient(64% 58% at 50% 50%, transparent 30%, var(--f2) 88%);
  animation: bgCharmBeat 4.2s cubic-bezier(.3, 0, .2, 1) infinite;
}
@keyframes bgCharmBeat{
  0%   { transform: scale(1.00); opacity: .11; }
  8%   { transform: scale(1.13); opacity: .22; }   /* lub */
  16%  { transform: scale(1.02); opacity: .13; }
  24%  { transform: scale(1.09); opacity: .19; }   /* dub */
  34%  { transform: scale(1.00); opacity: .11; }
  100% { transform: scale(1.00); opacity: .11; }   /* rest */
}

/* LUCK — glints that twinkle where they are. Four-point stars,
   stepped so they blink on and off rather than fading: a glint
   that eases is a lens flare, not luck. */
.fxbg[class][data-eff-real="luck"]:not([data-eff-real=""]){
  --f1: var(--warn);
  --f2: color-mix(in oklab, var(--warn) 58%, var(--ash));
  --eff-still: none;
  --eff-still-o: .17;
}
.fxbg[class][data-eff-real="luck"]:not([data-eff-real=""])::before{
  /* Crossed ELLIPSES, not crossed lines. Full-width lines tile into a tartan --
     which is what this drew before -- because each layer spans the whole cell.
     A flat ellipse over a tall one meets only at its centre, so each pair is one
     isolated four-point glint with dark between them. */
  background:
    radial-gradient(14% 1.1% at 29% 27%, var(--f1) 0%, transparent 72%),
    radial-gradient(1.1% 14% at 29% 27%, var(--f1) 0%, transparent 72%),
    radial-gradient(9% .8% at 71% 63%, var(--f2) 0%, transparent 70%),
    radial-gradient(.8% 9% at 71% 63%, var(--f2) 0%, transparent 70%),
    radial-gradient(6% .6% at 52% 86%, var(--f1) 0%, transparent 68%),
    radial-gradient(.6% 6% at 52% 86%, var(--f1) 0%, transparent 68%);
  background-size: 118px 118px;
  background-repeat: repeat;
  animation: bgLuckTwinkle 3.6s steps(1, end) infinite;
}
@keyframes bgLuckTwinkle{
  0%   { opacity: .08; transform: scale(1.00) rotate(0deg); }
  16%  { opacity: .30; transform: scale(1.04) rotate(6deg); }
  32%  { opacity: .11; transform: scale(1.00) rotate(0deg); }
  48%  { opacity: .26; transform: scale(1.07) rotate(-5deg); }
  64%  { opacity: .10; transform: scale(1.01) rotate(2deg); }
  80%  { opacity: .32; transform: scale(1.03) rotate(-3deg); }
  100% { opacity: .08; transform: scale(1.00) rotate(0deg); }
}

/* SHOCK — arcs. steps(1) throughout, so every frame is an
   instant jump: electricity has no in-between poses. Bolts are
   thin diagonals, not the concentric rings this used to draw —
   rings read as sonar. */
.fxbg[class][data-eff-real="shock"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, #9fe4ff 62%, var(--ash));
  --f2: color-mix(in oklab, var(--warn) 48%, var(--ash));
  --eff-still: skewX(-8deg) scale(1.04);
  --eff-still-o: .16;
}
.fxbg[class][data-eff-real="shock"]:not([data-eff-real=""])::before{
  background:
    repeating-linear-gradient(72deg, transparent 0 46px, var(--f1) 46px 47.4px, transparent 47.4px 94px),
    repeating-linear-gradient(-64deg, transparent 0 68px, var(--f2) 68px 69.2px, transparent 69.2px 138px),
    repeating-linear-gradient(84deg, transparent 0 112px, var(--f1) 112px 113px, transparent 113px 226px);
  animation: bgShockArc 1.9s steps(1, end) infinite;
}
@keyframes bgShockArc{
  0%   { transform: skewX(0deg) scaleY(1.00) translate3d(0, 0, 0);       opacity: .07; }
  8%   { transform: skewX(-11deg) scaleY(1.06) translate3d(3%, -2%, 0);  opacity: .30; }
  22%  { transform: skewX(-9deg) scaleY(1.04) translate3d(2%, -1%, 0);   opacity: .24; }
  30%  { transform: skewX(0deg) scaleY(1.00) translate3d(0, 0, 0);       opacity: .06; }
  46%  { transform: skewX(9deg) scaleY(.94) translate3d(-4%, 3%, 0);     opacity: .28; }
  58%  { transform: skewX(0deg) scaleY(1.00) translate3d(0, 0, 0);       opacity: .06; }
  74%  { transform: skewX(-6deg) scaleY(1.09) translate3d(2%, 2%, 0);    opacity: .26; }
  86%  { transform: skewX(0deg) scaleY(1.00) translate3d(0, 0, 0);       opacity: .06; }
  100% { transform: skewX(0deg) scaleY(1.00) translate3d(0, 0, 0);       opacity: .07; }
}

/* SMOKE — billows drifting SIDEWAYS, the one family that
   travels horizontally. Big and soft; the blur is the point. */
.fxbg[class][data-eff-real="smoke"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, var(--dim) 68%, var(--ash));
  --f2: color-mix(in oklab, var(--faint) 72%, var(--ash));
  --eff-still: translate3d(-130px, 0, 0) scale(1.05);
  --eff-still-o: .15;
}
.fxbg[class][data-eff-real="smoke"]:not([data-eff-real=""])::before{
  background:
    radial-gradient(circle at 24% 36%, var(--f1) 0 9%, transparent 17%),
    radial-gradient(circle at 63% 62%, var(--f2) 0 12%, transparent 21%),
    radial-gradient(circle at 88% 22%, var(--f1) 0 7%, transparent 15%);
  background-size: 260px 260px;
  background-repeat: repeat;
  filter: blur(9px);
  animation: bgSmokeDrift 21s linear infinite;
}
@keyframes bgSmokeDrift{
  0%   { transform: translate3d(0, 0, 0) scale(1.04);        opacity: .12; }
  50%  { transform: translate3d(-130px, 0, 0) scale(1.10);   opacity: .18; }
  100% { transform: translate3d(-260px, 0, 0) scale(1.04);   opacity: .12; }
}

/* DARK — the void pulls. Everything scales INWARD toward the
   centre while turning; it is the only family that shrinks. */
.fxbg[class][data-eff-real="dark"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, #6b4a8f 62%, var(--ash));
  --f2: color-mix(in oklab, var(--void) 62%, var(--ash));
  --eff-still: scale(1.06) rotate(24deg);
  --eff-still-o: .16;
}
.fxbg[class][data-eff-real="dark"]:not([data-eff-real=""])::before{
  transform-origin: 50% 50%;
  background:
    repeating-radial-gradient(circle at 50% 50%, transparent 0 26px, var(--f1) 26px 28px, transparent 28px 54px),
    radial-gradient(30% 30% at 50% 50%, var(--f2) 0%, transparent 78%),
    radial-gradient(74% 66% at 50% 50%, transparent 34%, var(--f1) 96%);
  animation: bgDarkPull 8.5s cubic-bezier(.28, 0, .5, 1) infinite;
}
@keyframes bgDarkPull{
  0%   { transform: scale(1.46) rotate(0deg);   opacity: .09; }
  40%  { transform: scale(1.02) rotate(58deg);  opacity: .26; }
  78%  { transform: scale(.72) rotate(104deg);  opacity: .20; }
  100% { transform: scale(.52) rotate(140deg);  opacity: .07; }
}

/* HOLY — light falling in beams. The one family that never
   travels and never spins: the beams stand still and only
   breathe wider and narrower, which is why it reads as light
   coming from somewhere rather than as an effect on the card. */
.fxbg[class][data-eff-real="holy"]:not([data-eff-real=""]){
  --f1: color-mix(in oklab, var(--warn) 52%, var(--ash));
  --f2: var(--warn);
  --eff-still: scaleX(1.08);
  --eff-still-o: .17;
}
.fxbg[class][data-eff-real="holy"]:not([data-eff-real=""])::before{
  /* 19% is the card's top edge inside the -30% box, see FIRE. */
  transform-origin: 50% 19%;
  background:
    linear-gradient(184deg, var(--f1) 0%, transparent 62%),
    linear-gradient(176deg, var(--f2) 0%, transparent 54%),
    linear-gradient(190deg, var(--f1) 0%, transparent 48%),
    linear-gradient(172deg, var(--f2) 0%, transparent 58%);
  background-size: 13% 64%, 8% 64%, 17% 64%, 6% 64%;
  background-position: 22% 19%, 38% 19%, 57% 19%, 76% 19%;
  background-repeat: no-repeat;
  animation: bgHolyBeam 11s ease-in-out infinite;
}
@keyframes bgHolyBeam{
  0%   { transform: scaleX(.88); opacity: .10; }
  50%  { transform: scaleX(1.14); opacity: .21; }
  100% { transform: scaleX(.88); opacity: .10; }
}

/* SPARK — a beam sweeping ACROSS. Fast, thin, and horizontal;
   the only family that crosses the card left to right. */
.fxbg[class][data-eff-real="spark"]:not([data-eff-real=""]){
  --f1: var(--warn);
  --f2: color-mix(in oklab, var(--hot) 58%, var(--ash));
  --eff-still: translate3d(120px, 0, 0);
  --eff-still-o: .20;
}
.fxbg[class][data-eff-real="spark"]:not([data-eff-real=""])::before{
  /* Wide-and-flat ellipses: a linear-gradient at 90deg spans its tile's full
     HEIGHT, so a 192px tile drew vertical bars marching sideways -- the opposite
     of a beam. An ellipse bounded on both axes is a streak, and a row of streaks
     travelling x reads as brimstone crossing the room. */
  background:
    radial-gradient(34% 1.5% at 42% 34%, var(--f1) 0%, transparent 74%),
    radial-gradient(22% 1.0% at 76% 52%, var(--f2) 0%, transparent 72%),
    radial-gradient(28% 1.2% at 22% 68%, var(--f1) 0%, transparent 72%);
  background-size: 240px 100%;
  background-repeat: repeat-x;
  animation: bgSparkSweep 2.4s linear infinite;
}
@keyframes bgSparkSweep{
  0%   { transform: translate3d(0, 0, 0);      opacity: .08; }
  30%  { transform: translate3d(72px, 0, 0);   opacity: .24; }
  70%  { transform: translate3d(168px, 0, 0);  opacity: .22; }
  100% { transform: translate3d(240px, 0, 0);  opacity: .08; }
}

/* ---- freeze, restated for the new poses ------------------
   The existing freeze rules already win on `animation` with
   !important; these carry the same transform/opacity at the
   higher specificity so the per-item translate/rotate/scale
   reset above cannot be undone by anything left behind. */
.fxbg[class][data-eff-real]:not([data-eff-real=""]).no-bg-anim::before,
.no-bg-anim .fxbg[class][data-eff-real]:not([data-eff-real=""])::before{
  animation: none !important;
  transform: var(--eff-still, scale(1.04));
  opacity: var(--eff-still-o, .16);
}
@media (prefers-reduced-motion: reduce){
  .fxbg[class][data-eff-real]:not([data-eff-real=""])::before{
    animation: none !important;
    transform: var(--eff-still, scale(1.04));
    opacity: var(--eff-still-o, .16);
  }
}
/* ===========================================================================
   fx-flyer — the sprite in transit.

   Every node with this class is created, animated and destroyed inside one
   fxZoomInto() call. Nothing here is ever applied to something that outlives
   a click, so none of it can leak into the row or the card.
   ========================================================================= */
.fx-flyer{
  position:fixed; left:0; top:0;
  margin:0; padding:0;
  box-sizing:border-box;            /* the rect we matched is a border box */
  transform-origin:0 0;             /* the FLIP maths anchors on the top-left */
  background-repeat:no-repeat;
  image-rendering:pixelated;        /* default; copied off the target inline, so
                                       the 263x176 badge art keeps its own
                                       smooth resampling instead of shredding */
  pointer-events:none;
  /* app: #card sits at 1000 and the scanline overlay at 900. Inside a modal
     <dialog> this is moot — the flyer is parented into the dialog, because
     nothing outside the top layer can paint over it at any z-index. */
  z-index:100000;
  /* One composited layer for the whole flight: the raster is made once, at the
     target's (large) size, and scaled down — so the frame it lands on is the
     native one, not a blown-up 28px texture. */
  will-change:transform, opacity;
  backface-visibility:hidden;
}

/* ===========================================================================
   The card's own arrival.

   Rule one: the panel must not MOVE. fxZoomInto measures the big sprite the
   instant the card is shown, and a panel that is mid-translate/mid-scale hands
   it a landing rect that is 8px low and 1.5% small — the flyer arrives, then
   snaps. So the panel arrives on opacity alone and only the text column rises.
   The sprite's box is pinned from frame one, and the flight (340ms) outlives
   the panel (190ms), so the card settles and then the item drops into it.

   This REPLACES `.cardpanel{animation:cardin …}` + `@keyframes cardin`.
   ========================================================================= */
.cardpanel,
#dlg .dlg{ animation: fxCardIn 190ms var(--ease) both; }
@keyframes fxCardIn{ from{ opacity:0 } to{ opacity:1 } }

/* Everything except the head sprite may rise. Both surfaces, one rule:
   app  = .cardbody > *          and .detail-head > .grow (the text column)
   site = #dlg .dlg > *          and .top > div           (the text column)
   Ends at transform:none, so no scroll container is left holding a stale
   transform once the animation is done. */
.cardbody > :not(.detail-head),
.cardbody .detail-head > .grow,
#dlg .dlg > :not(.top),
#dlg .dlg .top > div{
  animation: fxCardRise 240ms var(--ease) 70ms both;
}
@keyframes fxCardRise{
  from{ opacity:0; transform:translateY(6px) }
  to  { opacity:1; transform:none }
}

/* The JS bails on both of these before it ever builds a flyer; these rules are
   the belt to that pair of braces, and they also silence the entrance. */
@media (prefers-reduced-motion: reduce){
  .fx-flyer{ display:none }
  .cardpanel,
  #dlg .dlg,
  .cardbody > :not(.detail-head),
  .cardbody .detail-head > .grow,
  #dlg .dlg > :not(.top),
  #dlg .dlg .top > div{ animation:none }
}
:root[data-fx-anim="off"] .fx-flyer{ display:none }
:root[data-fx-anim="off"] .cardpanel,
:root[data-fx-anim="off"] #dlg .dlg,
:root[data-fx-anim="off"] .cardbody > :not(.detail-head),
:root[data-fx-anim="off"] .cardbody .detail-head > .grow,
:root[data-fx-anim="off"] #dlg .dlg > :not(.top),
:root[data-fx-anim="off"] #dlg .dlg .top > div{ animation:none }
/* ===== Items tab hover/keyboard dropdown — shared by site + app ===== */

/* The sticky nav must not clip the menu. */
nav, nav.tabs { overflow: visible; }

/* While a menu is open the nav is lifted above the scanline overlay (site,
   z900) and the card overlay (app, z1000). Restored the moment it closes. */
nav.menu-open, nav.tabs.menu-open { z-index: 1200; }

.tabwrap {
  position: relative;
  display: inline-flex;
  /* icon box size. 32x32 sprites render at an exact 2:1 downscale = crisp. */
  --icon-size: 16px;
}

/* keep the tab's own look; just mark the open state */
.tabwrap > .tab[aria-expanded="true"] { color: var(--mark); }
.tabwrap > .tab[aria-haspopup]::after {
  content: "";
  display: inline-block;
  width: 0; height: 0;
  margin-left: .4em;
  vertical-align: middle;
  border-left: 3px solid transparent;
  border-right: 3px solid transparent;
  border-top: 4px solid currentColor;
  opacity: .5;
  transition: transform var(--t) var(--ease), opacity var(--t) var(--ease);
}
.tabwrap > .tab[aria-expanded="true"]::after { opacity: 1; transform: translateY(1px); }

.tabmenu {
  position: absolute;
  top: 100%;
  left: 0;
  margin-top: 8px;
  z-index: 1200;
  min-width: 13.5rem;
  padding: 6px;
  box-sizing: border-box;
  font-family: var(--sans);
  background: var(--panel);
  border: 1px solid var(--rule2);
  border-radius: 10px;
  box-shadow:
    0 1px 0 var(--rule) inset,
    0 14px 34px -12px rgba(0, 0, 0, .55);
  opacity: 0;
  visibility: hidden;
  transform: translateY(-6px) scale(.985);
  transform-origin: top left;
  transition:
    opacity var(--t) var(--ease),
    transform var(--t) var(--ease),
    visibility 0s linear var(--t);
}
.tabmenu.open {
  opacity: 1;
  visibility: visible;
  transform: none;
  transition-delay: 0s;
}

/* Invisible bridge across the 8px gap so travelling tab -> menu never
   leaves .tabwrap and never fires pointerleave. No gap trap. */
.tabmenu::before {
  content: "";
  position: absolute;
  left: 0; right: 0;
  bottom: 100%;
  height: 10px;
}

.tabmenu-i {
  display: grid;
  grid-template-columns: var(--icon-size) 1fr auto;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 7px 9px;
  margin: 0;
  border: 0;
  border-radius: 7px;
  background: transparent;
  color: var(--ash);
  font-family: var(--sans);
  font-size: .8125rem;
  line-height: 1.2;
  letter-spacing: .01em;
  text-align: left;
  cursor: pointer;
  transition: background var(--t) var(--ease), color var(--t) var(--ease);
}
.tabmenu-i:hover { background: var(--panel2); color: var(--mark); }
.tabmenu-i:focus { outline: none; }
.tabmenu-i:focus-visible,
.tabmenu-i.here {
  background: var(--panel2);
  color: var(--mark);
  box-shadow: inset 0 0 0 1px var(--hot);
}
.tabmenu-i[aria-current="true"] { color: var(--mark); }
.tabmenu-i[aria-current="true"] .tabmenu-l::before {
  content: "";
  display: inline-block;
  width: 4px; height: 4px;
  margin-right: 6px;
  vertical-align: middle;
  border-radius: 50%;
  background: var(--hot);
}

/* Icon slot. Sprite comes in via --icon (inline style or class). */
.tabmenu-ic {
  width: var(--icon-size);
  height: var(--icon-size);
  background-image: var(--icon, none);
  background-repeat: no-repeat;
  background-position: var(--icon-pos, center);
  background-size: var(--icon-cover, var(--icon-size) var(--icon-size));
  image-rendering: pixelated;
  image-rendering: crisp-edges;
  opacity: .85;
  transition: opacity var(--t) var(--ease);
}
.tabmenu-i:hover .tabmenu-ic,
.tabmenu-i:focus-visible .tabmenu-ic,
.tabmenu-i[aria-current="true"] .tabmenu-ic { opacity: 1; }
/* empty slot still reserves the column so labels stay aligned */
.tabmenu-ic:not([style*="--icon"]):not([class*="ic-"]) { background: none; }

.tabmenu-l { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.tabmenu-n {
  justify-self: end;
  font-family: var(--mono);
  font-size: .6875rem;
  font-variant-numeric: tabular-nums;
  color: var(--faint);
  transition: color var(--t) var(--ease);
}
.tabmenu-n:empty { display: none; }
.tabmenu-i:hover .tabmenu-n,
.tabmenu-i:focus-visible .tabmenu-n { color: var(--dim); }

.tabmenu-sep {
  height: 1px;
  margin: 5px 8px;
  background: var(--rule);
}

/* light "angel" theme: softer, tighter shadow reads better on paper */
:root[data-theme="angel"] .tabmenu {
  background: var(--panel);
  border-color: var(--rule2);
  box-shadow:
    0 1px 0 rgba(255, 255, 255, .6) inset,
    0 10px 24px -12px rgba(0, 0, 0, .28);
}

@media (prefers-reduced-motion: reduce) {
  .tabmenu,
  .tabmenu.open,
  .tabmenu-i,
  .tabmenu-ic,
  .tabmenu-n,
  .tabwrap > .tab[aria-haspopup]::after { transition: none; }
  .tabmenu { transform: none; }
}
/* =========================================================
   PER-ITEM VARIATION — append after the family rules in bg2.css.
   Adds no new element, no new animation, no new opacity: it
   re-aims, re-times and re-tints the family's own ::before.
   Item contract (inline custom props, all optional):
     --i-hue 0-359  --i-seed 0-100  --i-speed .7-1.4
     --i-dense 0-100  --i-c1 <hex>  --i-c2 <hex>
   ========================================================= */

.fxbg[data-eff-real]:not([data-eff-real=""]){
  --_s:  var(--i-seed, 50);
  --_h:  var(--i-hue, 200);
  --_d:  var(--i-dense, 45);
  --_sp: var(--i-speed, 1);

  /* the family's own colours, restated so the item can be mixed INTO them.
     KEEP IN SYNC with the --e1/--e2/--e3 in bg2.css. */
  --_b1: var(--ash);
  --_b2: var(--dim);
  --_b3: var(--ash);
  --_dur: 12s;

  /* item colour; with no --i-c1/--i-c2 these resolve to the family colour and
     every mix below becomes a no-op */
  --_c1: var(--i-c1, var(--_b1));
  --_c2: var(--i-c2, var(--_b2));
  --_c3: var(--i-c2, var(--_b3));
  --_mix: calc(20% + var(--_d) * 0.16%);      /* 20-36% item; the family always keeps most */

  /* geometry — seed drives x, hue drives y, so they vary independently.
     background-position only bites because background-size is >100%, so the
     pair together shift the family's gradients by up to ~40% of the card. */
  --_bs: calc(106% + var(--_d) * 0.36%);      /* 106-142%: the slack the offset moves in */
  --_bx: calc(var(--_s) * 1%);                /* 0-100% of the slack */
  --_by: calc(var(--_h) * 0.278%);            /* 0-100% of the slack */
  --_ox: calc(28% + var(--_s) * 0.44%);       /* animation pivot, 28-72% */
  --_oy: calc(28% + var(--_h) * 0.122%);
  --_tx: calc((var(--_s) - 50) * 0.10%);      /* +/-5%, composes with the keyframes */
  --_ty: calc((var(--_h) - 180) * 0.028%);    /* +/-5% */
  --_rot: calc((var(--_s) - 50) * 0.08deg);   /* +/-4deg; ::before is inset:-30%, so no edge shows */
  --_scl: calc(1.03 + var(--_s) * 0.0013);    /* 1.03-1.16, extra cover for the rotation */
  --_blur: calc(var(--_blurbase, 0px) + (100 - var(--_d)) * 0.03px); /* soft when sparse */
}

/* --- family colour table + true base durations ------------------------- */
.fxbg[data-eff-real="poison"]:not([data-eff-real=""]){
  --_b1: var(--good);
  --_b2: color-mix(in oklab, var(--good) 55%, var(--void));
  --_dur: 12s;
}
.fxbg[data-eff-real="fire"]:not([data-eff-real=""]){
  --_b1: var(--hot);
  --_b2: var(--warn);
  --_b3: color-mix(in oklab, var(--mark) 70%, var(--hot));
  --_dur: 9s;
}
.fxbg[data-eff-real="blood"]:not([data-eff-real=""]){
  --_b1: var(--mark);
  --_b2: color-mix(in oklab, var(--mark) 55%, var(--void));
  --_dur: 13s;
}
.fxbg[data-eff-real="creep"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, var(--mark) 65%, var(--good));
  --_b2: color-mix(in oklab, var(--good) 50%, var(--pit));
  --_dur: 14s;
}
.fxbg[data-eff-real="frost"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, #7fc9ff 62%, var(--ash));
  --_b2: color-mix(in oklab, #cfe9ff 45%, var(--ash));
  --_dur: 13s;
}
.fxbg[data-eff-real="charm"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, #ff8ec2 60%, var(--mark));
  --_b2: color-mix(in oklab, #ffc2de 50%, var(--ash));
  --_dur: 10s;
}
.fxbg[data-eff-real="luck"]:not([data-eff-real=""]){
  --_b1: var(--warn);
  --_b2: color-mix(in oklab, var(--warn) 55%, var(--hot));
  --_dur: 11s;
}
.fxbg[data-eff-real="shock"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, #8fd8ff 58%, var(--ash));
  --_b2: color-mix(in oklab, var(--warn) 45%, var(--ash));
  --_dur: 8s;
}
.fxbg[data-eff-real="smoke"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, var(--dim) 65%, var(--ash));
  --_b2: color-mix(in oklab, var(--faint) 70%, var(--ash));
  --_blurbase: 10px;                          /* smoke's own blur, kept */
  --_dur: 14s;
}
.fxbg[data-eff-real="dark"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, var(--void) 70%, var(--ash));
  --_b2: color-mix(in oklab, var(--pit) 70%, var(--ash));
  --_dur: 12s;
}
.fxbg[data-eff-real="holy"]:not([data-eff-real=""]){
  --_b1: color-mix(in oklab, var(--warn) 45%, var(--ash));
  --_b2: var(--warn);
  --_dur: 12s;
}
.fxbg[data-eff-real="spark"]:not([data-eff-real=""]){
  --_b1: var(--warn);
  --_b2: color-mix(in oklab, var(--hot) 55%, var(--ash));
  --_dur: 9s;
}

/* --- the few families that need different treatment -------------------- */

/* directional families: the wash comes from a specific edge, so only let the
   vertical offset move inside a narrow band and keep the source where it is */
.fxbg[data-eff-real="poison"]:not([data-eff-real=""]),
.fxbg[data-eff-real="fire"]:not([data-eff-real=""]),
.fxbg[data-eff-real="creep"]:not([data-eff-real=""]),
.fxbg[data-eff-real="blood"]:not([data-eff-real=""]),
.fxbg[data-eff-real="holy"]:not([data-eff-real=""]){
  --_by: calc(38% + var(--_h) * 0.067%);      /* 38-62% */
  --_ty: calc((var(--_h) - 180) * 0.012%);
}
/* fine detail (ember dots, arc lattice, gold sweep): blur would erase it */
.fxbg[data-eff-real="spark"]:not([data-eff-real=""]),
.fxbg[data-eff-real="shock"]:not([data-eff-real=""]),
.fxbg[data-eff-real="luck"]:not([data-eff-real=""]){
  --_blur: calc((100 - var(--_d)) * 0.008px);
  --_bs: calc(104% + var(--_d) * 0.20%);
}
/* mood families: an item colour at full strength would stop reading as
   smoke / void, so they take a much smaller dose */
.fxbg[data-eff-real="smoke"]:not([data-eff-real=""]),
.fxbg[data-eff-real="dark"]:not([data-eff-real=""]){
  --_mix: calc(10% + var(--_d) * 0.12%);      /* 10-22% */
  --_rot: calc((var(--_s) - 50) * 0.035deg);
}

/* --- the item's own sprite colours tint the family wash ---------------- */
.fxbg[data-eff-real]:not([data-eff-real=""]){
  --e1: color-mix(in oklab, var(--_c1) var(--_mix), var(--_b1));
  --e2: color-mix(in oklab, var(--_c2) var(--_mix), var(--_b2));
  --e3: color-mix(in oklab, var(--_c3) var(--_mix), var(--_b3));
}

/* --- re-aim and re-time the family layer ------------------------------- */
.fxbg[data-eff-real]:not([data-eff-real=""])::before{
  /* individual transform properties compose with the family keyframes'
     `transform` instead of fighting it, so nothing is overridden */
  translate: var(--_tx) var(--_ty);
  rotate: var(--_rot);
  scale: var(--_scl);
  transform-origin: var(--_ox) var(--_oy);
  background-size: var(--_bs) var(--_bs);
  background-position: var(--_bx) var(--_by);
  filter: blur(var(--_blur));
  animation-duration: calc(var(--_dur) / var(--_sp));
  animation-delay: calc(var(--_s) * -0.19s);  /* phase: no two cards in step */
}

/* .no-bg-anim and prefers-reduced-motion already kill the animation with
   `animation: none !important` in bg2.css; translate/rotate/scale/background
   are static, so a frozen card still looks like ITS item. Nothing to add. */
/* ---- sort control -------------------------------------------------------
   Same block for both surfaces; theme vars only. Put it next to .searchwrap
   in site.html's <style>, and next to .searchbar in app style.css.        */
.sortrow { display: flex; align-items: center; gap: 8px; margin-top: 10px; }
/* the enemy row and the app search bar are already flex rows */
.searchwrap.row .sortrow, .searchbar .sortrow { margin-top: 0; }
.sortlab {
  font-family: var(--mono); font-size: 9.5px; letter-spacing: .13em;
  text-transform: uppercase; color: var(--faint); white-space: nowrap;
  cursor: pointer; transition: color var(--t) var(--ease);
}
.sortrow:hover .sortlab { color: var(--dim); }
.sortrow select { min-width: 0; }

/* site.html only: #q/#fq/#aq have a focus ring, .sel never did. Keyboard
   users could not see where they were. This fixes #ff as well. */
.sel:focus-visible { outline: 2px solid var(--hot); outline-offset: 1px; }

/* two selects beside a search box need room to wrap on a narrow window */
@media (max-width: 640px) {
  .searchwrap.row, .searchbar { flex-wrap: wrap; }
  .searchwrap.row input, .searchbar input { flex: 1 1 100%; }
  .searchwrap.row .sel, .searchwrap.row .sortrow,
  .searchbar select, .searchbar .sortrow { flex: 1 1 auto; }
}
/* =========================================================
   IDLE — sprites at rest
   ---------------------------------------------------------
   Every sprite in a list row gets a slow, whole-pixel idle
   loop, phase-shifted per row so a long list never breathes
   in unison. Site rows are .it > .spr / .foe; app rows are
   .held li / .results li > .slot > .sprite.

   Three deliberate constraints, all of them load-bearing:

   1. It animates `translate`, NOT `transform`. Both lists
      already own `transform` for the hover pop
      (.it:hover .spr{transform:scale(1.14)} and
      .held li:hover .sprite{transform:scale(1.12)}), and a
      running OR PAUSED animation on `transform` outranks a
      normal declaration — the hover pop would silently die.
      `translate` is a separate channel that multiplies into
      the same matrix, so hover keeps working untouched.

   2. It never animates `opacity`. Three existing states are
      expressed as opacity on or near this exact node —
      .sprite-missing{opacity:.3}, the site's inline
      opacity:.25 for a missing frame, and
      .slot.badge-art-locked{opacity:.62}. An opacity
      animation beats all three and would light missing and
      locked art up to full. The "blink beat" is therefore
      done in the transform channel instead, as a one-frame
      kick — which is how a 2D sprite blinks anyway.

   3. Motion is in WHOLE PIXELS, held on steps(), never
      interpolated. style.css already says smooth scaling
      "turns them to mush"; a fractional translate on a
      composited layer resamples the whole sprite and does
      exactly that, continuously. Integer steps stay
      pixel-exact and read like a real 4-frame idle loop.
      (If you want the smooth breathing scale instead, it is
      one attribute away — see data-fx-anim="breathe".)

   No `will-change` anywhere: this runs on 400-row lists and
   a forced layer per row is the opposite of what those
   perf notes in .items were fighting for.
   ========================================================= */

/* ---- keyframes -------------------------------------------
   Prefixed `idle` so they cannot collide with `floaty`
   (the hero specimen) or the fx* effect library. */

/* base: the pedestal float. A collectible sitting on a pedestal
   in game rides up and down about a tenth of its own height,
   once every second and a half. The old version travelled 2px
   over 5.2 seconds, which is a real animation that nobody can
   see -- it read as a still image. Same whole-pixel steps, just
   an amplitude and a tempo you can actually read. */
@keyframes idleBob{
  0%    { translate: 0 0 }
  12.5% { translate: 0 -1px }
  25%   { translate: 0 -2px }
  37.5% { translate: 0 -3px }
  50%   { translate: 0 -3px }
  62.5% { translate: 0 -2px }
  75%   { translate: 0 -1px }
  87.5% { translate: 0 0 }
  100%  { translate: 0 0 }
}

/* boss: 6 frames, and the weight shifts side to side as it
   rises and falls. Bosses lumber; they do not hover. */
@keyframes idleBossBob{
  0%     { translate: 0 0 }
  12.5%  { translate: 0 -1px }
  25%    { translate: -1px -2px }
  37.5%  { translate: -1px -3px }
  50%    { translate: 0 -4px }
  62.5%  { translate: 1px -3px }
  75%    { translate: 1px -2px }
  87.5%  { translate: 0 -1px }
  100%   { translate: 0 0 }
}

/* real effect: same bob, but the tail of the cycle is a
   two-frame twitch — the blink beat. The frames are short
   (290ms, 500ms) against the bob's 790ms, so it reads as a
   flinch rather than as part of the drift. */
@keyframes idleCharged{
  0%   { translate: 0 0 }
  12%  { translate: 0 -1px }
  24%  { translate: 0 -2px }
  36%  { translate: 0 -3px }
  48%  { translate: 0 -2px }
  60%  { translate: 0 -1px }
  72%  { translate: 1px -2px }
  80%  { translate: -1px -1px }
  88%  { translate: 1px 0 }
  100% { translate: 0 0 }
}

/* opt-in only, see data-fx-anim="breathe" below */
@keyframes idleBreath{
  0%, 100% { scale: 1 }
  50%      { scale: 1.02 }
}

/* ---- phase ladder: desync with no JS at all --------------
   Delays are NEGATIVE, so every row is already mid-cycle the
   instant it is created. A positive delay would make a page
   of freshly paginated rows sit dead still and then all start
   together — the exact wave this is meant to prevent.
   7 buckets: coprime with the 1-column app list and with the
   2/3/4-column auto-fill grid on the site, so the pattern
   never lines up into stripes.
   An inline --idle-d on the row beats every rule here, so
   the JS helper (if you use it) needs no !important. */
:is(.it, .held li, .results li)                { --idle-d: 0s }
:is(.it, .held li, .results li):nth-child(7n+2){ --idle-d: -.83s }
:is(.it, .held li, .results li):nth-child(7n+3){ --idle-d: -1.7s }
:is(.it, .held li, .results li):nth-child(7n+4){ --idle-d: -2.44s }
:is(.it, .held li, .results li):nth-child(7n+5){ --idle-d: -3.1s }
:is(.it, .held li, .results li):nth-child(7n+6){ --idle-d: -4.05s }
:is(.it, .held li, .results li):nth-child(7n+7){ --idle-d: -4.9s }

/* ---- the idle itself -------------------------------------
   Name and duration go through custom properties so the two
   variants below are one line each and never restate the
   shorthand (restating it is how you lose the delay).
   Scoped to list rows only: the detail card's sprite
   (.cardbody .detail-head .sprite, which carries its own
   translate(-4px,-6px)) is deliberately out of range, and so
   is the hero specimen. */
.it > :is(.spr, .foe),
:is(.held, .results) li .slot:not(.badge-art) > .sprite{
  --idle-name: idleBob;
  --idle-dur: 2.4s;
  /* The sprite's own frames come FIRST in the list. Order is
     load-bearing: the hover rule pauses by position, and only
     a fixed first slot lets one animation-play-state cover
     both this rule and the three-slot breathe variant.
     `none 0s` is the no-op for a sprite with no frames. */
  animation:
    var(--strip-run, none 0s),
    var(--idle-name) var(--idle-dur) steps(1, end) infinite;
  /* Per slot, not one value for both. The bob is staggered per row so a long list
     never breathes in unison; the sprite's own frames take --strip-d, which pills
     override to a shared phase so every pill shows the same colour at once. */
  animation-delay: var(--strip-d, var(--idle-d, 0s)), var(--idle-d, 0s);
}

/* rows with a real effect: quicker, and it twitches.
   The empty-string guard is load-bearing — fxApply leaves
   data-eff-real="" on rows with no real effect, so a bare
   [data-eff-real] over-matches. It is wrapped in :where() so
   the guard adds no specificity, which lets the boss rule
   below win on source order for a row that is both. */
.it[data-eff-real]:not(:where([data-eff-real=""])) > :is(.spr, .foe),
:is(.held, .results) li[data-eff-real]:not(:where([data-eff-real=""])) .slot:not(.badge-art) > .sprite{
  --idle-name: idleCharged;
  --idle-dur: 2s;
}

/* boss rows: last, so a boss that also carries a real effect
   idles as a boss. Bosses are the stronger identity. */
.it[data-boss] > :is(.spr, .foe),
:is(.held, .results) li[data-boss] .slot:not(.badge-art) > .sprite{
  --idle-name: idleBossBob;
  --idle-dur: 3.2s;
}

/* ---- hover: hold still -----------------------------------
   `paused`, not `none`: none snaps the sprite back to 0 the
   moment the pointer lands, which is a 2px jump under the
   cursor. Paused freezes the frame it is on, so the hover
   scale is the only thing that moves.
   :focus-within covers keyboard traversal for whichever list
   is focusable. */
.it:is(:hover, :focus-visible, :focus-within) > :is(.spr, .foe),
:is(.held, .results) li:is(:hover, :focus-visible, :focus-within) .slot > .sprite{
  /* First slot is the sprite's own frames — those keep
     running, because a creature that stops breathing the
     moment you point at it reads as dead. What freezes is the
     bob (and breathe's third slot): the motion that was
     fighting the cursor. */
  animation-play-state: running, paused, paused;
}

/* ---- achievement badge art: no idle loop -----------------
   Three reasons it gets none:
   (a) It is not a sprite. It is a 263x176 hand-drawn card
       rendered with image-rendering:auto, sitting edge to
       edge in a parchment tile. A card printed into a frame
       does not bob inside it — the frame would read as loose.
   (b) The whole-pixel trick above does not save it. The art
       is already heavily downsampled (scale .25), so ANY
       sub-pixel motion re-phases a bilinear resample and the
       lettering crawls. This is the one node in either list
       where motion actively damages the image.
   (c) Badge rows are already dealt an entry animation by
       fxForBadge — "a card the game deals you". A loop would
       be a second, contradictory motion on the same node.
   What it gets instead is a deliberate 1px lift on hover:
   the card is picked up, not alive. Transition, not
   animation, so it is a response and never an ambience.
   `translate` again, because .slot.badge-art .sprite pins
   transform:none — restating the transition here is safe
   precisely because that rule also pins filter:none, so
   nothing is lost by dropping them from the list. */
.it > .badge,
:is(.held, .results) li .slot.badge-art > .sprite{
  transition: translate var(--t) var(--ease);
}
.it:is(:hover, :focus-visible, :focus-within) > .badge,
:is(.held, .results) li:is(:hover, :focus-visible, :focus-within) .slot.badge-art > .sprite{
  translate: 0 -1px;
}

/* ---- opt-in: the smooth breathing scale ------------------
   <html data-fx-anim="breathe"> swaps the stepped idle for
   the stepped idle PLUS a continuous 2% scale breath. It is
   not the default because a permanent fractional scale is
   exactly the resampling this file avoids — but on the app's
   32px sprites it is defensible, so the switch is here.
   One rule covers all three variants because the name and
   duration still come from --idle-name / --idle-dur. */
:root[data-fx-anim="breathe"] .it > :is(.spr, .foe),
:root[data-fx-anim="breathe"] :is(.held, .results) li .slot:not(.badge-art) > .sprite{
  animation:
    var(--strip-run, none 0s),
    var(--idle-name) var(--idle-dur) steps(1, end) infinite,
    idleBreath 4.6s var(--ease) infinite;
  animation-delay: var(--strip-d, var(--idle-d, 0s)), var(--idle-d, 0s), var(--idle-d, 0s);
}

/* ---- kill switches ---------------------------------------
   <html data-fx-anim="off">. Higher specificity than every
   rule above, so no !important needed. */
:root[data-fx-anim="off"] .it > :is(.spr, .foe, .badge),
:root[data-fx-anim="off"] #dbody .top :is(.spr, .foe),
:root[data-fx-anim="off"] :is(.held, .results) li .slot > .sprite{
  animation: none;
  translate: none;
  transition: none;
}

/* prefers-reduced-motion has to beat the breathe opt-in,
   which is more specific than the plain selector — this is
   the one place !important is the correct tool. */
@media (prefers-reduced-motion: reduce){
  .it > :is(.spr, .foe, .badge),
  #dbody .top :is(.spr, .foe),
  :is(.held, .results) li .slot > .sprite{
    animation: none !important;
    translate: none !important;
    transition: none !important;
  }
}

/* ---- off-screen rows rest --------------------------------
   Paused, and faded out on the way. A list keeps every row it
   has paged in and each carries a sprite playing its own
   frames; a running animation ticks whether or not it is on
   screen. See restIO in the script for why paused, not none.

   Placement is load-bearing: `animation` is a shorthand and
   resets animation-play-state, so this has to come AFTER the
   idle rules or it is silently overwritten at equal
   specificity. It sat above them at first and paused nothing
   at all -- 0 of 28 off-screen rows. */
.it.rest > *,
.it.rest::after{
  animation-play-state: paused;
}
.it{transition:opacity .3s var(--ease)}
/* Safe to take all the way to 0: restIO's rootMargin guarantees a resting row is
   at least 280px outside the viewport, so the fade is never on screen. */
.it.rest{opacity:0}
/* ---------- entry motion moves the CONTENTS, never the row ----------
   A row that animates itself moves out from under the cursor: the pointer leaves,
   the row snaps back, the pointer enters again, and the hover replay retriggers
   forever. Rows with vertical motion (fxTear, fxStomp, fxBounce) shook on the edges
   because of exactly that loop.

   Animating the row's children instead keeps the row's own box -- and therefore its
   hit area -- perfectly still, so the pointer never crosses the boundary. The motion
   looks identical because the children are all there is to see. */
.it > *, .results li > * { animation: var(--fx-run, none); }

/* The overlay lives on the row's ::after and must stay put while the contents move. */
.it::after, .results li::after { animation-name: var(--fx-eff-name, none); }
/* =========================================================
   EFFECT BACKGROUNDS — animated ambient wash inside detail card
   Applies to any container carrying data-eff-real="<family>"
   (website #card / dialog .dlg, app #card). One ::before only.
   Animates transform + opacity only; gradients are static.
   ========================================================= */

.fxbg[data-eff-real]{
  position: relative;
  overflow: hidden;
  isolation: isolate;
}

/* keep card content above the wash */
.fxbg[data-eff-real] > *{
  position: relative;
  z-index: 1;
}

.fxbg[data-eff-real]::before{
  content: "";
  position: absolute;
  inset: -30%;                 /* oversized so drift never reveals an edge */
  z-index: 0;
  pointer-events: none;
  opacity: .16;                /* fallback peak if animation is unavailable */
  transform-origin: 50% 50%;
  background-repeat: no-repeat;
  will-change: transform, opacity;
  mix-blend-mode: screen;      /* Devil (dark) default */
  /* readability guard: wash is softest where the body copy sits */
  -webkit-mask-image: radial-gradient(120% 95% at 50% 50%, rgba(0,0,0,.5) 0%, rgba(0,0,0,.85) 45%, #000 72%);
          mask-image: radial-gradient(120% 95% at 50% 50%, rgba(0,0,0,.5) 0%, rgba(0,0,0,.85) 45%, #000 72%);
}

:root[data-theme="angel"] .fxbg[data-eff-real]::before{
  mix-blend-mode: multiply;    /* light marble: tint by darkening */
}

/* ---------------- POISON — bile blooms rising ---------------- */
.fxbg[data-eff-real="poison"]{
  --e1: var(--good);
  --e2: color-mix(in oklab, var(--good) 55%, var(--void));
  --eff-still: translate3d(-1%, -3%, 0) scale(1.05);
  --eff-still-o: .15;
}
.fxbg[data-eff-real="poison"]::before{
  background:
    radial-gradient(34% 24% at 24% 76%, var(--e1) 0%, transparent 68%),
    radial-gradient(26% 18% at 70% 62%, var(--e1) 0%, transparent 72%),
    radial-gradient(20% 14% at 46% 40%, var(--e2) 0%, transparent 74%),
    radial-gradient(70% 40% at 50% 106%, var(--e2) 0%, transparent 76%);
  animation: bgPoison 12s var(--ease, ease-in-out) infinite;
}
@keyframes bgPoison{
  0%   { transform: translate3d(0, 2%, 0) scale(1.02);      opacity: .12; }
  50%  { transform: translate3d(-2%, -7%, 0) scale(1.09);   opacity: .19; }
  100% { transform: translate3d(0, 2%, 0) scale(1.02);      opacity: .12; }
}

/* ---------------- FIRE — heat rising, slow flicker ---------------- */
.fxbg[data-eff-real="fire"]{
  --e1: var(--hot);
  --e2: var(--warn);
  --e3: color-mix(in oklab, var(--mark) 70%, var(--hot));
  --eff-still: translate3d(0, -3%, 0) scaleY(1.04);
  --eff-still-o: .16;
}
.fxbg[data-eff-real="fire"]::before{
  background:
    radial-gradient(46% 34% at 50% 104%, var(--e2) 0%, transparent 66%),
    radial-gradient(30% 40% at 26% 96%, var(--e1) 0%, transparent 72%),
    radial-gradient(28% 38% at 76% 98%, var(--e1) 0%, transparent 74%),
    radial-gradient(80% 55% at 50% 118%, var(--e3) 0%, transparent 78%);
  animation: bgFire 9s var(--ease, ease-in-out) infinite;
}
@keyframes bgFire{
  0%   { transform: translate3d(0, 0, 0) scaleY(1) scaleX(1.01);       opacity: .13; }
  35%  { transform: translate3d(-1%, -5%, 0) scaleY(1.07) scaleX(.99); opacity: .20; }
  65%  { transform: translate3d(1%, -3%, 0) scaleY(1.03) scaleX(1.02); opacity: .15; }
  100% { transform: translate3d(0, 0, 0) scaleY(1) scaleX(1.01);       opacity: .13; }
}

/* ---------------- BLOOD — heavy seep downward ---------------- */
.fxbg[data-eff-real="blood"]{
  --e1: var(--mark);
  --e2: color-mix(in oklab, var(--mark) 55%, var(--void));
  --eff-still: translate3d(0, 0, 0) scale(1.05);
  --eff-still-o: .17;
}
.fxbg[data-eff-real="blood"]::before{
  background:
    radial-gradient(50% 30% at 30% -8%, var(--e1) 0%, transparent 70%),
    radial-gradient(34% 46% at 68% 6%, var(--e2) 0%, transparent 74%),
    radial-gradient(22% 60% at 18% 30%, var(--e1) 0%, transparent 76%),
    radial-gradient(90% 40% at 50% 112%, var(--e2) 0%, transparent 80%);
  animation: bgBlood 13s var(--ease, ease-in-out) infinite;
}
@keyframes bgBlood{
  0%   { transform: translate3d(0, -4%, 0) scale(1.04); opacity: .14; }
  50%  { transform: translate3d(0, 5%, 0) scale(1.08);  opacity: .20; }
  100% { transform: translate3d(0, -4%, 0) scale(1.04); opacity: .14; }
}

/* ---------------- CREEP — spreading pool ---------------- */
.fxbg[data-eff-real="creep"]{
  --e1: color-mix(in oklab, var(--mark) 65%, var(--good));
  --e2: color-mix(in oklab, var(--good) 50%, var(--pit));
  --eff-still: rotate(1deg) scale(1.05);
  --eff-still-o: .15;
}
.fxbg[data-eff-real="creep"]::before{
  background:
    radial-gradient(30% 20% at 34% 82%, var(--e1) 0%, transparent 66%),
    radial-gradient(24% 16% at 66% 74%, var(--e2) 0%, transparent 70%),
    radial-gradient(18% 12% at 50% 92%, var(--e1) 0%, transparent 72%),
    radial-gradient(85% 45% at 50% 110%, var(--e2) 0%, transparent 78%);
  animation: bgCreep 14s var(--ease, ease-in-out) infinite;
}
@keyframes bgCreep{
  0%   { transform: rotate(-1.5deg) scale(1);      opacity: .12; }
  50%  { transform: rotate(2deg) scale(1.10);      opacity: .19; }
  100% { transform: rotate(-1.5deg) scale(1);      opacity: .12; }
}

/* ---------------- FROST — cold sheen drifting ---------------- */
.fxbg[data-eff-real="frost"]{
  --e1: color-mix(in oklab, #7fc9ff 62%, var(--ash));
  --e2: color-mix(in oklab, #cfe9ff 45%, var(--ash));
  --eff-still: translate3d(0, 0, 0) scale(1.04);
  --eff-still-o: .14;
}
.fxbg[data-eff-real="frost"]::before{
  background:
    linear-gradient(118deg, transparent 22%, var(--e2) 46%, transparent 62%),
    radial-gradient(40% 28% at 18% 22%, var(--e1) 0%, transparent 70%),
    radial-gradient(34% 24% at 82% 78%, var(--e1) 0%, transparent 72%),
    radial-gradient(90% 70% at 50% 50%, var(--e2) 0%, transparent 82%);
  animation: bgFrost 13s var(--ease, ease-in-out) infinite;
}
@keyframes bgFrost{
  0%   { transform: translate3d(-4%, 2%, 0) scale(1.02); opacity: .11; }
  50%  { transform: translate3d(4%, -2%, 0) scale(1.07); opacity: .18; }
  100% { transform: translate3d(-4%, 2%, 0) scale(1.02); opacity: .11; }
}

/* ---------------- CHARM — soft pink bloom ---------------- */
.fxbg[data-eff-real="charm"]{
  --e1: color-mix(in oklab, #ff8ec2 60%, var(--mark));
  --e2: color-mix(in oklab, #ffc2de 50%, var(--ash));
  --eff-still: rotate(0deg) scale(1.04);
  --eff-still-o: .15;
}
.fxbg[data-eff-real="charm"]::before{
  background:
    radial-gradient(26% 22% at 30% 34%, var(--e1) 0%, transparent 68%),
    radial-gradient(20% 18% at 72% 58%, var(--e2) 0%, transparent 70%),
    radial-gradient(16% 14% at 52% 80%, var(--e1) 0%, transparent 72%),
    radial-gradient(95% 75% at 50% 50%, var(--e2) 0%, transparent 84%);
  animation: bgCharm 10s var(--ease, ease-in-out) infinite;
}
@keyframes bgCharm{
  0%   { transform: rotate(-1.5deg) scale(1);    opacity: .12; }
  45%  { transform: rotate(1.5deg) scale(1.08);  opacity: .20; }
  100% { transform: rotate(-1.5deg) scale(1);    opacity: .12; }
}

/* ---------------- LUCK — slow golden sweep ---------------- */
.fxbg[data-eff-real="luck"]{
  --e1: var(--warn);
  --e2: color-mix(in oklab, var(--warn) 55%, var(--hot));
  --eff-still: translate3d(0, 0, 0) skewX(-6deg);
  --eff-still-o: .16;
}
.fxbg[data-eff-real="luck"]::before{
  background:
    linear-gradient(104deg, transparent 28%, var(--e1) 48%, transparent 66%),
    radial-gradient(30% 22% at 22% 30%, var(--e2) 0%, transparent 72%),
    radial-gradient(24% 18% at 78% 72%, var(--e2) 0%, transparent 74%);
  animation: bgLuck 11s var(--ease, ease-in-out) infinite;
}
@keyframes bgLuck{
  0%   { transform: translate3d(-14%, 0, 0) skewX(-6deg); opacity: .10; }
  50%  { transform: translate3d(0, 0, 0) skewX(-6deg);    opacity: .19; }
  100% { transform: translate3d(14%, 0, 0) skewX(-6deg);  opacity: .10; }
}

/* ---------------- SHOCK — drifting arc lattice ---------------- */
.fxbg[data-eff-real="shock"]{
  --e1: color-mix(in oklab, #8fd8ff 58%, var(--ash));
  --e2: color-mix(in oklab, var(--warn) 45%, var(--ash));
  --eff-still: translate3d(0, 0, 0) scale(1.03);
  --eff-still-o: .13;
}
.fxbg[data-eff-real="shock"]::before{
  background:
    repeating-linear-gradient(102deg, transparent 0 26px, var(--e1) 26px 27px, transparent 27px 54px),
    radial-gradient(38% 26% at 26% 26%, var(--e2) 0%, transparent 70%),
    radial-gradient(34% 24% at 74% 74%, var(--e1) 0%, transparent 72%);
  animation: bgShock 8s var(--ease, ease-in-out) infinite;
}
@keyframes bgShock{
  0%   { transform: translate3d(-2%, 0, 0) scale(1.01); opacity: .09; }
  22%  { transform: translate3d(1%, -1%, 0) scale(1.04); opacity: .18; }
  40%  { transform: translate3d(-1%, 1%, 0) scale(1.02); opacity: .11; }
  62%  { transform: translate3d(2%, 0, 0) scale(1.05);  opacity: .19; }
  100% { transform: translate3d(-2%, 0, 0) scale(1.01); opacity: .09; }
}

/* ---------------- SMOKE — slow plumes ---------------- */
.fxbg[data-eff-real="smoke"]{
  --e1: color-mix(in oklab, var(--dim) 65%, var(--ash));
  --e2: color-mix(in oklab, var(--faint) 70%, var(--ash));
  --eff-still: translate3d(0, 0, 0) scale(1.06);
  --eff-still-o: .16;
}
.fxbg[data-eff-real="smoke"]::before{
  background:
    radial-gradient(44% 34% at 28% 62%, var(--e1) 0%, transparent 72%),
    radial-gradient(38% 30% at 72% 38%, var(--e2) 0%, transparent 74%),
    radial-gradient(56% 40% at 50% 96%, var(--e1) 0%, transparent 78%);
  filter: blur(10px);
  animation: bgSmoke 14s var(--ease, ease-in-out) infinite;
}
@keyframes bgSmoke{
  0%   { transform: translate3d(-6%, 3%, 0) scale(1.02);  opacity: .12; }
  50%  { transform: translate3d(6%, -4%, 0) scale(1.10);  opacity: .20; }
  100% { transform: translate3d(-6%, 3%, 0) scale(1.02);  opacity: .12; }
}

/* ---------------- DARK — breathing void ---------------- */
.fxbg[data-eff-real="dark"]{
  --e1: color-mix(in oklab, var(--void) 70%, var(--ash));
  --e2: color-mix(in oklab, var(--pit) 70%, var(--ash));
  --eff-still: scale(1.06);
  --eff-still-o: .18;
}
.fxbg[data-eff-real="dark"]::before{
  mix-blend-mode: multiply;   /* always darkens, both themes */
  background:
    radial-gradient(70% 60% at 50% 50%, transparent 22%, var(--e2) 78%),
    radial-gradient(40% 34% at 20% 24%, var(--e1) 0%, transparent 74%),
    radial-gradient(40% 34% at 82% 78%, var(--e1) 0%, transparent 74%);
  animation: bgDark 12s var(--ease, ease-in-out) infinite;
}
@keyframes bgDark{
  0%   { transform: scale(1.12) rotate(.4deg); opacity: .14; }
  50%  { transform: scale(1.00) rotate(-.4deg); opacity: .21; }
  100% { transform: scale(1.12) rotate(.4deg); opacity: .14; }
}

/* ---------------- HOLY — light from above ---------------- */
.fxbg[data-eff-real="holy"]{
  --e1: color-mix(in oklab, var(--warn) 45%, var(--ash));
  --e2: var(--warn);
  --eff-still: translate3d(0, 0, 0) scale(1.04);
  --eff-still-o: .15;
}
.fxbg[data-eff-real="holy"]::before{
  background:
    linear-gradient(180deg, var(--e1) 0%, transparent 58%),
    radial-gradient(46% 30% at 50% -10%, var(--e2) 0%, transparent 72%),
    radial-gradient(24% 46% at 34% 8%, var(--e1) 0%, transparent 78%),
    radial-gradient(24% 46% at 68% 8%, var(--e1) 0%, transparent 78%);
  animation: bgHoly 12s var(--ease, ease-in-out) infinite;
}
@keyframes bgHoly{
  0%   { transform: translate3d(0, -3%, 0) scale(1.01); opacity: .10; }
  50%  { transform: translate3d(0, 3%, 0) scale(1.07);  opacity: .18; }
  100% { transform: translate3d(0, -3%, 0) scale(1.01); opacity: .10; }
}

/* ---------------- SPARK — drifting embers ---------------- */
.fxbg[data-eff-real="spark"]{
  --e1: var(--warn);
  --e2: color-mix(in oklab, var(--hot) 55%, var(--ash));
  --eff-still: translate3d(0, -2%, 0) scale(1.03);
  --eff-still-o: .16;
}
.fxbg[data-eff-real="spark"]::before{
  background:
    radial-gradient(4% 3% at 18% 32%, var(--e1) 0%, transparent 70%),
    radial-gradient(3% 2.4% at 42% 18%, var(--e2) 0%, transparent 70%),
    radial-gradient(3.4% 2.6% at 64% 44%, var(--e1) 0%, transparent 70%),
    radial-gradient(2.6% 2% at 82% 24%, var(--e2) 0%, transparent 70%),
    radial-gradient(3.6% 2.8% at 30% 68%, var(--e1) 0%, transparent 70%),
    radial-gradient(2.8% 2.2% at 74% 78%, var(--e2) 0%, transparent 70%),
    radial-gradient(70% 50% at 50% 60%, var(--e2) 0%, transparent 84%);
  animation: bgSpark 9s var(--ease, ease-in-out) infinite;
}
@keyframes bgSpark{
  0%   { transform: translate3d(-2%, 3%, 0) scale(1.00); opacity: .10; }
  40%  { transform: translate3d(1%, -2%, 0) scale(1.05); opacity: .20; }
  70%  { transform: translate3d(2%, -4%, 0) scale(1.03); opacity: .13; }
  100% { transform: translate3d(-2%, 3%, 0) scale(1.00); opacity: .10; }
}

/* =========================================================
   FROZEN STATE — same background, no motion.
   .no-bg-anim on the element itself or on any ancestor.
   ========================================================= */
.fxbg[data-eff-real].no-bg-anim::before,
.no-bg-anim .fxbg[data-eff-real]::before{
  animation: none !important;
  transform: var(--eff-still, scale(1.04));
  opacity: var(--eff-still-o, .16);
}

@media (prefers-reduced-motion: reduce){
  .fxbg[data-eff-real]::before{
    animation: none !important;
    transform: var(--eff-still, scale(1.04));
    opacity: var(--eff-still-o, .16);
  }
}
/* ============================================================
   FX row affordance — real effects vs filler
   Rows: div.it (site) | .results li (app)
   Companion to eff.css / keyframes.css. Deliberately touches
   nothing they own: no ::after of our own, no `transform` on
   the row, no animation-* except to switch motion off.
   ============================================================ */

/* --- 0. row baseline ---------------------------------------
   One channel for the edge marker (an inset shadow: no layout,
   no extra pseudo-element, survives the row's overflow:hidden)
   and one for the hover nudge.
   The nudge uses `translate:`, NOT `transform:` — .it already
   carries `animation: fadeUp .32s both` and every fx keyframe
   ends at `transform:none`, so a fill-both animation would
   permanently outrank any `transform` set here. `translate` is
   an independent property and composes with it instead. */
:is(.it, .results li){
  --fam: var(--rule2);
  /* the family colour nudged 12% toward the theme's ink. --ash is the
     high-contrast foreground in BOTH themes (bone on devil, near-black
     on angel), so this always pushes away from the panel: measured, the
     2px hairline clears 3.6:1 on every family in both themes, where the
     raw colour bottoms out at 2.3:1 (blood on devil, fire on angel). */
  --fam-ink: color-mix(in oklab, var(--fam) 88%, var(--ash));
  --edge: 0px;
  --edge-c: transparent;
  --nudge: 0px;
  box-shadow: inset var(--edge) 0 0 0 var(--edge-c);
  transition:
    background-color var(--t) var(--ease),
    border-color     var(--t) var(--ease),
    box-shadow       var(--t) var(--ease),
    translate        var(--t) var(--ease),
    opacity          var(--t) var(--ease);
}

/* Full-bleed list rows can afford to slide. The .it card grid is
   gapless (1px rule lines showing through), so a card that moves
   would open a seam against its neighbour — it stays put. */
.results li{ --nudge: 2px; }

/* --- 1. family tint ----------------------------------------
   --fam is the one hook the hover rule reads, so 12 families
   are served by a single hover rule. Every value is derived
   from theme vars, so [data-theme="angel"] re-tints for free
   and nothing hard-codes a hex. */
:is(.it, .results li)[data-eff-real="poison"]{ --fam: var(--good); }
:is(.it, .results li)[data-eff-real="fire"]  { --fam: var(--hot); }
:is(.it, .results li)[data-eff-real="blood"] { --fam: var(--mark); }
:is(.it, .results li)[data-eff-real="luck"]  { --fam: var(--warn); }
:is(.it, .results li)[data-eff-real="smoke"] { --fam: var(--dim); }
:is(.it, .results li)[data-eff-real="creep"] { --fam: color-mix(in oklab, var(--mark) 62%, var(--good)); }
:is(.it, .results li)[data-eff-real="charm"] { --fam: color-mix(in oklab, var(--mark) 55%, var(--ash)); }
:is(.it, .results li)[data-eff-real="dark"]  { --fam: color-mix(in oklab, var(--mark) 55%, var(--dim)); }
:is(.it, .results li)[data-eff-real="spark"] { --fam: color-mix(in oklab, var(--warn) 60%, var(--hot)); }
:is(.it, .results li)[data-eff-real="holy"]  { --fam: color-mix(in oklab, var(--warn) 55%, var(--ash)); }
:is(.it, .results li)[data-eff-real="shock"] { --fam: color-mix(in oklab, var(--ash) 60%, var(--warn)); }
:is(.it, .results li)[data-eff-real="frost"] { --fam: color-mix(in oklab, var(--ash) 62%, var(--dim)); }

/* --- 2. resting marker -------------------------------------
   A row that genuinely has an effect wears a hairline in its
   family colour, so it reads as special before you touch it.
   The :not([data-eff-real=""]) guard is load-bearing: fxApply
   writes these attributes unconditionally, so a plain row can
   carry an EMPTY data-eff-real / data-fx-real. */
:is(.it, .results li)[data-eff-real]:not([data-eff-real=""]){
  --edge: 2px;
  --edge-c: var(--fam-ink);
}

/* --- 3. hover / keyboard focus -----------------------------
   The edge thickens to full strength, the row takes a wash of
   its own family, and list rows lean 2px toward the cursor.
   Paint + composite only. The big entry animation is the JS's
   job (fxHoverBind); this is the invitation, not the replay. */
:is(.it, .results li)[data-eff-real]:not([data-eff-real=""]):hover,
:is(.it, .results li)[data-eff-real]:not([data-eff-real=""]):focus-visible,
:is(.it, .results li)[data-eff-real]:not([data-eff-real=""]):has(:focus-visible){
  --edge: 4px;
  --edge-c: var(--fam);
  background-color: color-mix(in oklab, var(--fam) 10%, var(--panel2));
  border-color: color-mix(in oklab, var(--fam) 45%, var(--rule));
  translate: var(--nudge);
}

/* Keyboard users get the same state plus a ring, in-set so the
   gapless card grid never clips it. */
:is(.it, .results li)[data-eff-real]:not([data-eff-real=""]):focus-visible{
  outline: 2px solid var(--fam-ink);
  outline-offset: -2px;
}

/* --- 4. plain rows -----------------------------------------
   Still respond — they are list rows — but flatly: no edge, no
   tint, no lean. That gap is what makes a real row read as
   "this one is special". */
:is(.it, .results li):not([data-eff-real]:not([data-eff-real=""])):hover,
:is(.it, .results li):not([data-eff-real]:not([data-eff-real=""])):focus-visible{
  background-color: var(--panel2);
}

/* --- 5. cursor emphasis (opt-in) ---------------------------
   Put .fx-cursor on the LIST (.results / .items), not the row.
   Only sound where the row has no other click behaviour — see
   notes before using it on the website's card grid. */
.fx-cursor :is(.it, .results li)[data-eff-real]:not([data-eff-real=""]){
  cursor: pointer;
}
.fx-cursor :is(.it, .results li):not([data-eff-real]:not([data-eff-real=""])){
  cursor: default;
}

/* --- 6. minimalist mode ------------------------------------
   :root[data-fx-min="on"] — rows with nothing of their own go
   inert: no overlay, no entry motion, and no residue from a run
   that was already in flight when the switch was flipped.
   !important is deliberate: it is the only way to beat the
   inline style.animation / style.opacity the JS writes. */
:root[data-fx-min="on"] :is(.it, .results li):not([data-eff-real]:not([data-eff-real=""])){
  animation: none !important;
  transform: none !important;
  translate: none !important;
  opacity: 1 !important;
  --edge: 0px;
  --edge-c: transparent;
}

/* Kill the wash only where the overlay actually lives, so a row
   that uses ::after for its own decoration is left alone. */
:root[data-fx-min="on"] :is(.it, .results li):not([data-eff-real]:not([data-eff-real=""]))[data-eff]::after,
:root[data-fx-min="on"] :is(.it, .results li):not([data-eff-real]:not([data-eff-real=""])) [data-eff]::after{
  content: none !important;
  animation: none !important;
  opacity: 0 !important;
}

/* --- 7. reduced motion -------------------------------------
   Colour still fades (that is not motion); nothing moves. */
@media (prefers-reduced-motion: reduce){
  :is(.it, .results li){ --nudge: 0px; }
}
/* ============================================================
   Transient row effect overlays  —  [data-eff="<family>"]
   Single ::after per row. Static layered gradients, animated
   with opacity + transform ONLY. Every family ends at
   opacity:0 with fill-mode:both, so nothing is left behind.
   ============================================================ */

/* Row container. Keep this permanent (not toggled with the
   attribute) so setting data-eff never triggers a style/layout
   change on the row itself. */
.it,
.results li{
  position: relative;
  overflow: hidden;
  isolation: isolate;
}

/* --- base overlay ------------------------------------------ */
[data-eff]::after{
  content: "";
  position: absolute;
  inset: 0;
  z-index: -1;
  pointer-events: none;
  border-radius: inherit;
  opacity: 0;
  background-repeat: no-repeat;
  transform-origin: 50% 50%;
  animation-duration: .9s;
  animation-fill-mode: both;
  animation-timing-function: var(--ease, cubic-bezier(.2,.8,.2,1));
}

/* --- poison ------------------------------------------------- */
[data-eff="poison"]::after{
  --a: var(--ef-poison, var(--good, #7e9c46));
  --b: var(--ef-poison-2, #a8d05a);
  transform-origin: 50% 100%;
  background-image:
    radial-gradient(circle at 18% 76%, var(--b) 0 3px, transparent 4px),
    radial-gradient(circle at 35% 92%, var(--b) 0 2px, transparent 3px),
    radial-gradient(circle at 53% 82%, var(--b) 0 4px, transparent 5px),
    radial-gradient(circle at 72% 95%, var(--b) 0 2px, transparent 3px),
    radial-gradient(circle at 88% 78%, var(--b) 0 3px, transparent 4px),
    linear-gradient(to top, var(--a), transparent 46%);
  animation-name: efPoison;
  animation-duration: 1s;
}
@keyframes efPoison{
  0%   { opacity: 0;   transform: translateY(14%) scaleY(.90); }
  20%  { opacity: .50; transform: translateY(6%)  scaleY(.97); }
  60%  { opacity: .42; transform: translateY(-8%) scaleY(1.04); }
  74%  { opacity: .30; transform: translateY(-14%) scaleY(1.12); }
  100% { opacity: 0;   transform: translateY(-26%) scaleY(1.04); }
}

/* --- fire --------------------------------------------------- */
[data-eff="fire"]::after{
  --a: var(--ef-fire, var(--hot, #e2542b));
  --b: var(--ef-fire-2, var(--warn, #d9a441));
  transform-origin: 50% 100%;
  background-image:
    radial-gradient(circle at 24% 84%, var(--b) 0 2px, transparent 3px),
    radial-gradient(circle at 47% 94%, var(--b) 0 2px, transparent 3px),
    radial-gradient(circle at 69% 88%, var(--b) 0 3px, transparent 4px),
    radial-gradient(ellipse 24% 72% at 30% 100%, var(--b) 0 22%, transparent 70%),
    radial-gradient(ellipse 20% 62% at 63% 100%, var(--b) 0 22%, transparent 70%),
    linear-gradient(to top, var(--a), transparent 56%);
  animation-name: efFire;
  animation-duration: .95s;
}
@keyframes efFire{
  0%   { opacity: 0;   transform: translateY(16%)  scaleY(.72); }
  16%  { opacity: .58; transform: translateY(6%)   scaleY(.94); }
  44%  { opacity: .50; transform: translateY(-4%)  scaleY(1.08); }
  68%  { opacity: .32; transform: translateY(-13%) scaleY(.98); }
  100% { opacity: 0;   transform: translateY(-30%) scaleY(1.16); }
}

/* --- blood -------------------------------------------------- */
[data-eff="blood"]::after{
  --a: var(--ef-blood, var(--mark, #b81f22));
  --b: var(--ef-blood-2, #7a0f13);
  transform-origin: 0% 50%;
  background-image:
    radial-gradient(circle at 7% 38%, var(--a) 0 5px, transparent 6px),
    radial-gradient(circle at 15% 70%, var(--a) 0 3px, transparent 4px),
    radial-gradient(circle at 26% 28%, var(--a) 0 2px, transparent 3px),
    radial-gradient(ellipse 34% 92% at 0% 52%, var(--a) 0 38%, transparent 78%),
    linear-gradient(to right, var(--b), transparent 62%);
  animation-name: efBlood;
  animation-duration: 1.05s;
}
@keyframes efBlood{
  0%   { opacity: 0;   transform: translateY(0)   scaleX(.10); }
  14%  { opacity: .62; transform: translateY(0)   scaleX(.55); }
  38%  { opacity: .55; transform: translateY(0)   scaleX(1); }
  60%  { opacity: .44; transform: translateY(8%)  scaleX(1); }
  100% { opacity: 0;   transform: translateY(46%) scaleX(1); }
}

/* --- creep -------------------------------------------------- */
[data-eff="creep"]::after{
  --a: var(--ef-creep, rgba(30,7,11,.95));
  --b: var(--ef-creep-2, #6d1a22);
  transform-origin: 50% 100%;
  background-image:
    linear-gradient(to top, transparent 0 5%, var(--b) 6% 8%, transparent 11%),
    radial-gradient(ellipse 34% 34% at 26% 104%, var(--b) 0 44%, transparent 82%),
    radial-gradient(ellipse 40% 30% at 71% 104%, var(--b) 0 44%, transparent 82%),
    linear-gradient(to top, var(--a) 0 7%, transparent 30%);
  animation-name: efCreep;
  animation-duration: 1.1s;
}
@keyframes efCreep{
  0%   { opacity: 0;   transform: scaleX(.06) scaleY(.4); }
  18%  { opacity: .85; transform: scaleX(.55) scaleY(.9); }
  46%  { opacity: .80; transform: scaleX(1)   scaleY(1); }
  70%  { opacity: .58; transform: scaleX(1)   scaleY(.9); }
  100% { opacity: 0;   transform: scaleX(1)   scaleY(.6); }
}

/* --- frost -------------------------------------------------- */
[data-eff="frost"]::after{
  --a: var(--ef-frost, #6fc4e2);
  --b: var(--ef-frost-2, #d4f0fb);
  background-image:
    repeating-conic-gradient(from 22deg at 50% 50%, var(--b) 0 1.4deg, transparent 1.4deg 45deg),
    radial-gradient(ellipse 46% 130% at 50% 50%, var(--a) 0 14%, transparent 74%);
  background-size: 74px 100%, auto;
  background-position: 50% 0, 0 0;
  animation-name: efFrost;
  animation-duration: .9s;
}
@keyframes efFrost{
  0%   { opacity: 0;   transform: scale(.72) rotate(-3deg); }
  22%  { opacity: .62; transform: scale(1)   rotate(0deg); }
  52%  { opacity: .50; transform: scale(1.05) rotate(1deg); }
  100% { opacity: 0;   transform: scale(1.16) rotate(3deg); }
}

/* --- charm -------------------------------------------------- */
[data-eff="charm"]::after{
  --a: var(--ef-charm, #e0619b);
  --b: var(--ef-charm-2, #f7b3d0);
  background-image:
    radial-gradient(circle at 22% 38%, var(--b) 0 3px, transparent 4px),
    radial-gradient(circle at 78% 62%, var(--b) 0 2px, transparent 3px),
    radial-gradient(ellipse 66% 150% at 50% 50%, var(--a) 0 14%, transparent 70%);
  animation-name: efCharm;
  animation-duration: .85s;
}
@keyframes efCharm{
  0%   { opacity: 0;   transform: scale(.94); }
  20%  { opacity: .55; transform: scale(1.02); }
  42%  { opacity: .34; transform: scale(.99); }
  64%  { opacity: .50; transform: scale(1.05); }
  100% { opacity: 0;   transform: scale(1.10); }
}

/* --- luck --------------------------------------------------- */
[data-eff="luck"]::after{
  --a: var(--ef-luck, var(--warn, #d9a441));
  --b: var(--ef-luck-2, #f0c257);
  background-image:
    repeating-conic-gradient(from 45deg at 50% 50%, var(--b) 0 2.5deg, transparent 2.5deg 90deg),
    repeating-conic-gradient(from 45deg at 50% 50%, var(--b) 0 3deg,   transparent 3deg 90deg),
    radial-gradient(circle at 14% 30%, var(--a) 0 2px, transparent 3px),
    radial-gradient(circle at 45% 74%, var(--a) 0 2px, transparent 3px),
    radial-gradient(circle at 66% 24%, var(--a) 0 2px, transparent 3px),
    radial-gradient(circle at 88% 62%, var(--a) 0 2px, transparent 3px);
  background-size: 22px 22px, 14px 14px, auto, auto, auto, auto;
  background-position: 30% 34%, 72% 66%, 0 0, 0 0, 0 0, 0 0;
  animation-name: efLuck;
  animation-duration: .8s;
}
@keyframes efLuck{
  0%   { opacity: 0;   transform: scale(.62) rotate(-6deg); }
  14%  { opacity: .85; transform: scale(.9)  rotate(-3deg); }
  30%  { opacity: .32; transform: scale(.98) rotate(-1deg); }
  46%  { opacity: .80; transform: scale(1.02) rotate(1deg); }
  62%  { opacity: .28; transform: scale(1.07) rotate(3deg); }
  78%  { opacity: .55; transform: scale(1.11) rotate(4deg); }
  100% { opacity: 0;   transform: scale(1.18) rotate(6deg); }
}

/* --- shock -------------------------------------------------- */
[data-eff="shock"]::after{
  --a: var(--ef-shock, rgba(255,255,255,.95));
  background-image:
    radial-gradient(circle at 50% 50%, transparent 0 29%, var(--a) 32% 35.5%, transparent 39%);
  animation-name: efShock;
  animation-duration: .7s;
  animation-timing-function: cubic-bezier(.1,.75,.25,1);
}
@keyframes efShock{
  0%   { opacity: 0;   transform: scale(.2); }
  12%  { opacity: .80; transform: scale(.7); }
  46%  { opacity: .42; transform: scale(1.7); }
  100% { opacity: 0;   transform: scale(3); }
}

/* --- smoke -------------------------------------------------- */
[data-eff="smoke"]::after{
  --a: var(--ef-smoke, rgba(190,190,196,.85));
  transform-origin: 50% 100%;
  background-image:
    radial-gradient(ellipse 32% 78% at 29% 72%, var(--a) 0 10%, transparent 70%),
    radial-gradient(ellipse 28% 68% at 57% 84%, var(--a) 0 10%, transparent 68%),
    radial-gradient(ellipse 24% 62% at 80% 74%, var(--a) 0 10%, transparent 66%);
  animation-name: efSmoke;
  animation-duration: 1.1s;
}
@keyframes efSmoke{
  0%   { opacity: 0;   transform: translateY(20%)  scale(.7); }
  22%  { opacity: .42; transform: translateY(6%)   scale(.95); }
  55%  { opacity: .30; transform: translateY(-10%) scale(1.15); }
  100% { opacity: 0;   transform: translateY(-34%) scale(1.45); }
}

/* --- dark --------------------------------------------------- */
[data-eff="dark"]::after{
  --a: var(--ef-dark, #0a0410);
  --b: var(--ef-dark-2, #4a1f78);
  background-image:
    radial-gradient(circle at 50% 50%, transparent 0 16%, var(--b) 52%, var(--a) 100%);
  animation-name: efDark;
  animation-duration: .95s;
  animation-timing-function: cubic-bezier(.4,0,.2,1);
}
@keyframes efDark{
  0%   { opacity: 0;   transform: scale(1.8) rotate(0deg); }
  22%  { opacity: .60; transform: scale(1.3) rotate(4deg); }
  62%  { opacity: .50; transform: scale(.85) rotate(10deg); }
  100% { opacity: 0;   transform: scale(.42) rotate(18deg); }
}

/* --- holy --------------------------------------------------- */
[data-eff="holy"]::after{
  --a: var(--ef-holy, var(--warn, #d9a441));
  --b: var(--ef-holy-2, #f6e3b0);
  transform-origin: 50% 0%;
  background-image:
    linear-gradient(100deg, transparent 34%, var(--b) 47% 53%, transparent 66%),
    linear-gradient(82deg,  transparent 34%, var(--b) 47% 53%, transparent 66%),
    radial-gradient(ellipse 78% 130% at 50% -34%, var(--b) 0 22%, transparent 72%),
    linear-gradient(to bottom, var(--a), transparent 62%);
  background-size: 15% 100%, 11% 100%, auto, auto;
  background-position: 31% 0, 66% 0, 0 0, 0 0;
  animation-name: efHoly;
  animation-duration: 1s;
}
@keyframes efHoly{
  0%   { opacity: 0;   transform: translateY(-14%) scaleY(.70); }
  20%  { opacity: .55; transform: translateY(-4%)  scaleY(.92); }
  50%  { opacity: .46; transform: translateY(0)    scaleY(1.04); }
  100% { opacity: 0;   transform: translateY(8%)   scaleY(1.14); }
}

/* --- spark -------------------------------------------------- */
[data-eff="spark"]::after{
  --a: var(--ef-spark, rgba(255,255,255,.98));
  --b: var(--ef-spark-2, var(--warn, #d9a441));
  background-image:
    linear-gradient(66deg,  transparent 42%, var(--a) 49% 51%, transparent 58%),
    linear-gradient(-52deg, transparent 42%, var(--a) 49% 51%, transparent 58%),
    linear-gradient(78deg,  transparent 42%, var(--a) 49% 51%, transparent 58%),
    radial-gradient(circle at 33% 42%, var(--b) 0 2px, transparent 3px),
    radial-gradient(circle at 72% 60%, var(--b) 0 2px, transparent 3px);
  background-size: 20px 62%, 24px 74%, 16px 54%, auto, auto;
  background-position: 17% 28%, 47% 66%, 78% 34%, 0 0, 0 0;
  animation-name: efSpark;
  animation-duration: .7s;
  animation-timing-function: steps(1, end);
}
@keyframes efSpark{
  0%   { opacity: 0;   transform: scaleX(1)  scaleY(1); }
  10%  { opacity: .95; transform: scaleX(1)  scaleY(1); }
  20%  { opacity: 0;   transform: scaleX(-1) scaleY(1); }
  30%  { opacity: .80; transform: scaleX(-1) scaleY(1); }
  40%  { opacity: 0;   transform: scaleX(1)  scaleY(-1); }
  54%  { opacity: .90; transform: scaleX(1)  scaleY(-1); }
  66%  { opacity: 0;   transform: scaleX(-1) scaleY(-1); }
  80%  { opacity: .45; transform: scaleX(-1) scaleY(-1); }
  92%  { opacity: 0;   transform: scaleX(1)  scaleY(1); }
  100% { opacity: 0;   transform: scaleX(1)  scaleY(1); }
}

/* --- Angel (light marble) tuning ---------------------------- *
   Only the families whose default reads as "bright white/pale"
   need re-pointing so they don't wash out on a light row.      */
:root[data-theme="angel"]{
  --ef-shock:    rgba(24,32,48,.90);
  --ef-spark:    rgba(26,36,58,.95);
  --ef-smoke:    rgba(96,98,106,.75);
  --ef-frost-2:  #4f93b0;
  --ef-holy-2:   #e8bf6a;
  --ef-luck-2:   #c08a1e;
  --ef-charm-2:  #d9639a;
  --ef-poison-2: #6f8f2e;
  --ef-fire-2:   #c2691a;
}

/* --- reduced motion ----------------------------------------- */
@media (prefers-reduced-motion: reduce){
  [data-eff][data-eff]::after{
    animation-name: efFade;
    animation-duration: .7s;
    transform: none;
  }
}
@keyframes efFade{
  0%   { opacity: 0; }
  30%  { opacity: .32; }
  100% { opacity: 0; }
}
/* ---------- FX toggle switch ---------- */
.fx-line{display:flex;align-items:center;justify-content:space-between;gap:18px}
.fx-name{font-family:var(--sans);font-size:15px;letter-spacing:.02em;color:var(--ash)}
.fx-note{margin:10px 0 0;font-family:var(--sans);font-size:13px;line-height:1.55;color:var(--dim)}
.fx-note[hidden]{display:none}
.fx-note--rm{color:var(--warn);border-left:2px solid var(--warn);padding-left:12px}

.fxsw{
  --sw-w:54px;
  --sw-h:28px;
  --sw-pad:3px;
  --sw-knob:calc(var(--sw-h) - 2px - (var(--sw-pad) * 2));
  box-sizing:border-box;
  position:relative;
  flex:0 0 auto;
  display:block;
  width:var(--sw-w);
  height:var(--sw-h);
  margin:0;
  padding:0;
  border:1px solid var(--rule2);
  border-radius:999px;
  background:var(--pit);
  cursor:pointer;
  -webkit-appearance:none;
  appearance:none;
  transition:background var(--t) var(--ease), border-color var(--t) var(--ease);
}
.fxsw::after{
  content:"";
  position:absolute;
  top:var(--sw-pad);
  left:var(--sw-pad);
  width:var(--sw-knob);
  height:var(--sw-knob);
  border-radius:50%;
  background:var(--faint);
  transition:transform var(--t) var(--ease), background var(--t) var(--ease);
}
.fxsw:hover{border-color:var(--hot)}
.fxsw:focus-visible{outline:2px solid var(--hot);outline-offset:3px}

.fxsw[aria-checked="true"]{background:var(--mark);border-color:var(--hot)}
.fxsw[aria-checked="true"]::after{
  background:var(--ash);
  transform:translateX(calc(var(--sw-w) - 2px - (var(--sw-pad) * 2) - var(--sw-knob)));
}

/* light theme needs a touch more edge on the off state */
:root[data-theme="angel"] .fxsw{background:var(--panel2);border-color:var(--rule)}
:root[data-theme="angel"] .fxsw::after{background:var(--dim)}
:root[data-theme="angel"] .fxsw[aria-checked="true"]{background:var(--mark);border-color:var(--mark)}
:root[data-theme="angel"] .fxsw[aria-checked="true"]::after{background:var(--panel)}

@media (prefers-reduced-motion: reduce){
  .sw,.fxsw::after{transition:none}
}
/* ---------- effect animations ----------
   Drawn from the game's own catalogue rather than invented: entities2.xml lists 39
   tear variants (Stone, Bone, Needle, Razor, Balloon, Pupula, Hungry, Multidimensional
   ...) and 126 ENTITY_EFFECT rows (Bomb Explosion, Creep, Brimstone Swirl, Shockwave,
   Fart Ring, Poof, Blood Splat, BlackHole, Boomerang, Heaven Door, Mom Foot Stomp ...).
   Each one below is a motion taken from that list. Transform and opacity only, so a
   row costs a composite rather than a repaint. */

/* --- how a tear arrives and lands --- */
@keyframes fxTear{0%{opacity:0;transform:translateY(-26px) scale(.72,1.34)}
  56%{opacity:1;transform:translateY(0) scale(1)}
  73%{transform:scale(1.28,.64)}88%{transform:scale(.97,1.05)}100%{opacity:1;transform:none}}
@keyframes fxStone{0%{opacity:0;transform:translateY(-34px) scale(1.15)}
  48%{opacity:1;transform:translateY(0) scale(1.18,.8)}
  62%{transform:scale(.95,1.06)}78%{transform:translateX(-2px)}100%{opacity:1;transform:none}}
@keyframes fxBone{0%{opacity:0;transform:translateY(-22px) rotate(-24deg)}
  55%{opacity:1;transform:translateY(0) rotate(9deg)}
  75%{transform:rotate(-5deg)}100%{opacity:1;transform:none}}
@keyframes fxNeedle{0%{opacity:0;transform:translateX(-38px) scaleX(2.4) scaleY(.5)}
  52%{opacity:1;transform:translateX(4px) scaleX(.9) scaleY(1.05)}100%{opacity:1;transform:none}}
@keyframes fxRazor{0%{opacity:0;transform:translateX(-30px) skewX(-26deg) scaleY(.7)}
  45%{opacity:1;transform:translateX(5px) skewX(12deg)}100%{opacity:1;transform:none}}
@keyframes fxScythe{0%{opacity:0;transform:rotate(-42deg) translateX(-24px)}
  55%{opacity:1;transform:rotate(14deg) translateX(4px)}100%{opacity:1;transform:none}}
@keyframes fxBalloon{0%{opacity:0;transform:translateY(24px) scale(.7)}
  50%{opacity:1;transform:translateY(-7px) scale(1.08)}
  72%{transform:translateY(3px) scale(.97)}100%{opacity:1;transform:none}}
@keyframes fxPop{0%{opacity:0;transform:scale(.2)}38%{opacity:1;transform:scale(1.26)}
  60%{transform:scale(.9)}100%{opacity:1;transform:none}}
@keyframes fxPupula{0%{opacity:0;transform:scale(.28)}100%{opacity:1;transform:none}}
@keyframes fxHungry{0%{opacity:0;transform:scale(1.3,.55)}
  40%{opacity:1;transform:scale(.82,1.2)}66%{transform:scale(1.08,.92)}100%{opacity:1;transform:none}}
@keyframes fxMultidim{0%{opacity:0;transform:translateX(-26px) scaleX(2.2)}
  40%{opacity:.55;transform:translateX(6px) scaleX(.8)}
  64%{opacity:.85;transform:translateX(-3px) scaleX(1.1)}100%{opacity:1;transform:none}}
@keyframes fxDarkMatter{0%{opacity:0;transform:scale(1.5) rotate(18deg)}
  46%{opacity:.4;transform:scale(.86) rotate(-8deg)}100%{opacity:1;transform:none}}
@keyframes fxGlaucoma{0%{opacity:0;transform:scale(1.18,.86)}
  50%{opacity:.5;transform:scale(.94,1.08)}100%{opacity:1;transform:none}}
@keyframes fxMetallic{0%{opacity:0;transform:translateY(-20px) scaleX(.6)}
  46%{opacity:1;transform:translateY(0) scaleX(1.22)}
  64%{transform:scaleX(.92)}80%{transform:scaleX(1.04)}100%{opacity:1;transform:none}}
@keyframes fxTooth{0%{opacity:0;transform:translateY(-24px) rotate(16deg) scale(.8)}
  54%{opacity:1;transform:translateY(0) rotate(-6deg) scale(1.06)}100%{opacity:1;transform:none}}

/* --- impacts and explosions --- */
@keyframes fxBoom{0%{opacity:0;transform:scale(.5)}38%{opacity:1;transform:scale(1.22)}
  54%{transform:scale(.93) translateX(-5px)}68%{transform:scale(1.04) translateX(5px)}
  84%{transform:translateX(-2px)}100%{opacity:1;transform:none}}
@keyframes fxShockwave{0%{opacity:0;transform:scale(.35,.9)}
  44%{opacity:1;transform:scale(1.32,.94)}68%{transform:scale(.94,1.03)}100%{opacity:1;transform:none}}
@keyframes fxDebris{0%{opacity:0;transform:translate(-12px,-16px) rotate(-22deg) scale(.7)}
  46%{opacity:1;transform:translate(4px,3px) rotate(8deg) scale(1.06)}
  70%{transform:translate(-2px,0) rotate(-3deg)}100%{opacity:1;transform:none}}
@keyframes fxImpact{0%{opacity:0;transform:translateY(-18px)}
  44%{opacity:1;transform:translateY(0) scale(1.16,.82)}
  60%{transform:translateY(-6px) scale(.96,1.05)}78%{transform:translateY(0)}100%{opacity:1;transform:none}}
@keyframes fxStomp{0%{opacity:0;transform:translateY(-40px) scaleY(1.3)}
  40%{opacity:1;transform:translateY(0) scale(1.24,.66)}
  56%{transform:scale(.94,1.08)}72%{transform:scale(1.03,.98)}100%{opacity:1;transform:none}}
@keyframes fxSpike{0%{opacity:0;transform:translateY(20px) scaleY(.4)}
  42%{opacity:1;transform:translateY(-4px) scaleY(1.2)}100%{opacity:1;transform:none}}

/* --- fluids and ground --- */
@keyframes fxBloodSplat{0%{opacity:0;transform:translateY(-18px) scale(.75)}
  48%{opacity:1;transform:translateY(0) scale(1.3,.6)}
  66%{transform:scale(.92,1.12)}82%{transform:scale(1.05,.96)}100%{opacity:1;transform:none}}
@keyframes fxCreep{0%{opacity:0;transform:scale(.28,.16)}
  54%{opacity:1;transform:scale(1.2,.86)}100%{opacity:1;transform:none}}
@keyframes fxPuddle{0%{opacity:0;transform:scale(.5,.2)}
  60%{opacity:1;transform:scale(1.12,.94)}100%{opacity:1;transform:none}}
@keyframes fxDrip{0%{opacity:0;transform:translateY(-16px) rotate(-5deg)}
  46%{opacity:1;transform:translateY(3px) rotate(4deg)}
  72%{transform:translateY(-1px) rotate(-2deg)}100%{opacity:1;transform:none}}

/* --- air, fire, smoke --- */
@keyframes fxPoof{0%{opacity:0;transform:scale(1.4)}45%{opacity:1;transform:scale(.92)}
  70%{transform:scale(1.04)}100%{opacity:1;transform:none}}
@keyframes fxFart{0%{opacity:0;transform:scale(.62)}44%{opacity:1;transform:scale(1.24) skewX(8deg)}
  70%{transform:scale(.96) skewX(-3deg)}100%{opacity:1;transform:none}}
@keyframes fxEmber{0%{opacity:0;transform:translateY(12px) scaleY(1.22)}
  30%{opacity:.72;transform:translateY(-4px) scaleY(.92)}
  54%{opacity:1;transform:translateY(1px) scaleY(1.08)}
  76%{opacity:.9;transform:translateY(-2px) scaleY(.97)}100%{opacity:1;transform:none}}
@keyframes fxWisp{0%{opacity:0;transform:translateY(18px) scale(.86)}
  58%{opacity:.9;transform:translateY(-6px) scale(1.04)}100%{opacity:1;transform:none}}

/* --- beams and lasers --- */
@keyframes fxBrimstone{0%{opacity:0;transform:translateX(-50px) scaleX(2)}
  44%{opacity:1;transform:translateX(6px) scaleX(.86)}
  66%{transform:scaleX(1.06)}100%{opacity:1;transform:none}}
@keyframes fxLaser{0%{opacity:0;transform:scaleX(.1)}
  40%{opacity:1;transform:scaleX(1.3)}62%{transform:scaleX(.94)}100%{opacity:1;transform:none}}
@keyframes fxCrackSky{0%{opacity:0;transform:translateY(-36px) scaleY(1.5) scaleX(.7)}
  46%{opacity:1;transform:translateY(0) scale(1)}
  62%{transform:scale(1.14,.9)}100%{opacity:1;transform:none}}

/* --- pulls, arcs, warps --- */
@keyframes fxBlackHole{0%{opacity:0;transform:scale(1.6) rotate(-26deg)}
  50%{opacity:.85;transform:scale(.82) rotate(10deg)}100%{opacity:1;transform:none}}
@keyframes fxBoomerang{0%{opacity:0;transform:translateX(-34px) rotate(-90deg)}
  50%{opacity:1;transform:translateX(9px) rotate(24deg)}
  74%{transform:translateX(-4px) rotate(-8deg)}100%{opacity:1;transform:none}}
@keyframes fxWarp{0%{opacity:0;transform:scale(1.55)}28%{opacity:.16;transform:scale(.86)}
  52%{opacity:1;transform:scale(1.06)}100%{opacity:1;transform:none}}
@keyframes fxHoming{0%{opacity:0;transform:translate(-30px,18px) rotate(-13deg)}
  55%{opacity:1;transform:translate(5px,-5px) rotate(5deg)}100%{opacity:1;transform:none}}
@keyframes fxRocket{0%{opacity:0;transform:translateY(26px) scaleY(1.3)}
  44%{opacity:1;transform:translateY(-6px) scaleY(.94)}100%{opacity:1;transform:none}}

/* --- creatures --- */
@keyframes fxSkitter{0%{opacity:0;transform:translate(-18px,-11px)}
  28%{opacity:1;transform:translate(6px,5px)}46%{transform:translate(-5px,-4px)}
  64%{transform:translate(3px,2px)}80%{transform:translate(-1px,-1px)}100%{opacity:1;transform:none}}
@keyframes fxOrbit{0%{opacity:0;transform:translate(26px,-17px) rotate(28deg)}
  55%{opacity:1;transform:translate(-6px,4px) rotate(-10deg)}100%{opacity:1;transform:none}}
@keyframes fxLeech{0%{opacity:0;transform:scale(.6,1.4)}
  42%{opacity:1;transform:scale(1.2,.78)}66%{transform:scale(.92,1.08)}100%{opacity:1;transform:none}}

/* --- room and ritual --- */
@keyframes fxHeavenDoor{0%{opacity:0;transform:translateY(-30px) scale(.9)}
  60%{opacity:1;transform:translateY(4px) scale(1.03)}100%{opacity:1;transform:none}}
@keyframes fxDevil{0%{opacity:0;transform:translateY(26px) scale(1.08)}
  52%{opacity:1;transform:translateY(-5px) scale(.97)}100%{opacity:1;transform:none}}
@keyframes fxPentagram{0%{opacity:0;transform:rotate(-200deg) scale(.5)}100%{opacity:1;transform:none}}
@keyframes fxShield{0%{opacity:0;transform:scale(1.4)}54%{opacity:1;transform:scale(.95)}
  74%{transform:scale(1.03)}100%{opacity:1;transform:none}}
@keyframes fxFireworks{0%{opacity:0;transform:scale(.44)}42%{opacity:1;transform:scale(1.2)}
  62%{transform:scale(.94)}80%{transform:scale(1.05)}100%{opacity:1;transform:none}}
@keyframes fxCoinFlip{0%{opacity:0;transform:rotateY(96deg) scale(.82)}100%{opacity:1;transform:none}}
@keyframes fxChest{0%{opacity:0;transform:translateY(-14px) scaleY(.7)}
  50%{opacity:1;transform:translateY(0) scaleY(1.14)}100%{opacity:1;transform:none}}

/* --- status --- */
@keyframes fxPetrify{0%{opacity:0;transform:translateY(-18px)}
  50%{opacity:1;transform:translateY(0) scale(1.08,.86)}58%{transform:none}100%{opacity:1;transform:none}}
@keyframes fxCharm{0%{opacity:0;transform:scale(.78) rotate(-10deg)}
  40%{opacity:1;transform:scale(1.07) rotate(8deg)}70%{transform:rotate(-4deg)}100%{opacity:1;transform:none}}
@keyframes fxFear{0%{opacity:0;transform:translateX(17px)}34%{opacity:1;transform:translateX(-8px)}
  54%{transform:translateX(5px)}74%{transform:translateX(-2px)}100%{opacity:1;transform:none}}
@keyframes fxConfuse{0%{opacity:0;transform:rotate(-196deg) scale(.54)}100%{opacity:1;transform:none}}
@keyframes fxSlow{0%{opacity:0;transform:translateY(-13px) scale(1.06)}
  72%{opacity:.86;transform:translateY(2px) scale(1.01)}100%{opacity:1;transform:none}}
@keyframes fxCharge{0%{opacity:0;transform:scale(.85)}56%{opacity:.9;transform:scale(.91)}
  76%{transform:scale(1.14)}100%{opacity:1;transform:none}}

dialog{border:1px solid var(--rule2);background:var(--panel);color:var(--ash);border-radius:3px;
  max-width:520px;width:92vw;padding:0}
dialog::backdrop{background:rgba(0,0,0,.66);backdrop-filter:blur(3px)}
/* The two new indexes put a filter beside the box; the items view stacks chips
   under it, so the row behaviour is opt-in rather than on .searchwrap itself. */
.searchwrap.row{display:flex;gap:10px;align-items:stretch}
.searchwrap.row input{flex:1;min-width:0}
/* A near-black swatch on a near-black page reads as a missing dot without this. */
.dots i{box-shadow:inset 0 0 0 1px rgba(232,217,198,.22)}
.sel{background:var(--panel2);color:var(--ash);border:1px solid var(--rule2);border-radius:3px;
  padding:9px 10px;font:inherit;font-size:13px}
/* Badges are 263x176 hand-drawn cards, not pixel art: smooth scaling, and the
   parchment stock they were drawn for or the dark ink vanishes on either theme. */
.badge{background-color:#cdbfa4;border:1px solid #8a7a5f;border-radius:2px;flex:0 0 auto;
  image-rendering:auto;background-repeat:no-repeat}
.foe{image-rendering:pixelated;background-repeat:no-repeat;flex:0 0 auto}
.dlg .badge{margin-bottom:4px}
.dlg{padding:20px 22px 24px}
.dlg .top{display:flex;gap:15px;align-items:flex-start}
.dlg h3{font-family:var(--serif);font-size:23px;margin:0 0 5px;font-weight:400}
.dlg .tags{display:flex;flex-wrap:wrap;gap:4px;margin-top:7px}
.tg{font-family:var(--mono);font-size:8.5px;letter-spacing:.13em;text-transform:uppercase;
  padding:2px 6px;border:1px solid var(--rule2);color:var(--faint)}
.tg.ok{color:var(--good);border-color:var(--goodLine)}
.dlg p.body{white-space:pre-line;color:var(--dim);font-size:13.5px;margin:16px 0 0}
.dlg h4{font-family:var(--mono);font-size:8.5px;letter-spacing:.22em;text-transform:uppercase;
  color:var(--faint);margin:18px 0 5px;font-weight:400}
.dlg .pools{font-family:var(--mono);font-size:11.5px;color:var(--dim)}
.x{position:absolute;top:12px;right:14px;background:none;border:none;color:var(--faint);
  font-size:18px;cursor:pointer;line-height:1}
.x:hover{color:var(--mark)}

footer{border-top:1px solid var(--rule);padding:34px 0 60px;color:var(--faint);font-size:12.5px}
footer a{color:var(--dim)}
@media(prefers-reduced-motion:reduce){
  *,*::before,*::after{animation-duration:.001ms!important;transition-duration:.001ms!important}
  #rain{display:none}
}
</style>

<canvas id="rain"></canvas>

<nav>
  <span class="brand">Isaac <b>Companion</b></span>
  <button class="tab on" data-v="home">Home</button>
  <span class="tabwrap" data-menu="items">
      <button class="tab" data-v="index" id="itemsTab"
              aria-haspopup="menu" aria-expanded="false" aria-controls="itemsMenu">Items</button>
      <div class="tabmenu" id="itemsMenu" role="menu" aria-labelledby="itemsTab">
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="" aria-current="true">
          <span class="tabmenu-ic ic-all" aria-hidden="true"></span>
          <span class="tabmenu-l">All items</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
        <div class="tabmenu-sep" role="separator"></div>
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="passive">
          <span class="tabmenu-ic ic-passive" aria-hidden="true"></span>
          <span class="tabmenu-l">Passive</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="active">
          <span class="tabmenu-ic ic-active" aria-hidden="true"></span>
          <span class="tabmenu-l">Active</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="familiar">
          <span class="tabmenu-ic ic-familiar" aria-hidden="true"></span>
          <span class="tabmenu-l">Familiars</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="trinket">
          <span class="tabmenu-ic ic-trinket" aria-hidden="true"></span>
          <span class="tabmenu-l">Trinkets</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="card">
          <span class="tabmenu-ic ic-card" aria-hidden="true"></span>
          <span class="tabmenu-l">Cards</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
        <button class="tabmenu-i" role="menuitem" tabindex="-1" data-kind="pill">
          <span class="tabmenu-ic ic-pill" aria-hidden="true"></span>
          <span class="tabmenu-l">Pills</span>
          <span class="tabmenu-n" data-count aria-hidden="true"></span>
        </button>
      </div>
    </span>
  <button class="tab" data-v="foes">Enemies</button>
  <button class="tab" data-v="unlocks">Unlocks</button>
  <button class="tab" data-v="settings">Settings</button>
  <span class="sp"></span>
  <button id="theme"><span id="tg">⛧</span> <span id="tn">Devil</span></button>
  <a class="navlink" href="#features">Features</a>
  <a class="navlink" href="#source">Source</a>
  <a class="navlink" href="#get">Download</a>
</nav>

<!-- ===================== HOME ===================== -->
<div class="view on" id="home">
  <div class="wrap">
    <header class="hero">
      <p class="eyebrow">macOS &#183; Afterbirth+ &#183; no mod required</p>
      <h1 id="head"></h1>
      <p class="sell">Isaac never tells you what your stats actually are. This reads the game's
        own log while you play, works out your real damage and fire rate, and warns you when an
        item you just took is <b>doing nothing at all</b>.</p>
      <div class="cta">
        <button class="btn" id="dl1">Download for macOS &#183; __DMGMB__ MB</button>
        <button class="btn ghost" data-goto="index">Browse all 775 items</button>
      </div>
      <div class="specimen">
        <span class="halo"></span>
        <span class="spr" id="hspr"></span>
        <span class="cap" id="hcap"></span>
      </div>
    </header>
  </div>

  <section class="band">
    <div class="wrap rv">
      <h2>Your build, while you're in it</h2>
      <p class="lead">Every number is computed from your actual run — base stat, what the items
        did, and the total. Damage runs through a square-root curve, so "+0.3 Damage" is almost
        never worth +0.3.</p>
      <div class="demo" id="demo">
        <div class="bar"><i style="background:#c4453f"></i><i style="background:#d9964a"></i>
          <i style="background:#8fa758"></i><span>Isaac Companion</span></div>
        <div class="in">
          <div class="rail">
            <div class="cellx hot"><div class="k">Damage</div><div class="v">6.12</div>
              <div class="mtr"><i data-w="62"></i></div></div>
            <div class="cellx"><div class="k">Tears</div><div class="v">1.15</div>
              <div class="mtr dn"><i data-w="44"></i></div></div>
            <div class="cellx"><div class="k">Range</div><div class="v">29.00</div>
              <div class="mtr"><i data-w="22"></i></div></div>
            <div class="cellx"><div class="k">Speed</div><div class="v">1.70</div>
              <div class="mtr"><i data-w="55"></i></div></div>
          </div>
          <div class="mini">
            <div class="mrow"><span class="spr" data-gfx="collectibles_118_brimstone.png"></span>
              <div><div class="nm">Brimstone</div><div class="ds">Chargeable blood laser &#183; 13&#215; damage</div></div></div>
            <div class="mrow dead"><span class="spr" data-gfx="collectibles_068_technology.png"></span>
              <div><div class="nm">Technology</div>
                <div class="ds cut">Overridden by Brimstone &#8212; 666 over 400</div></div></div>
          </div>
        </div>
      </div>
    </div>
  </section>

  <section class="band">
    <div class="wrap rv">
      <h2>Why bother</h2>
      <p class="lead">Four things no wiki and no in-game mod can do, because none of them know
        what you are already carrying.</p>
      <div class="grid">
        <div class="card"><div class="n">Dead items</div><h3>Knows when a pickup is wasted</h3>
          <p>Take Technology while holding Brimstone and the laser never fires. The app reads
            Afterbirth+'s real precedence ladder and says so, instead of leaving you to wonder.</p></div>
        <div class="card"><div class="n">Real numbers</div><h3>Your stats, not the wiki's</h3>
          <p>Base + change = total, on every stat, reconciling on screen. Clamps and multipliers
            included; anything the game doesn't document is marked estimated rather than guessed.</p></div>
        <div class="card"><div class="n">Zero input</div><h3>Tracks itself</h3>
          <p>It tails the log Isaac already writes. Nothing is injected, no mod is enabled — so
            your Steam achievements keep counting.</p></div>
        <div class="card"><div class="n">Re-rolls</div><h3>Worth the D6?</h3>
          <p>Scores the pedestal against everything still in that pool, weighted properly, using
            your current build — and refuses to answer for items a stat score can't represent.</p></div>
      </div>
    </div>
  </section>

  <section class="band" id="features">
    <div class="wrap rv">
      <h2>Everything in it</h2>
      <p class="lead">Four things, and they all run off one log file the game already
        writes.</p>

      <div class="grid">
        <div class="card"><div class="n">Overlay</div><h3>What that item just did</h3>
          <p>A borderless always-on-top panel over the fullscreen game. It does not just
            show your stats &#8212; it shows the <b>change your last pickup made</b>, per
            stat, held until the next one. Ipecac reads <b>+21.00</b> damage and
            <b>&#8722;2.55</b> tears, with the item's name underneath.</p></div>

        <div class="card"><div class="n">Overlay</div><h3>Built how you want it</h3>
          <p>Around 35 settings in their own tab, with a live mini-screen of your actual
            display: drag the miniature to move the real window, click a part to take it
            off. Click-through, corner snapping, per-display placement, opacity, text
            scale, compact mode, accent stat. It appears when Isaac launches and gets out
            of the way when you quit.</p></div>

        <div class="card"><div class="n">Browser</div><h3>775 items, by description</h3>
          <p>Every item, card, pill and trinket &#8212; searchable by name, by effect, or
            by <b>colour measured off the sprite itself</b>, so "grey" or "gold" finds the
            one you half-remember. 359 enemies with HP, 403 achievements with their unlock
            conditions and full-size art.</p></div>

        <div class="card"><div class="n">Browser</div><h3>Sprites that move</h3>
          <p>Enemy icons play the idle loop from their own animation files, pills cycle
            every colour the game deals, and an item with a real baked-in effect gets a
            backdrop drawn for that effect &#8212; poison creeps, fire licks up from the
            floor, brimstone sweeps across. Off-screen rows stop animating entirely.</p></div>

        <div class="card"><div class="n">Run</div><h3>Pills and cards, read off the screen</h3>
          <p>The log says a pocket item was used but never which one &#8212; and by then the
            slot is empty. So the slot is read beforehand and the use is attributed to it.
            A <b>card is named outright</b>; a pill is harder, because the game reshuffles
            which colour does what every run, so you say what one did <b>once</b> and every
            later pill of that colour counts itself. Ones taken before you named the colour
            are backfilled.</p></div>

        <div class="card"><div class="n">Run</div><h3>Numbers checked against the game</h3>
          <p>Turn on the comparison table, type what the HUD shows, and any disagreement is
            a bug in the stat model rather than in your reading of it. It found three of
            Cain's six base stats wrong. At the start of a run the HUD <b>is</b> the
            character's baseline, so those numbers can be saved as measured base stats
            &#8212; play a character once and its row is settled from the game itself, not
            from a wiki.</p></div>

        <div class="card"><div class="n">Advisor</div><h3>Worth taking?</h3>
          <p>In a Devil, Treasure or Angel room it reads the pedestals off the screen
            &#8212; passively, no injection &#8212; and scores what is on them against
            your build and what is left in that pool. It refuses to answer where a stat
            score cannot represent the item.</p></div>

        <div class="card"><div class="n">Windows</div><h3>The same engine</h3>
          <p>A single 440&#160;KB executable with no installer and no runtime. It runs the
            <b>same log parser and the same stat model</b>, tested against the same
            fixtures, and serves the readout in your browser. The overlay and the pedestal
            scanner are macOS window-server features, so they are absent rather than
            faked.</p></div>
      </div>
    </div>
  </section>

  <section class="band" id="source">
    <div class="wrap rv">
      <div class="osslead">
        <div>
          <h2>Open source</h2>
          <p class="lead">Every line of it is on GitHub under the MIT licence &#8212; the
            Swift app, the Windows build, the data pipeline and the page you are reading.
            The stat model is the part worth reading: it is commented with <em>why</em>
            each number is what it is, and which ones nobody can settle.</p>
          <div class="cta" style="opacity:1;animation:none">
            <a class="btn" href="__REPO__" target="_blank" rel="noopener">View on GitHub</a>
            <a class="btn ghost" href="__REPO__/blob/main/README.md" target="_blank"
               rel="noopener">Read the README</a>
          </div>
        </div>
        <div class="ossfacts">
          <div class="ossfact"><b>MIT</b><span>licence</span></div>
          <div class="ossfact"><b>127</b><span>tests</span></div>
          <div class="ossfact"><b>0</b><span>runtime deps</span></div>
        </div>
      </div>

      <div class="grid" style="margin-top:26px">
        <div class="card"><div class="n">Not in the repo</div><h3>Nobody else's work</h3>
          <p>The item descriptions come from the External Item Descriptions mod, which
            ships without a licence &#8212; so that snapshot is not redistributed. It is
            generated from your own install at build time, along with every sprite and
            every item name, which come out of your own copy of the game.</p></div>
        <div class="card"><div class="n">Verified, not asserted</div><h3>Both engines agree</h3>
          <p>The Windows stat engine is tested against the same fixtures as the macOS
            one &#8212; Ipecac is exactly 24.50, Sad Onion floors to 3.75/s. If the two
            builds ever disagree about a number, the test fails instead of your screen
            being quietly wrong.</p></div>
        <div class="card"><div class="n">A fan tool</div><h3>Not affiliated</h3>
          <p>The Binding of Isaac is Nicalis and Edmund McMillen's. This reads a log file
            the game already writes and never touches the game, which is the whole reason
            your achievements keep counting.</p></div>
      </div>
    </div>
  </section>

  <section class="band" id="get">
    <div class="wrap rv">
      <div class="getlead">
        <img class="appicon" alt="" width="96" height="96" src="data:image/png;base64,__ICONB64__">
        <div>
          <h2>Get it</h2>
          <p class="lead">One build, every Mac: the binary is universal &#8212; arm64 and
            x86_64 in the same file &#8212; so an M-series Mac and a 2017 Intel MacBook run
            the same download natively, with no Rosetta and nothing to choose between.
            There is a Windows build too, further down.</p>
        </div>
      </div>

      <!-- Filled in by the platform check. Written into the markup as the macOS case
           so the page still says something useful with scripting off. -->
      <div class="detect" id="detect">
        <span class="dot" id="detect-dot"></span>
        <span id="detect-text">Checking what you are on&#8230;</span>
      </div>

      <!-- One button, front and centre. The grid of four equal cards that used to be
           here made you pick a format before you could do anything, which is a
           decision most people do not have and should not need. The detection already
           knows the answer, so it answers: this button IS the right build, named and
           sized, and the alternatives sit underneath for the people who want them. -->
      <div class="dlhero">
        <a class="dlmain" id="dlmain" data-kind="dmg" href="#">
          <span class="dlmain-arrow" aria-hidden="true">&#8595;</span>
          <span class="dlmain-text">
            <span class="dlmain-title" id="dlmain-title">Download</span>
            <span class="dlmain-sub" id="dlmain-sub">working out which build you need&#8230;</span>
          </span>
        </a>
        <p class="dlmain-note" id="dlmain-note"></p>
      </div>

      <div class="dlalt" id="dlalt">
        <span class="dlalt-label">Other formats</span>
        <button class="chip dlopt" data-kind="dmg">DMG &#183; disk image</button>
        <button class="chip dlopt" data-kind="pkg">PKG &#183; installer</button>
        <button class="chip dlopt" data-kind="zip">ZIP &#183; just the app</button>
        <button class="chip dlopt win" data-kind="exe">EXE &#183; Windows</button>
      </div>

      <p class="lead" style="margin-top:22px">A notarised release would just open. This one
        is ad-hoc signed, so macOS quarantines it on download &#8212; one command clears
        that, and it is shown here rather than hidden.</p>
      <div class="demo"><div class="in" style="font-family:var(--mono);font-size:12.5px;line-height:2.1">
        <div style="color:var(--faint)"># after installing, clear the quarantine flag</div>
        <div>$ xattr -dr com.apple.quarantine /Applications/IsaacCompanion.app</div>
        <div>$ open /Applications/IsaacCompanion.app</div>
      </div></div>

      <div class="grid" style="margin-top:26px">
        <div class="card"><div class="n">On first launch</div><h3>It finds your game</h3>
          <p>Reads Steam's own manifest to see which release you own &#8212; Rebirth,
            Afterbirth, Afterbirth+, Repentance or Repentance+ &#8212; and picks the matching
            log file, description set and data expectations.</p></div>
        <div class="card"><div class="n">Verified on</div><h3>Afterbirth+</h3>
          <p>Every number in the app is checked against Afterbirth+ values. Other releases
            are detected and wired up, but their item and pool tables live inside game
            archives, so they are only built once you own that release.</p></div>
        <div class="card"><div class="n">Needs</div><h3>macOS or Windows</h3>
          <p>Item data is extracted from your own install, once, on first run. Nothing is downloaded and no mod is enabled, so achievements keep counting. The Mac build is universal &#8212; Apple&#160;Silicon and Intel in one binary; the Windows build is a single executable.</p></div>
      </div>
    </div>
  </section>

  <footer><div class="wrap">
    Item data derived from your own Afterbirth+ install and the
    External Item Descriptions project. Colours are measured from the game's sprites.
    Not affiliated with Nicalis or Edmund McMillen.
  </div></footer>
</div>

<!-- ===================== INDEX ===================== -->
<div class="view" id="index">
  <div class="wrap">
    <div class="searchwrap">
      <input id="q" placeholder="Describe it &#8212; &#8220;grey&#8221;, &#8220;gold&#8221;, &#8220;locked&#8221;, or just the name…" autocomplete="off">
      <div class="chips" id="chips"></div>
    <div class="sortrow">
      <label class="sortlab" for="qsort">Sort</label>
      <select id="qsort" class="sel">
        <option value="">Best match</option>
        <option value="name">Name A-Z</option>
        <option value="name-desc">Name Z-A</option>
        <option value="id">Number, grouped by kind</option>
        <option value="kind">Kind, then name</option>
        <option value="charge">Charge cost, low first</option>
        <option value="devil">Devil price, cheapest first</option>
        <option value="conf">Least verified first</option>
      </select>
    </div>
    </div>
    <p class="count" id="count"></p>
    <div class="items" id="list"></div>
  </div>
</div>

<!-- ===================== ENEMIES ===================== -->
<div class="view" id="foes">
  <div class="wrap">
    <div class="searchwrap row">
      <input id="fq" placeholder="Describe it &#8212; &#8220;red fly&#8221;, &#8220;black&#8221;, or just the name…" autocomplete="off">
      <select id="ff" class="sel">
        <option value="fight">Enemies &amp; bosses</option>
        <option value="boss">Bosses only</option>
        <option value="all">Everything, incl. effects &amp; pickups</option>
      </select>
      <div class="sortrow">
        <label class="sortlab" for="fsort">Sort</label>
        <select id="fsort" class="sel">
          <option value="">Default order</option>
          <option value="name">Name A-Z</option>
          <option value="hp-desc">Health, high to low (floor 5)</option>
          <option value="hp-asc">Health, low to high (floor 5)</option>
          <option value="boss">Bosses first</option>
          <option value="type">Type number</option>
        </select>
      </div>
    </div>
    <p class="count" id="fcount"></p>
    <div class="items" id="flist"></div>
  </div>
</div>

<!-- ===================== UNLOCKS ===================== -->
<div class="view" id="unlocks">
  <div class="wrap">
    <div class="searchwrap row">
      <input id="aq" placeholder="Search achievements &#8212; a name, a condition, or what it gives you…" autocomplete="off">
    </div>
    <p class="count" id="acount"></p>
    <div class="items" id="alist"></div>
  </div>
</div>

<div class="view" id="settings">
  <section class="band">
    <div class="wrap">
      <h2>Settings</h2>
      <p class="lead">Motion and effects are two separate switches — turn either one off and the other keeps working. Your choice is remembered in this browser.</p>

      <p class="fx-note fx-note--rm" id="fxRmNote" hidden>Your system is set to reduce motion, so both switches start off. You can still turn either one on.</p>

      <div class="grid">
        <div class="card">
          <div class="fx-line">
            <span class="fx-name" id="fxAnimLbl">Entry animations</span>
            <button type="button" class="fxsw" id="fxAnimSw" role="switch" aria-checked="true" aria-labelledby="fxAnimLbl" aria-describedby="fxAnimHelp"></button>
          </div>
          <p class="fx-note" id="fxAnimHelp">The slide-and-fade a row makes as it scrolls into view. Off means rows simply appear in place.</p>
        </div>

        <div class="card">
          <div class="fx-line">
            <span class="fx-name" id="fxEffLbl">Effect overlays</span>
            <button type="button" class="fxsw" id="fxEffSw" role="switch" aria-checked="true" aria-labelledby="fxEffLbl" aria-describedby="fxEffHelp"></button>
          </div>
          <p class="fx-note" id="fxEffHelp">The poison, fire, and blood wash that plays across a row and fades. Off means rows stay plain.</p>
        </div>
        <!-- ===== WEBSITE PANEL — add these two .card blocks inside <div class="grid"> ===== -->
        <div class="card">
          <div class="fx-line">
            <span class="fx-name" id="fxMinLbl">Minimalist effects</span>
            <button type="button" class="fxsw" id="fxMinSw" role="switch" aria-checked="false" aria-labelledby="fxMinLbl" aria-describedby="fxMinHelp"></button>
          </div>
          <p class="fx-note" id="fxMinHelp">On, only things that really do it in-game move — Ipecac drips, Brimstone burns, and everything else sits perfectly still. Off, plain items borrow a stand-in effect so the whole list has some life to it.</p>
        </div>
        
        <div class="card">
          <div class="fx-line">
            <span class="fx-name" id="fxBgLbl">Animated backgrounds</span>
            <button type="button" class="fxsw" id="fxBgSw" role="switch" aria-checked="true" aria-labelledby="fxBgLbl" aria-describedby="fxBgHelp"></button>
          </div>
          <p class="fx-note" id="fxBgHelp">When you open an item that has a real effect, that effect drifts behind its card. Off keeps the same backdrop, it just holds still instead of moving.</p>
        </div>
        
        <!-- ============================================================ -->
      </div>
    </div>
  </section>
</div>

<dialog id="dlg"><button class="x" id="dx">&#215;</button><div class="dlg" id="dbody"></div></dialog>

<script>
const D = __DATA__;

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
const $ = (id) => document.getElementById(id);

/* ---- theme ---- */
// Declared up here on purpose: setTheme() calls paintRain(), which reads this. A `let`
// further down puts it in the temporal dead zone and the whole script dies on load.
let rainCol = "#b81f22";
const T = { devil:{g:"\u26E7",n:"Devil"}, angel:{g:"\u271D",n:"Angel"} };
function setTheme(t, animate){
  const r = document.documentElement;
  r.classList.add("noT");
  if (t === "devil") r.removeAttribute("data-theme"); else r.setAttribute("data-theme", t);
  requestAnimationFrame(()=>requestAnimationFrame(()=>r.classList.remove("noT")));
  $("tg").textContent = T[t].g; $("tn").textContent = T[t].n;
  try{ localStorage.setItem("t", t); }catch(e){}
  paintRain();
}
$("theme").onclick = () => setTheme(
  document.documentElement.getAttribute("data-theme") === "angel" ? "devil" : "angel", true);
try{ setTheme(localStorage.getItem("t") || "devil"); }catch(e){ setTheme("devil"); }

/* ---- views ---- */
document.querySelectorAll(".tab").forEach(b=>b.onclick=()=>show(b.dataset.v));
document.querySelectorAll("[data-goto]").forEach(b=>b.onclick=()=>show(b.dataset.goto));
function show(v){
  document.querySelectorAll(".view").forEach(x=>x.classList.toggle("on", x.id===v));
  document.querySelectorAll(".tab").forEach(x=>x.classList.toggle("on", x.dataset.v===v));
  window.scrollTo({top:0});
  if (v === "index") $("q").focus();
  if (v === "foes"){ if(!$("flist").children.length) renderFoes(); $("fq").focus(); }
  if (v === "unlocks"){ if(!$("alist").children.length) renderAchs(); $("aq").focus(); }
}

/* ---- sprites, off the shared atlas ---- */
/* The three sheets are 103, 440 and 609 KB of base64. Assigning one to
   el.style.backgroundImage per row meant rebuilding that whole string for every
   sprite on screen -- 400 rows x 609 KB is why the achievements list took 1.1s to
   redraw on each keystroke. They are set once as custom properties instead, and the
   per-element styles carry nothing but geometry. */
const ROOTS = document.documentElement.style;
ROOTS.setProperty("--sheet-items", `url(${D.atlas})`);
if(D.monsters) ROOTS.setProperty("--sheet-mon", `url(${D.monsters.uri})`);
if(D.badges) ROOTS.setProperty("--sheet-bdg", `url(${D.badges.uri})`);
if(D.pills) ROOTS.setProperty("--sheet-pills", `url(${D.pills.uri})`);

/* The sheets are 11 and 19 megapixels. Left alone, the browser decodes one the first
   time a row scrolls into view -- synchronously, on the main thread, which showed up
   as a single 640ms stall mid-scroll. decode() does that work up front and off the
   critical path, so the first scroll is as smooth as the rest. */
(function warmSheets(){
  const uris = [D.atlas, D.monsters && D.monsters.uri, D.badges && D.badges.uri,
                D.pills && D.pills.uri].filter(Boolean);
  const warm = () => uris.forEach(u => {
    const img = new Image();
    img.src = u;
    if (img.decode) img.decode().catch(()=>{});
  });
  if ("requestIdleCallback" in window) requestIdleCallback(warm, {timeout: 1200});
  else setTimeout(warm, 200);
})();

function spriteInto(el, frame, scale){
  if(!frame){ el.style.opacity=.25; return; }
  const s = scale || 1;
  el.style.width = el.style.height = (D.cell*s)+"px";
  el.style.backgroundSize = `${D.atlasWidth*s}px ${D.atlasHeight*s}px`;
  el.style.backgroundPosition = `-${frame[0]*s}px -${frame[1]*s}px`;
}
/* Every item except a pill is a cell of the atlas; a pill is its own colour strip --
   but only if the build produced one. Without it the atlas still holds a usable
   single pill frame, and falling through to that beats an empty tile. */
function itemInto(el, it, scale){
  if(it.kind === "pill" && D.pills) pillInto(el, scale);
  else spriteInto(el, it.frame, scale);
}
const byGfx = {};
D.items.forEach(i=>{ if(i.frame) byGfx[i.name.toLowerCase()] = i.frame; });

/* ---- hero title, letter by letter ---- */
(function(){
  const words = ["Know ","what ","you ","just ","","picked ","up."];
  const h = $("head"); let d = 0.18;
  words.forEach((w,i)=>{
    if(w===""){ h.appendChild(document.createElement("br")); return; }
    const s = document.createElement("span");
    s.textContent = w; s.style.animationDelay = (d += .075) + "s";
    if(i>=5) s.innerHTML = `<em>${w}</em>`;
    h.appendChild(s);
  });
})();

/* ---- hero specimen: a different item on every visit ---- */
(function(){
  const pool = D.items.filter(i=>i.frame && i.kind!=="card" && i.kind!=="pill" && i.text);
  const pick = pool[Math.floor(Math.random()*pool.length)];
  if(!pick) return;
  spriteInto($("hspr"), pick.frame, 3);
  $("hcap").textContent = pick.name;
})();

/* ---- blood / light rain ---- */
const cv = $("rain"), cx = cv.getContext("2d");
let drops = [], W=0, H=0;
function resize(){ W=cv.width=innerWidth; H=cv.height=innerHeight;
  drops = Array.from({length: Math.min(90, Math.round(W/16))}, ()=>mk(true)); }
function mk(any){ return {x:Math.random()*W, y:any?Math.random()*H:-20,
  v:.7+Math.random()*2.1, l:7+Math.random()*17, w:Math.random()<.14?2:1, a:.16+Math.random()*.4}; }
function paintRain(){
  rainCol = getComputedStyle(document.documentElement).getPropertyValue("--mark").trim() || "#b81f22";
}
let rainOn = true;
function tick(){
  if(!rainOn || document.hidden || !document.getElementById("home").classList.contains("on")){
    cx.clearRect(0,0,W,H);
    return requestAnimationFrame(tick);
  }
  cx.clearRect(0,0,W,H);
  cx.lineCap = "round";
  for(const d of drops){
    cx.globalAlpha = d.a; cx.strokeStyle = rainCol; cx.lineWidth = d.w;
    cx.beginPath(); cx.moveTo(d.x,d.y); cx.lineTo(d.x, d.y+d.l); cx.stroke();
    d.y += d.v*2.1;
    if(d.y > H+20) Object.assign(d, mk(false));
  }
  cx.globalAlpha = 1;
  requestAnimationFrame(tick);
}
if(!matchMedia("(prefers-reduced-motion: reduce)").matches){
  addEventListener("resize", resize); resize(); paintRain(); tick();
}

/* ---- scroll reveals + the demo's meters ---- */
/* Deliberately NOT unobserved: leaving the viewport winds the section back so that
   scrolling up and coming back down plays it again. The meters have to be zeroed on
   the way out too, or they would already be full when the section returns. */
const meterTimers = new WeakMap();
const io = new IntersectionObserver(es=>es.forEach(e=>{
  const bars = e.target.querySelectorAll?.(".mtr i") || [];
  clearTimeout(meterTimers.get(e.target));
  if(e.isIntersecting){
    e.target.classList.add("in");
    bars.forEach((b,n)=>{
      const t = setTimeout(()=>b.style.width = b.dataset.w+"%", 120+n*110);
      if(n === 0) meterTimers.set(e.target, t);
    });
  } else {
    e.target.classList.remove("in");
    bars.forEach(b=>b.style.width = "0%");
  }
}),{threshold:.16});
document.querySelectorAll(".rv").forEach(e=>io.observe(e));
document.querySelectorAll("#demo .spr").forEach(el=>{
  const f = byGfx[({"collectibles_118_brimstone.png":"brimstone",
    "collectibles_068_technology.png":"technology"})[el.dataset.gfx]];
  spriteInto(el, f);
});

/* ---- the index ----
   Search matches name, description AND measured sprite colour, so "grey" or
   "red syringe" work when you cannot remember what the thing is called. */
const COLORS = {};
D.items.forEach(i=>i.colors.forEach(c=>COLORS[c]=(COLORS[c]||0)+1));
const SWATCH = {red:"#b81f22",orange:"#e2542b",gold:"#d9a441",green:"#7e9c46",teal:"#4a9c95",
  blue:"#3f6fb5",purple:"#7a4a9c",pink:"#d98ca8",brown:"#7a5230",grey:"#8d8d8d",
  white:"#efe7d8",black:"#1a1414"};
let active = new Set();
const chips = $("chips");
Object.keys(COLORS).sort((a,b)=>COLORS[b]-COLORS[a]).forEach(c=>{
  const b = document.createElement("button");
  b.className = "chip";
  b.innerHTML = `<span class="sw" style="background:${SWATCH[c]||"#888"}"></span>${c} ${COLORS[c]}`;
  b.onclick = ()=>{ active.has(c) ? active.delete(c) : active.add(c);
    b.classList.toggle("on"); render(); };
  chips.appendChild(b);
});

/* ---- incremental lists ----
   Building every row up front is what made opening a tab feel slow: the browser had
   to lay out and rasterise 400 rows before it could paint the first one. Each list now
   renders just enough to fill the viewport and grows when you reach the end, so the
   first paint is immediate and each new batch fades in as it arrives. */
const BATCH = 24;
const pagers = new WeakMap();
function paginate(list, rows, makeRow){
  pagers.get(list)?.disconnect();          // a new search supersedes the old list
  list.querySelectorAll(".it").forEach(el=>{ fxIO.unobserve(el); restIO.unobserve(el); });
  // A new result set invalidates the old scroll depth: filter 400 rows down to ten
  // while you are 5000px in and you would be left staring at blank page.
  const listTop = list.getBoundingClientRect().top + scrollY;
  if(scrollY > listTop) scrollTo({top: Math.max(0, listTop - 90)});
  list.textContent = "";
  let n = 0;
  const sentinel = document.createElement("div");
  sentinel.className = "more";
  const io2 = new IntersectionObserver(es=>{ if(es.some(e=>e.isIntersecting)) grow(); },
    {rootMargin: "600px 0px"});            // start the next batch before it is needed
  pagers.set(list, io2);
  list.appendChild(sentinel);

  function grow(){
    // A new search wipes the list, but this pager may already have a top-up queued on
    // the next frame. Its sentinel is gone from the DOM by then, and insertBefore
    // throws NotFoundError. Bail rather than fight for a list we no longer own.
    if(!sentinel.isConnected) return;
    if(n >= rows.length){ io2.disconnect(); sentinel.remove(); return; }
    const frag = document.createDocumentFragment();
    const end = Math.min(n + BATCH, rows.length);
    for(let i = n; i < end; i++){
      const el = makeRow(rows[i], i);
      frag.appendChild(el);
      fxIO.observe(el);
      restIO.observe(el);
    }
    n = end;
    list.insertBefore(frag, sentinel);
    if(n >= rows.length){ io2.disconnect(); sentinel.remove(); return; }
    // A tall window can swallow a whole batch without the sentinel ever leaving the
    // viewport, and the observer only fires on a CHANGE -- so top it up explicitly.
    requestAnimationFrame(()=>{
      const r = sentinel.getBoundingClientRect();
      if(r.top < innerHeight + 600) grow();
    });
  }
  io2.observe(sentinel);
  grow();
}

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

const FX_REDUCED = matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ---- replay on every scroll ----
   Rows re-shuffle whenever they come back into view, so scrolling up and down deals a
   different hand each time rather than freezing whatever played first. */
/* ---- replay on every scroll ----
   Rows re-shuffle whenever they come back into view, so scrolling up and down deals a
   different hand each time rather than freezing whatever played first.

   Cost is bounded by how many may START at once rather than by how fast you scroll.
   A velocity gate was tried first and removed: it suppressed exactly the scroll-up-
   and-back motion this is meant to replay, and measuring showed the effects were only
   ever worth ~12fps of a fling anyway -- the rest of that cost is batch loading and
   sprite rasterisation, which no gate here can help. */
const FX_MAX_AT_ONCE = 26;
const fxIO = new IntersectionObserver(es=>{
  if(FX_REDUCED) return;
  const entering = [];
  for(const e of es){
    e.target.style.setProperty("--fx-run", "none");   // wound back, ready to replay
    e.target.removeAttribute("data-eff");
    if(e.isIntersecting) entering.push(e.target);
  }
  if(!entering.length) return;
  // Restarting a CSS animation needs a reflow between clearing the name and setting
  // it. One read for the whole batch flushes the same pending style, once, instead of
  // forcing a synchronous layout per row.
  void document.body.offsetWidth;
  const n = Math.min(entering.length, FX_MAX_AT_ONCE);
  for(let i = 0; i < n; i++){
    const el = entering[i];
    const choice = fxPick(el);
    if(!choice) continue;                 // minimalist: nothing of its own to show
    // Two independent switches. The choice is made either way so the overlay still
    // matches what the row would have done with motion turned off.
    if(window.FX_ANIM_ON !== false)
      el.style.setProperty("--fx-run",
        `${choice.anim} .5s var(--ease) ${(Math.random()*70)|0}ms both`);
    if(window.FX_EFF_ON !== false) el.dataset.eff = choice.eff;
  }
}, {rootMargin: "0px 0px -6% 0px"});

/* Rows that have scrolled out of view stop animating.

   A list keeps every row it has ever paged in, and each one carries a sprite that
   is now playing its own frames: the item index alone had 824 running animations,
   and a running animation ticks whether or not anyone can see it. Resting the
   off-screen ones is what buys back the headroom for the visible ones.

   `paused`, not `none`: none would rewind every sprite to frame 0, so scrolling
   back up would show a wall of enemies all restarting in step. Paused holds the
   frame the row was on and picks up exactly where it left off.

   The margin is generous on purpose -- a row wakes well before it can be seen, so
   it is already mid-cycle when it arrives, and the fade-out happens off-screen. */
const restIO = new IntersectionObserver(es=>{
  for(const e of es) e.target.classList.toggle("rest", !e.isIntersecting);
}, {rootMargin: "280px 0px"});

const KIND = {passive:"passive",active:"active",familiar:"familiar",trinket:"trinket",card:"card",pill:"pill"};
function score(it, terms){
  const name = it.name.toLowerCase(), text = it.text.toLowerCase();
  let s = 0;
  for(const t of terms){
    let hit = 0;
    if(name === t) hit = 100;
    else if(name.startsWith(t)) hit = 60;
    else if(name.includes(t)) hit = 40;
    if(it.colors.includes(t)) hit = Math.max(hit, 45);
    if(KIND[t] === it.kind) hit = Math.max(hit, 30);
    if((t === "locked" || t === "unlockable") && it.unlock) hit = Math.max(hit, 42);
    if(!hit && text.includes(t)) hit = 14;
    if(!hit) return -1;                 // every term must land somewhere
    s += hit;
  }
  return s;
}
function render(){
  const raw = $("q").value.trim().toLowerCase();
  const terms = raw ? raw.split(/\s+/) : [];
  let out = D.items;
  // Set by the Items menu; empty means every kind.
  if(window.kindFilter) out = out.filter(i=>i.kind === window.kindFilter);
  if(active.size) out = out.filter(i=>[...active].every(c=>i.colors.includes(c)));
  if(terms.length){
    out = out.map(i=>({i, s:score(i, terms)})).filter(x=>x.s >= 0)
             .sort((a,b)=>b.s-a.s || a.i.id-b.i.id).map(x=>x.i);
  }
  $("count").textContent = `${out.length} of ${D.items.length} items`
    + (active.size ? ` · ${[...active].join(" + ")}` : "");
  const list = $("list");
  if(!out.length){ pagers.get(list)?.disconnect(); list.innerHTML = `<p class="none">Nothing matches that description.</p>`; return; }
  paginate(list, Sort.apply("#qsort", out), (it)=>{
    const el = document.createElement("div");
    el.className = "it";
    fxApply(el, fxFor(it.name, it.text + " " + it.kind));
    fxItemVars(el, it);
    fxIdleVar(el, it.name);
    fxHoverBind(el);
    const sp = document.createElement("span"); sp.className="spr";
    itemInto(sp, it);
    const body = document.createElement("div");
    body.innerHTML =
      `<div class="nm"></div><div class="meta">${it.kind} · #${it.id}</div>`
      + `<div class="ds"></div><div class="dots"></div>`;
    body.querySelector(".nm").textContent = it.name;
    body.querySelector(".ds").textContent = it.text.replace(/\{\{[^}]*\}\}/g,"").replace(/#/g," \u00b7 ");
    it.colors.forEach(c=>{ const d=document.createElement("i");
      d.style.background = SWATCH[c]||"#888"; d.title=c; body.querySelector(".dots").appendChild(d); });
    el.append(sp, body);
    el.onclick = ()=>{ window.fxFrom = sp; open(it); };
    return el;
  });
}
/* ---- the enemy and badge sheets: their own cells, so their own painter ---- */
function sheetInto(el, sheet, key, scale){
  const f = sheet && key ? sheet.frames[String(key).toLowerCase()] : null;
  const s = scale || 1;
  /* A cell can hold several frames side by side -- the enemy sheet packs each
     entity's idle loop into one -- so the box is a FRAME wide, not a cell. */
  const n = (sheet && sheet.steps) || 1;
  const cw = (sheet ? sheet.cellW : 32);
  const w = cw / n * s, h = (sheet ? sheet.cellH : 32) * s;
  el.style.width = w+"px"; el.style.height = h+"px";
  if(!f){ el.style.opacity=.25; return; }
  el.style.backgroundSize = `${sheet.width*s}px ${sheet.height*s}px`;
  el.style.backgroundPosition = `-${f[0]*s}px -${f[1]*s}px`;
  if(n > 1){
    /* The idle plays by walking background-position-x across the cell; the two
       endpoints go through custom properties so one @keyframes serves them all. */
    el.style.setProperty("--strip-x", `-${f[0]*s}px`);
    /* cw, not w: w is already scaled, and scaling it twice lands the last frame
       a third of the way across the cell. One whole cell of travel, stepped n
       times, is exactly one frame per step. */
    el.style.setProperty("--strip-end", `-${(f[0] + cw)*s}px`);
    el.style.setProperty("--strip-steps", n);
    el.classList.add("sprite-anim");
  }
}

/* Pills are the one item with no icon of its own: the game reshuffles which colour
   carries which effect every run, so there is no such thing as "the red pill". The
   icon is every colour instead, cycled through one strip of 32px frames.
   The count comes from the strip rather than being written here as well: it was in
   three places at once (the harvest, this function, and the steps() in the CSS) and
   nothing made them agree -- a shorter strip would have been stretched to the old
   width and every frame would have landed off-register, quietly. */
const PILL_CYCLE =
  parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--pill-cycle"))
  || 3400;
function pillInto(el, scale){
  const n = D.pills.frames, w = 32 * (scale || 1);
  el.classList.add("pillspr");
  el.style.width = el.style.height = w+"px";
  el.style.backgroundSize = `${w*n}px ${w}px`;
  el.style.setProperty("--strip-end", `-${w*n}px`);
  el.style.setProperty("--strip-steps", n);
  /* Every pill on the same frame at the same moment. A CSS animation starts when
     its element is created and rows arrive in batches as you scroll, so a plain 0s
     delay would leave each batch in its own phase. Winding the clock back by how
     far we already are into the current cycle puts a row created now exactly where
     one created at page load would be. */
  el.style.setProperty("--strip-d", `-${performance.now() % PILL_CYCLE}ms`);
}

/* ---- enemies ---- */
const FOES = D.enemies || [];
function renderFoes(){
  const raw = $("fq").value.trim().toLowerCase();
  const terms = raw ? raw.split(/\s+/) : [];
  const mode = $("ff").value;
  let out = FOES;
  // Eleven effect rows carry boss="1" upstream with 0 HP (Crack The Sky, BlackHoleRay),
  // so "bosses" has to mean fightable bosses or those reappear at the top of the list.
  if(mode === "boss") out = out.filter(e=>e.boss && e.fight);
  else if(mode !== "all") out = out.filter(e=>e.fight);
  if(terms.length){
    out = out.filter(e=>{
      const hay = (e.name + " " + (e.colors||[]).join(" ")).toLowerCase();
      return terms.every(t=>hay.includes(t));
    });
  }
  $("fcount").textContent = `${out.length} of ${FOES.length} entities`;
  const list = $("flist");
  if(!out.length){ pagers.get(list)?.disconnect(); list.innerHTML = `<p class="none">Nothing matches that description.</p>`; return; }
  paginate(list, Sort.apply("#fsort", out), (e)=>{
    const el = document.createElement("div"); el.className = "it";
    fxApply(el, fxForEnemy(e));
    fxItemVars(el, e);
    fxIdleVar(el, e.name);
    if(e.boss && e.fight) el.dataset.boss = "1";
    fxHoverBind(el);
    const sp = document.createElement("span"); sp.className = "foe";
    sheetInto(sp, D.monsters, e.art, 0.375);
    const body = document.createElement("div");
    const bits = [e.hp + " HP"];
    if(e.stageHP > 0) bits.push("+" + e.stageHP + " per floor");
    bits.push("type " + e.type + "." + e.variant);
    body.innerHTML = `<div class="nm"></div><div class="meta">${bits.join(" \u00b7 ")}</div>`
      + `<div class="ds"></div><div class="dots"></div>`;
    body.querySelector(".nm").textContent = e.name
      + (e.boss && e.fight ? "  \u2014 boss" : e.fight ? "" : "  \u2014 not an enemy");
    body.querySelector(".ds").textContent = (e.colors||[]).join(", ");
    (e.colors||[]).forEach(c=>{ const d=document.createElement("i");
      d.style.background = SWATCH[c]||"#888"; d.title=c; body.querySelector(".dots").appendChild(d); });
    el.append(sp, body);
    el.onclick = ()=>{ window.fxFrom = sp; openFoe(e); };
    return el;
  });
}
function openFoe(e){
  const b = $("dbody");
  b.innerHTML = `<div class="top"><span class="foe" id="ds"></span><div>
    <h3></h3><div class="tags"></div></div></div>`;
  b.querySelector("h3").textContent = e.name;
  sheetInto(b.querySelector("#ds"), D.monsters, e.art, 1);
  const tags = b.querySelector(".tags");
  const add = (t,cls)=>{ const s=document.createElement("span"); s.className="tg "+(cls||"");
    s.textContent=t; tags.appendChild(s); };
  if(e.boss && e.fight) add("boss","ok");
  if(!e.fight) add("not an enemy");
  add(e.type + "." + e.variant);
  (e.colors||[]).forEach(c=>add(c));
  const sec = (title, text, cls)=>{
    const h=document.createElement("h4"); h.textContent=title; b.appendChild(h);
    const p=document.createElement("p"); p.className=cls||"pools"; p.textContent=text; b.appendChild(p);
  };
  sec("Health", e.stageHP > 0
    ? `${e.hp} base, +${e.stageHP} per floor \u2014 ${e.hp + e.stageHP*4} on floor 5`
    : String(e.hp));
  sec("Room clear", e.blocks
    ? "Holds the doors shut \u2014 the room is not clear until it is dead."
    : "Does not hold the doors shut. Clearing the room ignores it.");
  if((e.colors||[]).length)
    sec("Colours", "Measured from the sprite\u2019s own pixels \u2014 nothing in the game "
      + "files describes what an enemy looks like.");
  fxDressCard(fxForEnemy(e), e);
  $("dlg").showModal();
  fxZoomInto(window.fxFrom, $("ds")); window.fxFrom = null;
}
$("fq").addEventListener("input", renderFoes);
$("ff").addEventListener("change", renderFoes);

/* ---- achievements ---- */
const ACHS = D.achievements || [];
function renderAchs(){
  const q = $("aq").value.trim().toLowerCase();
  let out = ACHS;
  if(q) out = out.filter(a=>
    a.name.toLowerCase().includes(q) || (a.condition||"").toLowerCase().includes(q)
    || (a.gives||[]).some(g=>g.toLowerCase().includes(q)));
  $("acount").textContent = `${out.length} of ${ACHS.length} achievements`;
  const list = $("alist");
  if(!out.length){ pagers.get(list)?.disconnect(); list.innerHTML = `<p class="none">Nothing matches.</p>`; return; }
  paginate(list, out, (a)=>{
    const el = document.createElement("div"); el.className = "it";
    // A badge is a card the game deals you, so it flips, drops or glints in rather
    // than pretending to be a tear effect.
    fxApply(el, fxForBadge(a));
    fxIdleVar(el, a.name);
    const sp = document.createElement("span"); sp.className = "badge";
    sheetInto(sp, D.badges, a.gfx, 0.25);
    const body = document.createElement("div");
    body.innerHTML = `<div class="nm"></div><div class="meta">#${a.id}</div><div class="ds"></div>`;
    body.querySelector(".nm").textContent = a.name;
    body.querySelector(".ds").textContent = a.condition || "";
    el.append(sp, body);
    el.onclick = ()=>{ window.fxFrom = sp; openAch(a); };
    return el;
  });
}
function openAch(a){
  const b = $("dbody");
  b.innerHTML = `<div class="top"><span class="badge" id="ds"></span></div><h3></h3>`;
  b.querySelector("h3").textContent = a.name;
  sheetInto(b.querySelector("#ds"), D.badges, a.gfx, 1);
  const h=document.createElement("h4"); h.textContent="How you get it"; b.appendChild(h);
  const p=document.createElement("p");
  p.className = a.known ? "pools" : "pools unknown";
  p.textContent = a.condition; b.appendChild(p);
  if((a.gives||[]).length){
    const h2=document.createElement("h4"); h2.textContent="What it gives you"; b.appendChild(h2);
    const g=document.createElement("div"); g.className="pools"; g.textContent=a.gives.join(", ");
    b.appendChild(g);
  }
  fxDressCard(null);
  $("dlg").showModal();
  fxZoomInto(window.fxFrom, $("ds")); window.fxFrom = null;
}
$("aq").addEventListener("input", renderAchs);

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

function fxDressCard(split, subject){
  const b = $("dbody");
  b.classList.add("fxbg");
  if(subject) fxItemVars(b, subject);
  b.classList.toggle("no-bg-anim", window.FX_BG_ON === false);
  if(split && split.real.length && window.FX_EFF_ON !== false)
    b.dataset.effReal = FX_FAMILY[split.real[0]] || "blood";
  else b.removeAttribute("data-eff-real");
}

function open(it){
  const b = $("dbody");
  b.innerHTML = `<div class="top"><span class="spr" id="ds"></span><div>
    <h3></h3><div class="tags"></div></div></div>
    <p class="body"></p>`;
  b.querySelector("h3").textContent = it.name;
  itemInto(b.querySelector("#ds"), it, 2);
  const tags = b.querySelector(".tags");
  const add = (t,cls)=>{ const s=document.createElement("span"); s.className="tg "+(cls||"");
    s.textContent=t; tags.appendChild(s); };
  add(it.kind); add("#"+it.id);
  if(it.charges) add(it.charges+" charges");
  if(it.devil) add(it.devil+" heart(s)");
  if(it.confidence && it.confidence!=="nonNumeric")
    add(it.confidence==="crossChecked"?"cross-checked":it.confidence, it.confidence==="verified"?"ok":"");
  it.colors.forEach(c=>add(c));
  b.querySelector(".body").textContent =
    it.text.replace(/\{\{[^}]*\}\}/g,"").replace(/#/g,"\n").trim() || "No description.";
  if(it.unlock){
    const h=document.createElement("h4"); h.textContent="How you unlock it"; b.appendChild(h);
    const u=document.createElement("p");
    u.className = it.unlockKnown ? "pools" : "pools unknown";
    u.textContent = it.unlock; b.appendChild(u);
  }
  if(it.pools.length){
    const h=document.createElement("h4"); h.textContent="Item pools"; b.appendChild(h);
    const p=document.createElement("div"); p.className="pools"; p.textContent=it.pools.join(", ");
    b.appendChild(p);
  }
  fxDressCard(fxFor(it.name, it.text + " " + it.kind), it);
  $("dlg").showModal();
  fxZoomInto(window.fxFrom, $("ds")); window.fxFrom = null;
}
$("dx").onclick = ()=>$("dlg").close();
$("dlg").onclick = (e)=>{ if(e.target.id==="dlg") $("dlg").close(); };
$("q").addEventListener("input", render);
render();

/* ---- downloads ----
   Resolved at build time to GitHub Release URLs, so the page itself still makes no
   network request -- it just holds ordinary links, and the browser fetches only what
   someone actually clicks. When a release asset is missing, the URL falls back to the
   Releases page: a link that always works beats a button that does nothing. */
const DOWNLOADS = __DOWNLOADS__;
function dlURL(kind){ return (DOWNLOADS[kind] || {}).url || __RELEASES__; }
function download(kind){ window.location.href = dlURL(kind); }
document.querySelectorAll(".dlopt").forEach(b=>{
  b.onclick = ()=>download(b.dataset.kind);
});
/* The old hero button at the top of the page, still there, still the Mac default. */
{ const b=$("dl1"); if(b) b.onclick = ()=>download("dmg"); }

/* ---- what are you on? ----
   Deliberately NOT trying to tell Apple Silicon from Intel. A browser cannot do it
   honestly -- Safari reports "Intel Mac OS X" on every Mac ever made, and the WebGL
   renderer string is a guess that breaks under fingerprint blocking. It also would
   not matter: the binary is universal, so both Macs take the same file. Detection
   only has to answer "which single build should this button hand you", and that it
   can do. */
(function detectPlatform(){
  const box = $("detect"), text = $("detect-text"), main = $("dlmain");
  if(!box || !text || !main) return;

  const ua = navigator.userAgent || "";
  const uaData = navigator.userAgentData;
  const plat = (uaData && uaData.platform) || navigator.platform || "";
  const hay = (plat + " " + ua).toLowerCase();
  // iPadOS reports itself as a Mac; the touch-point count is what separates them.
  const iPad = /macintel/i.test(plat) && navigator.maxTouchPoints > 1;
  const mac = !iPad && (/mac/.test(hay)) && !/iphone|ipad|ipod/.test(hay);
  const ios = iPad || /iphone|ipad|ipod/.test(hay);
  const win = /win/.test(hay) && !/darwin/.test(hay);
  const android = /android/.test(hay);
  const linux = !android && /linux|x11|cros/.test(hay);

  const NAMES = { dmg:"Disk image", pkg:"Installer", zip:"App bundle", exe:"Windows executable" };
  /* Points the one button at a build and says, on the button, exactly what that is. */
  const aim = (kind, title, note) => {
    main.dataset.kind = kind;
    main.href = dlURL(kind);
    $("dlmain-title").textContent = title;
    const mb = (DOWNLOADS[kind] || {}).mb || "?";
    $("dlmain-sub").textContent = NAMES[kind] + "  \u00b7  " + kind.toUpperCase() + "  \u00b7  " + mb + " MB";
    $("dlmain-note").innerHTML = note;
    document.querySelectorAll(".dlopt").forEach(c=>
      c.classList.toggle("current", c.dataset.kind === kind));
  };
  const set = (cls, html)=>{ box.className = "detect " + cls; text.innerHTML = html; };

  if(mac){
    set("ok", "You are on a <b>Mac</b> &#8212; this runs natively on Apple&nbsp;Silicon "
      + "and on Intel.");
    aim("dmg", "Download for macOS",
      "Opens a window; drag the app to Applications. Needs macOS&nbsp;14 or newer. "
      + "One universal binary &#8212; nothing to choose between.");
    return;
  }
  if(win){
    set("ok", "You are on <b>Windows</b>.");
    aim("exe", "Download for Windows",
      "A single executable &#8212; no installer, nothing to unpack. Runs the same log "
      + "reader and the same stat model as the Mac build; the overlay and the pedestal "
      + "scanner are macOS-only and are not in it.");
    return;
  }
  // Not a platform it runs on. Still give the button a sensible target, because the
  // commonest reason to be here on Linux or a phone is fetching it for another machine.
  aim("dmg", "Download for macOS",
    "You are not on a machine this runs on, so nothing is pre-selected for you "
    + "&#8212; pick the build for wherever you are installing it.");
  if(linux){
    set("no", "You are on <b>Linux</b>. There is no Linux build &#8212; the reference "
      + "above works fine here, though.");
  } else if(ios || android){
    set("no", "You are on a <b>phone or tablet</b>. It is a desktop app, but this "
      + "reference is built to work at this size.");
  } else {
    set("", "Could not tell what you are on. There are builds for macOS&nbsp;14+ and "
      + "for Windows.");
  }
})();

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

/* Each menu entry wears a real sprite from the game rather than a glyph: one
   representative item per kind, the card is The Fool, the pill is the pickup. The
   counts come from the data so they can never drift from what the list shows. */
(function menuIcons(){
  const PICK = { "": "The D6", passive: "The Sad Onion", active: "The Bible",
    familiar: "Brother Bobby", trinket: "Swallowed Penny",
    card: "0 - The Fool", pill: "Bad Gas" };
  function paint(){
    const counts = {};
    for(const it of D.items) counts[it.kind] = (counts[it.kind] || 0) + 1;
    counts[""] = D.items.length;
    document.querySelectorAll(".tabmenu-i").forEach(b=>{
      const kind = b.dataset.kind || "";
      const n = b.querySelector(".tabmenu-n");
      if(n) n.textContent = counts[kind] != null ? counts[kind] : "";
      const el = b.querySelector(".tabmenu-ic");
      const src = D.items.find(i=>i.name === PICK[kind] && i.frame)
        || D.items.find(i=>i.kind === kind && i.frame);
      if(!el || !src) return;
      el.style.backgroundImage = `url(${D.atlas})`;
      el.style.backgroundSize = `${D.atlasWidth}px ${D.atlasHeight}px`;
      el.style.backgroundPosition = `-${src.frame[0]}px -${src.frame[1]}px`;
      el.style.imageRendering = "pixelated";
    });
  }
  if(document.readyState === "loading") addEventListener("DOMContentLoaded", paint);
  else paint();
})();

(function () {
  var MODES = [
    { key: 'fxMin', global: 'FX_MIN_ON', attr: 'data-fx-min', def: false, sw: 'fxMinSw', box: 'fx-min' },
    { key: 'fxBg',  global: 'FX_BG_ON',  attr: 'data-fx-bg',  def: true,  sw: 'fxBgSw',  box: 'fx-bg'  }
  ];

  function read(m) {
    try {
      var v = localStorage.getItem(m.key);
      if (v === 'on' || v === '1' || v === 'true') return true;
      if (v === 'off' || v === '0' || v === 'false') return false;
    } catch (e) {}
    return m.def;
  }

  function write(m, on) {
    try { localStorage.setItem(m.key, on ? 'on' : 'off'); } catch (e) {}
  }

  function apply(m, on) {
    window[m.global] = on;
    document.documentElement.setAttribute(m.attr, on ? 'on' : 'off');
    var sw = document.getElementById(m.sw);
    if (sw) sw.setAttribute('aria-checked', on ? 'true' : 'false');
    var box = document.getElementById(m.box);
    if (box) box.checked = on;
  }

  function set(m, on) { write(m, on); apply(m, on); }

  window.fxSyncModes = function () {
    for (var i = 0; i < MODES.length; i++) apply(MODES[i], read(MODES[i]));
  };

  function wire(m) {
    var sw = document.getElementById(m.sw);
    if (sw && !sw.dataset.fxWired) {
      sw.dataset.fxWired = '1';
      sw.addEventListener('click', function () {
        set(m, sw.getAttribute('aria-checked') !== 'true');
      });
    }
    var box = document.getElementById(m.box);
    if (box && !box.dataset.fxWired) {
      box.dataset.fxWired = '1';
      box.addEventListener('change', function () { set(m, box.checked); });
    }
  }

  function init() {
    for (var i = 0; i < MODES.length; i++) wire(MODES[i]);
    window.fxSyncModes();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

/* ---------- FX settings: entry animations + effect overlays (independent) ---------- */
(function () {
  var K_ANIM = 'fxAnim', K_EFF = 'fxEff';

  var reduce = false;
  try {
    reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  } catch (e) {}

  function load(key, dflt) {
    try {
      var v = window.localStorage.getItem(key);
      if (v === '1') return true;
      if (v === '0') return false;
    } catch (e) {}
    return dflt;
  }

  function save(key, on) {
    try { window.localStorage.setItem(key, on ? '1' : '0'); } catch (e) {}
  }

  var fx = { anim: load(K_ANIM, !reduce), eff: load(K_EFF, !reduce) };

  function apply() {
    window.FX_ANIM_ON = fx.anim;
    window.FX_EFF_ON  = fx.eff;

    var r = document.documentElement;
    r.setAttribute('data-fx-anim', fx.anim ? 'on' : 'off');
    r.setAttribute('data-fx-eff',  fx.eff  ? 'on' : 'off');

    if (!fx.eff) {
      var live = document.querySelectorAll('[data-eff]');
      for (var i = 0; i < live.length; i++) live[i].removeAttribute('data-eff');
    }
  }

  apply();

  function wire(btnId, prop, storeKey) {
    var b = document.getElementById(btnId);
    if (!b) return;
    b.setAttribute('aria-checked', fx[prop] ? 'true' : 'false');
    b.addEventListener('click', function () {
      fx[prop] = !fx[prop];
      b.setAttribute('aria-checked', fx[prop] ? 'true' : 'false');
      save(storeKey, fx[prop]);
      apply();
    });
  }

  function init() {
    wire('fxAnimSw', 'anim', K_ANIM);
    wire('fxEffSw',  'eff',  K_EFF);
    var note = document.getElementById('fxRmNote');
    if (note) note.hidden = !reduce;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
</script>
"""

out = HTML.replace("__DATA__", blob)
# Pure-ASCII output: json.dumps already escapes the data blob, and this converts the
# template's punctuation to entities, so no charset assumption can corrupt the page.
out = out.encode("ascii", "xmlcharrefreplace").decode("ascii")
out = out.replace("__DOWNLOADS__", json.dumps(DOWNLOADS, separators=(",", ":")))
out = out.replace("__RELEASES__", json.dumps(RELEASES_URL))
out = out.replace("__ICONB64__", ICON_B64).replace("__REPO__", REPO)
for _k in ("zip", "dmg", "pkg", "exe"):
    out = out.replace(f"__{_k.upper()}MB__", DOWNLOADS[_k]["mb"])
dest = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else HERE / "isaac-site.html")
dest.write_text(out)
print(f"wrote {dest} ({len(out)/1024:.0f} KB)")
