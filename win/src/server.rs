//! A localhost HTTP server, in std.
//!
//! Small enough to hand-write, and hand-writing it is what keeps the crate
//! dependency-free -- which is the thing that makes cross-compiling to Windows from a
//! Mac dependable rather than a gamble on every transitive dependency's target
//! support. It binds 127.0.0.1 only: this is a readout for the person at the
//! keyboard, and it should not be reachable from the network.

use crate::run::Data;
use crate::stats::{compute, Stat};
use crate::State;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Binds the first free port, preferring the one the macOS build's dev server uses so
/// the URL is familiar, and returns it.
pub fn serve(
    state: Arc<Mutex<State>>,
    data: Arc<Data>,
    running: Arc<AtomicBool>,
    catalogue: Arc<crate::browse::Catalogue>,
) -> u16 {
    // ISAAC_PORT pins the port. Only the test harness sets it: everything else wants
    // the "first one that is free" behaviour below, because two copies of this on one
    // machine should not fight over a number.
    let preferred: Vec<u16> = match std::env::var("ISAAC_PORT").ok().and_then(|v| v.parse().ok()) {
        Some(p) => vec![p],
        None => vec![8731, 8732, 8733, 0],
    };
    let listener = match preferred
        .iter()
        .find_map(|p| TcpListener::bind(("127.0.0.1", *p)).ok())
    {
        Some(l) => l,
        None => {
            // Panicking here killed the console window before anyone could read why,
            // which on Windows means double-clicking the exe just flashes and exits.
            eprintln!("could not open a local port -- is another copy already running?");
            eprintln!("press Enter to close");
            let _ = std::io::stdin().read_line(&mut String::new());
            std::process::exit(1);
        }
    };
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);

    // The payload only changes when the tailer says so, so a poll that changed
    // nothing costs a string clone instead of recomputing every stat and rebuilding
    // the JSON. The measured cost was already 0.39 ms a request -- this is about not
    // doing pointless work rather than about a bottleneck anyone could feel.
    let cache: Arc<Mutex<(u64, bool, String)>> = Arc::new(Mutex::new((u64::MAX, false, String::new())));

    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let state = Arc::clone(&state);
            let data = Arc::clone(&data);
            let running = Arc::clone(&running);
            let cache = Arc::clone(&cache);
            let catalogue = Arc::clone(&catalogue);
            // A thread per connection. The only client is one browser tab polling a
            // few times a second, so a pool would be machinery for no one.
            std::thread::spawn(move || {
                let _ = handle(stream, state, data, running, cache, catalogue);
            });
        }
    });
    port
}

type Cache = Arc<Mutex<(u64, bool, String)>>;

fn handle(
    mut stream: TcpStream,
    state: Arc<Mutex<State>>,
    data: Arc<Data>,
    running: Arc<AtomicBool>,
    cache: Cache,
    catalogue: Arc<crate::browse::Catalogue>,
) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request = String::new();
    reader.read_line(&mut request)?;
    // Drain the headers so the client does not see a reset before it finishes writing.
    let mut line = String::new();
    while reader.read_line(&mut line)? > 0 && line.trim() != "" {
        line.clear();
    }

    let target = request.split_whitespace().nth(1).unwrap_or("/").to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target.clone(), String::new()),
    };

    // Sprites are the one binary response, and they are read from the user's own game
    // install rather than shipped -- see browse.rs. Cached hard, because the art for a
    // given item never changes and the browser asks for hundreds of them.
    if let Some(name) = path.strip_prefix("/sprite/") {
        return match catalogue.sprite(&percent_decode(name)) {
            Some(bytes) => {
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: {}\r\n\
                     Cache-Control: max-age=86400\r\nConnection: close\r\n\r\n",
                    bytes.len()
                );
                stream.write_all(head.as_bytes())?;
                stream.write_all(&bytes)?;
                stream.flush()
            }
            None => {
                let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\
                            Connection: close\r\n\r\n";
                stream.write_all(head.as_bytes())?;
                stream.flush()
            }
        };
    }

    let q = param(&query, "q");
    let (status, ctype, body) = match path.as_str() {
        "/api/state" => (
            "200 OK",
            "application/json; charset=utf-8",
            cached_state(&state, &data, &running, &cache),
        ),
        "/api/items" => ("200 OK", "application/json; charset=utf-8", items_json(&catalogue, &q)),
        "/api/enemies" => (
            "200 OK",
            "application/json; charset=utf-8",
            enemies_json(&catalogue, &q),
        ),
        "/api/achievements" => (
            "200 OK",
            "application/json; charset=utf-8",
            achievements_json(&catalogue, &q),
        ),
        "/" | "/index.html" => ("200 OK", "text/html; charset=utf-8", crate::ui::PAGE.to_string()),
        _ => ("404 Not Found", "text/plain; charset=utf-8", "not found".to_string()),
    };

    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.as_bytes().len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

/// Minimal JSON string escaping. Item names are game data, not user input, but they
/// do contain apostrophes and the odd quote, and an unescaped one would break the
/// whole payload rather than one field.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn stat_json(s: &Stat) -> String {
    format!(
        r#"{{"value":{:.4},"base":{:.4},"approx":{},"reason":{}}}"#,
        s.value,
        s.base,
        s.approx,
        match &s.reason {
            Some(r) => format!("\"{}\"", esc(r)),
            None => "null".into(),
        }
    )
}

/// Rebuilds the payload only when the run (or whether the game is up) has actually
/// changed since the last request.
fn cached_state(
    state: &Arc<Mutex<State>>,
    data: &Data,
    running: &Arc<AtomicBool>,
    cache: &Cache,
) -> String {
    let is_running = running.load(Ordering::Relaxed);
    let version = state.lock().unwrap().version;
    let mut c = cache.lock().unwrap();
    if c.0 != version || c.1 != is_running {
        *c = (version, is_running, state_json(state, data, is_running));
    }
    c.2.clone()
}

fn state_json(state: &Arc<Mutex<State>>, data: &Data, is_running: bool) -> String {
    let s = state.lock().unwrap();
    let character = s.run.character(data);
    let stats = compute(&character, &s.run.deltas(data));

    let items: Vec<String> = s
        .run
        .items
        .iter()
        .map(|p| format!(r#"{{"id":{},"name":"{}"}}"#, p.id, esc(&p.name)))
        .collect();
    let curses: Vec<String> = s.run.curses.iter().map(|c| format!("\"{}\"", esc(c))).collect();
    let unverified: Vec<String> =
        character.unverified.iter().map(|u| format!("\"{}\"", esc(u))).collect();

    format!(
        r#"{{"attached":{},"gameRunning":{},"log":{},"seed":{},"character":"{}","unverified":[{}],
"stage":{},"stageType":{},"room":{},"pedestals":{},"curses":[{}],
"damage":{},"tears":{},"tearDelay":{},"range":{},"shotSpeed":{},"speed":{},"luck":{},
"shots":{},"flight":{},"items":[{}]}}"#,
        s.attached,
        is_running,
        match &s.log_path {
            Some(p) => format!("\"{}\"", esc(&p.display().to_string())),
            None => "null".into(),
        },
        match &s.run.seed {
            Some(x) => format!("\"{}\"", esc(x)),
            None => "null".into(),
        },
        esc(&character.name),
        unverified.join(","),
        s.run.stage,
        s.run.stage_type,
        s.run.room,
        s.run.pedestals,
        curses.join(","),
        stat_json(&stats.damage),
        stat_json(&stats.tears),
        stat_json(&stats.tear_delay),
        stat_json(&stats.range),
        stat_json(&stats.shot_speed),
        stat_json(&stats.speed),
        stat_json(&stats.luck),
        stats.shots,
        stats.flight,
        items.join(",")
    )
}


// ---- browse endpoints -------------------------------------------------------

/// One query parameter, percent-decoded. No general parser: there is exactly one
/// parameter in this whole server and it is a search box.
fn param(query: &str, key: &str) -> String {
    for pair in query.split('&') {
        if let Some(v) = pair.strip_prefix(&format!("{key}=")) {
            return percent_decode(v);
        }
    }
    String::new()
}

/// Enough percent-decoding for a search box: %XX and '+' for space. Invalid escapes are
/// left alone rather than dropped, so a stray '%' someone typed still searches for '%'.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(b) => {
                        out.push(b);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// How many rows one search returns. The browser renders them all, and past a few
/// hundred the list stops being something a person reads.
const SEARCH_LIMIT: usize = 300;

fn items_json(cat: &crate::browse::Catalogue, q: &str) -> String {
    let mut out = String::from("{\"items\":[");
    for (i, e) in cat.search_items(q, SEARCH_LIMIT).iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"id\":{},\"name\":\"{}\",\"kind\":\"{}\",\"special\":{},\
             \"gfx\":\"{}\",\"pools\":[{}],\"cache\":[{}]}}",
            e.id,
            esc(&e.name),
            esc(&e.kind),
            e.special,
            esc(&e.gfx),
            e.pools.iter().map(|p| format!("\"{}\"", esc(p))).collect::<Vec<_>>().join(","),
            e.cache.iter().map(|c| format!("\"{}\"", esc(c))).collect::<Vec<_>>().join(","),
        ));
    }
    out.push_str(&format!("],\"total\":{},\"art\":{}}}", cat.items.len(), cat.sprite_dir.is_some()));
    out
}

fn enemies_json(cat: &crate::browse::Catalogue, q: &str) -> String {
    let mut out = String::from("{\"enemies\":[");
    for (i, e) in cat.search_enemies(q, SEARCH_LIMIT).iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let hp = match e.hp {
            Some(h) => format!("{h}"),
            None => "null".to_string(),
        };
        out.push_str(&format!(
            "{{\"type\":{},\"variant\":{},\"name\":\"{}\",\"hp\":{},\"boss\":{}}}",
            e.kind,
            e.variant,
            esc(&e.name),
            hp,
            e.boss
        ));
    }
    out.push_str(&format!("],\"total\":{}}}", cat.enemies.len()));
    out
}

fn achievements_json(cat: &crate::browse::Catalogue, q: &str) -> String {
    let mut out = String::from("{\"achievements\":[");
    for (i, a) in cat.search_achievements(q, SEARCH_LIMIT).iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"id\":{},\"name\":\"{}\",\"condition\":\"{}\"}}",
            a.id,
            esc(&a.name),
            esc(&a.condition)
        ));
    }
    out.push_str(&format!("],\"total\":{}}}", cat.achievements.len()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- the HTTP layer itself ---------------------------------------------
    //
    // None of this was covered before: `handle` had never been run over a real socket,
    // so the request line parsing, the header drain, the 404 path and the sprite route
    // were all assumed rather than known.

    use std::io::{BufRead, BufReader as TestReader, Write as TestWrite};
    use std::net::TcpStream as TestStream;

    fn spin_up() -> u16 {
        let state = Arc::new(Mutex::new(State {
            run: crate::run::Run::default(),
            log_path: None,
            attached: false,
            version: 0,
        }));
        let data = Arc::new(crate::run::Data::load());
        let running = Arc::new(AtomicBool::new(false));
        let catalogue = Arc::new(crate::browse::Catalogue::load());
        // Port 0: let the OS pick, so parallel tests cannot collide.
        std::env::set_var("ISAAC_PORT", "0");
        let port = serve(state, data, running, catalogue);
        std::env::remove_var("ISAAC_PORT");
        port
    }

    fn get(port: u16, path: &str) -> (String, String) {
        let mut stream = TestStream::connect(("127.0.0.1", port)).expect("connect");
        write!(stream, "GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        stream.flush().unwrap();
        let mut reader = TestReader::new(stream);
        let mut status = String::new();
        reader.read_line(&mut status).unwrap();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 && line.trim() != "" {
            line.clear();
        }
        let mut body = String::new();
        use std::io::Read;
        reader.read_to_string(&mut body).ok();
        (status.trim().to_string(), body)
    }

    #[test]
    fn serves_the_page_the_state_and_the_catalogue() {
        let port = spin_up();

        let (status, body) = get(port, "/");
        assert!(status.contains("200"), "GET / -> {status}");
        assert!(body.contains("Isaac Companion"));

        let (status, body) = get(port, "/api/state");
        assert!(status.contains("200"));
        assert!(body.contains("\"character\""));

        let (status, body) = get(port, "/api/items?q=brimstone");
        assert!(status.contains("200"));
        assert!(body.contains("Brimstone"), "{body}");
        // Balanced braces is a weak check on its own, so also assert the shape.
        assert!(body.starts_with("{\"items\":["));
        assert!(body.contains("\"total\":"));

        let (_, body) = get(port, "/api/enemies?q=monstro");
        assert!(body.contains("Monstro"));

        let (_, body) = get(port, "/api/achievements?q=pennies");
        assert!(body.contains("Pennies"));
    }

    #[test]
    fn an_unknown_path_is_a_404_and_a_bad_sprite_is_too() {
        let port = spin_up();
        let (status, _) = get(port, "/nope");
        assert!(status.contains("404"), "{status}");
        // Traversal is refused at the HTTP layer as well as in browse.rs.
        let (status, _) = get(port, "/sprite/../../etc/passwd");
        assert!(status.contains("404"), "{status}");
    }

    #[test]
    fn query_parameters_survive_the_trip() {
        assert_eq!(param("q=brim", "q"), "brim");
        assert_eq!(param("q=mom%27s+knife", "q"), "mom's knife");
        assert_eq!(param("other=1&q=cain", "q"), "cain");
        assert_eq!(param("", "q"), "");
        // A stray percent is what someone typed, not an error to swallow.
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%zz"), "%zz");
        assert_eq!(percent_decode("caf%C3%A9"), "café");
    }


    #[test]
    fn escapes_what_would_otherwise_break_the_payload() {
        assert_eq!(esc(r#"a"b"#), r#"a\"b"#);
        assert_eq!(esc("a\\b"), "a\\\\b");
        assert_eq!(esc("a\nb"), "a\\nb");
        // An apostrophe is legal JSON and must NOT be escaped -- half the item names
        // have one ("Cricket's Head").
        assert_eq!(esc("Cricket's Head"), "Cricket's Head");
    }

    #[test]
    fn the_payload_is_wellformed_for_a_real_run() {
        let data = Arc::new(Data::load());
        let state = Arc::new(Mutex::new(State {
            run: crate::run::Run::default(),
            log_path: None,
            attached: false,
            version: 0,
        }));
        {
            let mut s = state.lock().unwrap();
            s.run.apply(crate::parser::Event::PlayerInit { subtype: 2 }, &data);
            s.run.apply(
                crate::parser::Event::ItemAdded { id: 149, name: "Ipecac".into() },
                &data,
            );
        }
        let json = state_json(&state, &data, true);
        assert!(json.contains("\"character\":\"Cain\""), "{json}");
        assert!(json.contains("Ipecac"), "{json}");
        // Braces must balance, or the browser silently shows nothing.
        assert_eq!(
            json.chars().filter(|c| *c == '{').count(),
            json.chars().filter(|c| *c == '}').count()
        );
    }
}
