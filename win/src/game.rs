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
#[cfg(windows)]
const PROCESS: &str = "isaac-ng.exe";

pub fn watch(running: Arc<AtomicBool>) {
    std::thread::spawn(move || loop {
        running.store(is_running(), Ordering::Relaxed);
        // Well under human reaction time for "I just launched it", and three seconds
        // between process spawns is not something anyone can measure.
        std::thread::sleep(Duration::from_secs(3));
    });
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
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_lowercase().contains(PROCESS),
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

#[cfg(not(any(windows, target_os = "macos")))]
fn is_running() -> bool {
    true
}
