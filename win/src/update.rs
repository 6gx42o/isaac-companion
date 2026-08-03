//! Updating the Windows build from GitHub Releases.
//!
//! Same two rules as the Mac updater: nothing installs that cannot be verified against
//! the checksum published with the release, and nothing swaps the binary while the game
//! is running.
//!
//! **How this talks to the network without a dependency.** std has no HTTP client, let
//! alone TLS, and adding one would end the zero-crate property that makes cross-compiling
//! this from a Mac reliable. So it shells out to tools Windows already ships:
//! `curl.exe` (in System32 since Windows 10 1803) for fetching over the OS's own TLS
//! stack, and `certutil` for the SHA-256. Both are Microsoft's, both are present on any
//! machine this runs on, and neither adds a byte to the download.
//!
//! **Why the file shuffle.** A running .exe cannot be overwritten on Windows -- but it
//! CAN be renamed. So the live binary is moved aside, the new one takes its name, and the
//! old one is deleted on the next start.

use std::path::Path;
use std::process::Command;

const REPO: &str = "6gx42o/isaac-companion";

pub struct Available {
    pub tag: String,
    pub exe_url: String,
    pub sums_url: String,
    pub exe_name: String,
}

/// Compares dotted versions numerically. "0.10.0" is newer than "0.9.0", which is the
/// case a string comparison gets wrong.
fn newer(candidate: &str, current: &str) -> bool {
    let parse = |v: &str| -> Vec<u64> {
        v.trim_start_matches('v')
            .split('-')
            .next()
            .unwrap_or("")
            .split('.')
            .map(|p| p.parse().unwrap_or(0))
            .collect()
    };
    let (a, b) = (parse(candidate), parse(current));
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

/// Pulls one string field out of a flat JSON object. Deliberately not a JSON parser:
/// this reads three fields from a payload GitHub controls, and a parser would be more
/// code than the feature.
fn field<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\":\"");
    let start = json.find(&needle)? + needle.len();
    let rest = &json[start..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn fetch(url: &str) -> Option<String> {
    let out = Command::new("curl")
        .args(["-sL", "--max-time", "30", "-A", "IsaacCompanion", url])
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn download(url: &str, to: &Path) -> bool {
    Command::new("curl")
        .args(["-sL", "--max-time", "300", "-A", "IsaacCompanion", "-o"])
        .arg(to)
        .arg(url)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
        && to.is_file()
}

/// SHA-256 via certutil, whose output is a three-line block with the hash in the middle.
fn sha256(path: &Path) -> Option<String> {
    let out = Command::new("certutil")
        .arg("-hashfile")
        .arg(path)
        .arg("SHA256")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines()
        .map(str::trim)
        .find(|l| l.len() == 64 && l.chars().all(|c| c.is_ascii_hexdigit()))
        .map(|l| l.to_lowercase())
}

/// Looks a filename up in a `shasum`-style manifest.
pub fn expected_hash(manifest: &str, file: &str) -> Option<String> {
    for line in manifest.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 2 {
            continue;
        }
        let name = parts[parts.len() - 1]
            .trim_start_matches('*')
            .trim_start_matches("./");
        if name == file {
            return Some(parts[0].to_lowercase());
        }
    }
    None
}

/// Asks GitHub whether anything newer exists. None means "up to date, or we could not
/// tell" -- an update check must never be the reason the app stops working.
pub fn check(current: &str) -> Option<Available> {
    let json = fetch(&format!("https://api.github.com/repos/{REPO}/releases/latest"))?;
    let tag = field(&json, "tag_name")?.to_string();
    let version = tag.trim_start_matches('v').to_string();
    if !newer(&version, current) {
        return None;
    }
    // The .exe asset and the checksum manifest, both from the same release.
    let mut exe_url = None;
    let mut sums_url = None;
    let mut exe_name = String::new();
    for chunk in json.split("\"browser_download_url\":\"").skip(1) {
        let url = chunk.split('"').next().unwrap_or("");
        let name = url.rsplit('/').next().unwrap_or("");
        if name.ends_with("-windows-x64.exe") {
            exe_name = name.to_string();
            exe_url = Some(url.to_string());
        } else if name == "SHA256SUMS" {
            sums_url = Some(url.to_string());
        }
    }
    Some(Available {
        tag,
        exe_url: exe_url?,
        sums_url: sums_url?,
        exe_name,
    })
}

/// Downloads, verifies, and swaps. Returns Ok(()) when the new binary is in place and the
/// caller should restart.
pub fn install(update: &Available) -> Result<(), String> {
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = current.parent().ok_or("no parent directory")?.to_path_buf();
    let staged = dir.join("isaac-companion.new.exe");

    let manifest = fetch(&update.sums_url)
        .ok_or("could not fetch SHA256SUMS -- refusing to install unverified")?;
    let expected = expected_hash(&manifest, &update.exe_name)
        .ok_or_else(|| format!("{} is not listed in SHA256SUMS", update.exe_name))?;

    if !download(&update.exe_url, &staged) {
        return Err("download failed".into());
    }
    let got = sha256(&staged).ok_or("could not hash the download")?;
    if got != expected {
        let _ = std::fs::remove_file(&staged);
        return Err(format!(
            "the download does not match its published checksum (expected {}…, got {}…). \
             It was discarded.",
            &expected[..12],
            &got[..12]
        ));
    }

    // A running .exe cannot be overwritten, but it can be renamed out of the way.
    let old = dir.join("isaac-companion.old.exe");
    let _ = std::fs::remove_file(&old);
    std::fs::rename(&current, &old).map_err(|e| format!("could not move the old build: {e}"))?;
    if let Err(e) = std::fs::rename(&staged, &current) {
        // Put it back rather than leaving no executable at all.
        let _ = std::fs::rename(&old, &current);
        return Err(format!("could not put the new build in place: {e}"));
    }
    Ok(())
}

/// Deletes the previous build, if one is sitting next to us from a past update.
pub fn clean_up_after_update() {
    if let Ok(current) = std::env::current_exe() {
        if let Some(dir) = current.parent() {
            let _ = std::fs::remove_file(dir.join("isaac-companion.old.exe"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_numerically_not_as_text() {
        // The one a string compare gets wrong.
        assert!(newer("0.10.0", "0.9.0"));
        assert!(newer("1.0.0", "0.99.99"));
        assert!(newer("0.2.1", "0.2.0"));
        assert!(!newer("0.2.0", "0.2.0"), "the installed version is not an update");
        assert!(!newer("0.1.0", "0.2.0"), "never offer a downgrade");
        // Tags carry a v, the baked version does not.
        assert!(newer("v0.3.0", "0.2.0"));
        // A pre-release suffix does not make it older than its own core version.
        assert!(newer("0.3.0-beta.1", "0.2.0"));
    }

    #[test]
    fn reads_the_fields_it_needs_out_of_a_release_payload() {
        let json = r#"{"tag_name":"v0.3.0","draft":false,"body":"notes"}"#;
        assert_eq!(field(json, "tag_name"), Some("v0.3.0"));
        assert_eq!(field(json, "body"), Some("notes"));
        assert_eq!(field(json, "missing"), None);
    }

    #[test]
    fn finds_a_files_hash_in_the_manifest() {
        let manifest = "\
964ccfabb83b9219a722517f95bb1393ddf88ae4ed61166e6a2f0f0884813d07  IsaacCompanion-0.2.0-windows-x64.exe
8fe7965641a1f28fedef3e06e28697a05e4fcb2557ea8347f32a882ded37bb40  IsaacCompanion-0.2.0.zip";
        assert_eq!(
            expected_hash(manifest, "IsaacCompanion-0.2.0-windows-x64.exe").as_deref(),
            Some("964ccfabb83b9219a722517f95bb1393ddf88ae4ed61166e6a2f0f0884813d07")
        );
        // Not listed means it cannot be verified, which must read as None so the caller
        // refuses rather than installing something unchecked.
        assert_eq!(expected_hash(manifest, "something-else.exe"), None);
        assert_eq!(expected_hash("", "anything"), None);
    }

    #[test]
    fn tolerates_the_shapes_a_manifest_comes_in() {
        let h = "a".repeat(64);
        for line in [
            format!("{h}  f.exe"),
            format!("{h} f.exe"),
            format!("{h} *f.exe"),
            format!("{h}  ./f.exe"),
        ] {
            assert_eq!(expected_hash(&line, "f.exe").as_deref(), Some(h.as_str()), "{line}");
        }
    }
}
