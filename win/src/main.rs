//! Isaac Companion for Windows.
//!
//! The macOS app is AppKit end to end -- the overlay is an NSPanel, the pedestal
//! scanner is ScreenCaptureKit, the UI is a WKWebView. None of that ports. What DOES
//! port is the part that matters most: the log reader and the Afterbirth+ stat model,
//! which are pure logic and are the reason the app exists at all.
//!
//! So this is the same engine with a different front door. It tails the game's own
//! log, folds it into a run, computes the stats, and serves a readout on localhost
//! that it opens in your browser. No mod, nothing written to the game, achievements
//! untouched -- the same hard constraint the whole project is built around.
//!
//! Not here, and honestly so: the always-on-top overlay and the pedestal scanner.
//! Both are macOS window-server features with no portable equivalent.

mod browse;
mod game;
mod overlay;
mod parser;
mod run;
mod server;
mod stats;
mod ui;

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Where Afterbirth+ writes its log on Windows.
///
/// The Mac path is ~/Library/Application Support/...; on Windows the game uses the
/// Documents folder, and OneDrive's Documents redirection is common enough that both
/// are tried. A path given on the command line always wins.
/// The explicit path, if it points at a real file. Split out from `find_log` so it can
/// be tested without reaching into the process's own argv.
fn resolve_log(arg: Option<String>) -> Option<PathBuf> {
    let arg = arg?;
    let p = PathBuf::from(&arg);
    if p.is_file() {
        return Some(p);
    }
    eprintln!("note: {arg} is not a file -- looking in the usual places instead");
    None
}

fn find_log() -> Option<PathBuf> {
    // A path on the command line wins -- but only if it exists. Returning None for a
    // typo used to switch auto-detection off for the life of the process, so the app
    // sat on "no log found" next to a log it would have found on its own.
    if let Some(p) = resolve_log(std::env::args().nth(1)) {
        return Some(p);
    }
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .ok()?;
    let names = [
        "Documents/My Games/Binding of Isaac Afterbirth+/log.txt",
        "OneDrive/Documents/My Games/Binding of Isaac Afterbirth+/log.txt",
        "Documents/My Games/Binding of Isaac Repentance/log.txt",
        "Documents/My Games/Binding of Isaac Afterbirth/log.txt",
        "Documents/My Games/Binding of Isaac Rebirth/log.txt",
        // So the build can be exercised on the machine it is cross-compiled from.
        "Library/Application Support/Binding of Isaac Afterbirth+/log.txt",
    ];
    names
        .iter()
        .map(|n| Path::new(&home).join(n))
        .find(|p| p.is_file())
}

/// The mutable half. `Data` is deliberately NOT in here: it is immutable once
/// loaded, and keeping it out of the mutex is what lets the tailer hold a reference
/// to it while mutating the run -- the alternative was aliasing two fields of one
/// locked struct, which needed `unsafe` to express and would have been a real hazard
/// the first time someone added a second writer.
pub struct State {
    pub run: run::Run,
    pub log_path: Option<PathBuf>,
    pub attached: bool,
    /// Bumped whenever anything above changes, so the server can hand back a cached
    /// payload instead of recomputing the stats for a poll that changed nothing.
    pub version: u64,
}

fn main() {
    // CI hook: create the overlay window, ask Windows whether it exists, exit. It is the
    // only part of an overlay a machine can check on its own.
    #[cfg(windows)]
    if std::env::args().any(|a| a == "--overlay-selftest") {
        std::process::exit(if overlay::selftest() { 0 } else { 1 });
    }
    let data = Arc::new(run::Data::load());
    let log_path = find_log();
    let state = Arc::new(Mutex::new(State {
        run: run::Run::default(),
        log_path: log_path.clone(),
        attached: false,
        version: 0,
    }));

    // Asked of the OS, never inferred from the log -- see game.rs.
    let running = Arc::new(AtomicBool::new(false));
    game::watch(Arc::clone(&running));

    // Tailer thread.
    {
        let state = Arc::clone(&state);
        let data = Arc::clone(&data);
        std::thread::spawn(move || tail_loop(state, data));
    }

    let catalogue = Arc::new(browse::Catalogue::load());
    let port = server::serve(
        Arc::clone(&state),
        Arc::clone(&data),
        Arc::clone(&running),
        Arc::clone(&catalogue),
    );
    let url = format!("http://127.0.0.1:{port}/");
    println!("Isaac Companion  ->  {url}");
    match &log_path {
        Some(p) => println!("watching {}", p.display()),
        None => println!(
            "no log.txt found yet. Launch the game once, then restart this, \
             or pass the path as an argument."
        ),
    }
    // A CI runner has no one to show a browser to, and on a headless agent the
    // launcher can block.
    if std::env::var("ISAAC_NO_BROWSER").is_err() {
        open_browser(&url);
    }

    // The always-on-top readout. Windows only, and it owns this thread from here --
    // GetMessageW blocks, which is why the sleep loop below is in an else branch rather
    // than after it. Off by default is the wrong default for an overlay, so it is on,
    // and ISAAC_NO_OVERLAY turns it off.
    #[cfg(windows)]
    if std::env::var("ISAAC_NO_OVERLAY").is_err() {
        println!(
            "overlay: on. Isaac must be windowed or borderless-windowed -- nothing can \
             draw over exclusive fullscreen."
        );
        overlay::run(Arc::clone(&state), Arc::clone(&data), Arc::clone(&running));
        return;
    }
    // The server owns the process from here.
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}


/// Splits off whole lines, leaving any partial trailing line in `carry`.
///
/// Two things this has to get right, both of which used to be reasoned about rather than
/// tested. A read can stop mid-line, and parsing half an item name as the whole would
/// silently record the wrong item. A read can also stop in the middle of a multi-byte
/// character, so decoding each chunk on its own would replace that character with a
/// replacement char permanently -- which is why this works in bytes and defers decoding
/// until a newline has been seen.
fn take_complete_lines(carry: &mut Vec<u8>) -> Option<Vec<u8>> {
    let cut = carry.iter().rposition(|b| *b == b'\n')?;
    Some(carry.drain(..=cut).collect())
}

/// Polling rather than a filesystem watcher: the game appends constantly while you
/// play, a watcher would fire hundreds of times a second for no benefit, and polling
/// keeps this dependency-free and identical on every Windows version.
fn tail_loop(state: Arc<Mutex<State>>, data: Arc<run::Data>) {
    let mut offset: u64 = 0;
    // Bytes, not a String: a read can land in the middle of a multi-byte character,
    // and decoding each chunk on its own would replace the split character with a
    // replacement char permanently. Decoding is deferred until a whole line is in
    // hand, at which point the boundary is guaranteed to be safe.
    let mut carry: Vec<u8> = Vec::new();
    loop {
        let path = { state.lock().unwrap().log_path.clone() };
        let path = match path {
            Some(p) => p,
            None => {
                // Re-look every few seconds: the folder appears the first time the
                // game is launched, which may well be after this started.
                std::thread::sleep(Duration::from_secs(3));
                let found = find_log();
                if found.is_some() {
                    state.lock().unwrap().log_path = found;
                }
                continue;
            }
        };

        if let Ok(mut f) = std::fs::File::open(&path) {
            let len = f.metadata().map(|m| m.len()).unwrap_or(0);
            // The game rewrites log.txt on every launch. Shorter than where we were
            // reading means a new session, so start the run over rather than
            // appending a fresh run onto a stale one.
            if len < offset {
                offset = 0;
                carry.clear();
                let mut s = state.lock().unwrap();
                s.run = run::Run::default();
                s.version += 1;
            }
            if len > offset {
                if f.seek(SeekFrom::Start(offset)).is_ok() {
                    let mut buf = Vec::new();
                    if f.read_to_end(&mut buf).is_ok() {
                        offset = len;
                        carry.extend_from_slice(&buf);
                        if let Some(complete) = take_complete_lines(&mut carry) {
                            let text = String::from_utf8_lossy(&complete);
                            let mut s = state.lock().unwrap();
                            s.attached = true;
                            for line in text.lines() {
                                if let Some(ev) = parser::parse(line) {
                                    s.run.apply(ev, &data);
                                }
                            }
                            s.version += 1;
                        }
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(400));
    }
}

fn open_browser(url: &str) {
    #[cfg(windows)]
    let _ = std::process::Command::new("cmd").args(["/C", "start", "", url]).spawn();
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(url).spawn();
    #[cfg(all(unix, not(target_os = "macos")))]
    let _ = std::process::Command::new("xdg-open").arg(url).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_partial_line_is_held_back_until_its_newline_arrives() {
        // The game appends constantly, so a read landing mid-line is the normal case,
        // not an edge case. Parsing "Adding collectible 149 (Ipe" would record an item
        // that does not exist and get every stat after it wrong.
        let mut carry: Vec<u8> = b"one\ntwo\nthree-partial".to_vec();
        let complete = take_complete_lines(&mut carry).expect("two whole lines are ready");
        assert_eq!(String::from_utf8_lossy(&complete), "one\ntwo\n");
        assert_eq!(carry, b"three-partial");

        // Nothing complete yet: hold everything.
        let mut only_partial: Vec<u8> = b"still writing".to_vec();
        assert!(take_complete_lines(&mut only_partial).is_none());
        assert_eq!(only_partial, b"still writing");

        // And the rest of that line, once it lands.
        carry.extend_from_slice(b"-finished\n");
        let complete = take_complete_lines(&mut carry).unwrap();
        assert_eq!(String::from_utf8_lossy(&complete), "three-partial-finished\n");
        assert!(carry.is_empty());
    }

    #[test]
    fn a_character_split_across_two_reads_survives() {
        // Item names are ASCII, but the log is not guaranteed to be, and decoding each
        // chunk separately would turn a split character into U+FFFD forever.
        let text = "Curse of the Blind — really\n";
        let bytes = text.as_bytes();
        let split = 20; // one byte into the em dash's three
        assert!(!text.is_char_boundary(split), "pick a split that is mid-character");

        let mut carry: Vec<u8> = bytes[..split].to_vec();
        assert!(take_complete_lines(&mut carry).is_none());
        carry.extend_from_slice(&bytes[split..]);
        let complete = take_complete_lines(&mut carry).unwrap();
        assert_eq!(String::from_utf8_lossy(&complete), text);
        assert!(!String::from_utf8_lossy(&complete).contains('\u{FFFD}'));
    }

    #[test]
    fn a_named_log_wins_but_only_if_it_exists() {
        // Returning None for a typo used to switch auto-detection off for the life of
        // the process, so the app sat on "no log found" next to a log it would have
        // found on its own.
        let dir = std::env::temp_dir().join(format!("isaac-findlog-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let real = dir.join("log.txt");
        std::fs::write(&real, "hello").unwrap();

        assert_eq!(resolve_log(Some(real.to_string_lossy().into_owned())), Some(real.clone()));
        // A path that is not there falls through to auto-detection rather than sticking.
        assert_eq!(resolve_log(Some("/definitely/not/here.txt".to_string())), None);
        // A directory is not a log either.
        assert_eq!(resolve_log(Some(dir.to_string_lossy().into_owned())), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
