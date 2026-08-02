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
pub fn serve(state: Arc<Mutex<State>>, data: Arc<Data>, running: Arc<AtomicBool>) -> u16 {
    let listener = match [8731u16, 8732, 8733, 0]
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
            // A thread per connection. The only client is one browser tab polling a
            // few times a second, so a pool would be machinery for no one.
            std::thread::spawn(move || {
                let _ = handle(stream, state, data, running, cache);
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
) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request = String::new();
    reader.read_line(&mut request)?;
    // Drain the headers so the client does not see a reset before it finishes writing.
    let mut line = String::new();
    while reader.read_line(&mut line)? > 0 && line.trim() != "" {
        line.clear();
    }

    let path = request.split_whitespace().nth(1).unwrap_or("/");
    let (status, ctype, body) = match path {
        "/api/state" => (
            "200 OK",
            "application/json; charset=utf-8",
            cached_state(&state, &data, &running, &cache),
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

#[cfg(test)]
mod tests {
    use super::*;

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
