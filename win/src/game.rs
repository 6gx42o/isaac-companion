//! Is the game actually running?
//!
//! The log cannot answer this, and that is the whole reason this file exists. `log.txt`
//! is only rewritten when the game LAUNCHES, and nothing is appended when it exits, so
//! a file from a session that ended yesterday reads exactly like a session in progress.
//! Without this check the readout sits there showing a seed, a floor and a full build
//! and calls it "live" while the game is not even open -- the same trap the macOS build
//! documents in GameLauncher.swift, which is why it asks the OS instead of the log.
//!
//! Asking the OS on Windows without pulling in a crate means shelling out to `tasklist`.
//! That is a process spawn, so it runs on its own thread every few seconds rather than
//! per request, and the answer is cached.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Rebirth, Afterbirth, Afterbirth+ and Repentance all ship the same executable name.
///
/// Not cfg(windows)-gated: the name of the Windows executable is a fact whatever we are
/// compiling for, and gating it meant the one piece of logic worth testing could only be
/// tested on the platform it is hardest to run tests on.
const PROCESS: &str = "isaac-ng.exe";

pub fn watch(running: Arc<AtomicBool>) {
    std::thread::spawn(move || loop {
        running.store(is_running(), Ordering::Relaxed);
        // Well under human reaction time for "I just launched it", and three seconds
        // between process spawns is not something anyone can measure.
        std::thread::sleep(Duration::from_secs(3));
    });
}


/// Whether `tasklist` output names the game.
///
/// `tasklist` does not fail when nothing matches -- it succeeds and prints
/// "INFO: No tasks are running which match the specified criteria", which contains
/// neither the process name nor anything else useful. So the executable name appearing
/// at all is the answer, and this is the bit worth pinning: reading that INFO line as a
/// match would report the game running forever.
fn tasklist_says_running(stdout: &str) -> bool {
    stdout.to_lowercase().contains(PROCESS)
}

#[cfg(windows)]
fn is_running() -> bool {
    use std::os::windows::process::CommandExt;
    // CREATE_NO_WINDOW: without it, a GUI-subsystem build of this would flash a
    // console window every three seconds forever.
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let out = std::process::Command::new("tasklist")
        .args(["/FI", &format!("IMAGENAME eq {PROCESS}"), "/NH"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    match out {
        // tasklist prints "INFO: No tasks are running which match..." when there is
        // no match, so the executable name appearing at all is the answer.
        Ok(o) => tasklist_says_running(&String::from_utf8_lossy(&o.stdout)),
        // If tasklist is missing or blocked, do not claim the game is closed -- an
        // unavailable check should degrade to "cannot tell", and the caller treats
        // that as running so the readout keeps working.
        Err(_) => true,
    }
}

/// So the Windows logic can be exercised on the machine it is cross-compiled from.
#[cfg(target_os = "macos")]
fn is_running() -> bool {
    match std::process::Command::new("pgrep")
        .args(["-f", "The Binding of Isaac"])
        .output()
    {
        Ok(o) => !o.stdout.is_empty(),
        Err(_) => true,
    }
}

/// Linux has pgrep too, so the honest answer is available rather than assumed.
#[cfg(all(unix, not(target_os = "macos")))]
fn is_running() -> bool {
    match std::process::Command::new("pgrep")
        .args(["-f", "isaac-ng"])
        .output()
    {
        Ok(o) => !o.stdout.is_empty(),
        // Same degradation as everywhere else: an unavailable check must not claim the
        // game is closed.
        Err(_) => true,
    }
}

#[cfg(not(any(windows, unix)))]
fn is_running() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tasklist_output_is_read_correctly() {
        // A real match.
        assert!(tasklist_says_running(
            "isaac-ng.exe                  12345 Console                    1    120,000 K"
        ));
        // Case: tasklist has been seen to upper-case names on some locales.
        assert!(tasklist_says_running("ISAAC-NG.EXE  99 Console 1 1 K"));
        // The no-match case, which succeeds rather than failing and must not read as a
        // match.
        assert!(!tasklist_says_running(
            "INFO: No tasks are running which match the specified criteria."
        ));
        assert!(!tasklist_says_running(""));
        // Some other program is not the game.
        assert!(!tasklist_says_running("chrome.exe  42 Console 1 1 K"));
    }

    #[test]
    fn the_process_name_is_the_one_the_game_actually_uses() {
        // Lower-cased, because the comparison lower-cases the haystack. A capital here
        // would make every check return false and the readout would say "game closed"
        // for the whole session.
        assert_eq!(PROCESS, PROCESS.to_lowercase());
        assert!(PROCESS.contains("isaac"));
    }
}
