//! `log.txt` line -> event, ported from Sources/IsaacCore/LogParser.swift.
//!
//! Hand-written matchers rather than a regex crate: the grammar is a handful of fixed
//! prefixes, and keeping the dependency count at zero is what makes the Windows
//! cross-build dependable. Each function below carries the Swift pattern it replaces
//! so the two can be diffed by eye.

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    ItemAdded { id: i64, name: String },
    ItemRemoved { id: i64 },
    Seed(String),
    PlayerInit { subtype: i64 },
    LevelInit { stage: i64, stage_type: i64 },
    Room { kind: i64, variant: i64 },
    Curse(String),
    Pedestal,
    Shutdown,
}

/// `Adding collectible 46 (Lucky Foot)` on AB+. Repentance appends
/// ` to Player 0 (Isaac)`, tolerated so a future Repentance swap does not silently
/// mangle every item name.
/// Swift: ^Adding collectible (\d+) \((.+?)\)(?: to Player \d+.*)?$
fn item_added(line: &str) -> Option<Event> {
    let rest = line.strip_prefix("Adding collectible ")?;
    let (id_text, rest) = rest.split_once(' ')?;
    let id: i64 = id_text.parse().ok()?;
    let rest = rest.strip_prefix('(')?;
    // Item names CAN contain brackets: "Odd Mushroom (Thin)" and "Odd Mushroom
    // (Large)" are both real Afterbirth+ collectibles. Stopping at the first ')'
    // therefore dropped those two lines entirely and silently -- their stat changes
    // were never applied, and nothing on screen said so. The Swift regex gets this
    // right by anchoring to the end of the line and backtracking; the equivalent
    // here is to remove the optional Repentance suffix first, then take everything
    // up to the FINAL bracket.
    let body = match rest.find(") to Player ") {
        Some(i) => &rest[..i],
        None => rest.strip_suffix(')')?,
    };
    Some(Event::ItemAdded { id, name: body.to_string() })
}

/// Swift: ^Removing collectible (\d+)
fn item_removed(line: &str) -> Option<Event> {
    let rest = line.strip_prefix("Removing collectible ")?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok().map(|id| Event::ItemRemoved { id })
}

/// Swift: ^RNG Start Seed: ([A-Z0-9 ]+) \(\d+\)
fn seed(line: &str) -> Option<Event> {
    let rest = line.strip_prefix("RNG Start Seed: ")?;
    let open = rest.find('(')?;
    let s = rest[..open].trim();
    if s.is_empty() || !s.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == ' ') {
        return None;
    }
    Some(Event::Seed(s.to_string()))
}

/// Swift: ^Initialized player with Variant \d+ and Subtype (\d+)
fn player_init(line: &str) -> Option<Event> {
    let rest = line.strip_prefix("Initialized player with Variant ")?;
    let rest = rest.split_once(" and Subtype ")?.1;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok().map(|subtype| Event::PlayerInit { subtype })
}

/// Swift: ^Level::Init m_Stage (\d+), m_StageType (\d+)
fn level_init(line: &str) -> Option<Event> {
    let rest = line.strip_prefix("Level::Init m_Stage ")?;
    let (a, rest) = rest.split_once(',')?;
    let rest = rest.trim_start().strip_prefix("m_StageType ")?;
    let b: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    Some(Event::LevelInit { stage: a.trim().parse().ok()?, stage_type: b.parse().ok()? })
}

/// Swift: ^Room (\d+)\.(\d+)\(
/// The first number is the RoomType: 4=Treasure, 14=Devil, 15=Angel, 2=Shop.
fn room(line: &str) -> Option<Event> {
    let rest = line.strip_prefix("Room ")?;
    let (kind, rest) = rest.split_once('.')?;
    let open = rest.find('(')?;
    Some(Event::Room {
        kind: kind.parse().ok()?,
        variant: rest[..open].parse().ok()?,
    })
}

/// Swift: ^(Curse of [A-Za-z' ]+)!?$
/// The "!" is optional: the real AB+ log writes "Curse of Blind" with no punctuation
/// for most curses, and only some carry the exclamation mark.
fn curse(line: &str) -> Option<Event> {
    if !line.starts_with("Curse of ") {
        return None;
    }
    let body = line.strip_suffix('!').unwrap_or(line);
    if body["Curse of ".len()..]
        .chars()
        .all(|c| c.is_ascii_alphabetic() || c == '\'' || c == ' ')
    {
        Some(Event::Curse(body.to_string()))
    } else {
        None
    }
}

/// Type 5 / Variant 100 is a collectible pedestal, Variant 150 a shop slot. The item
/// id is NOT logged -- only the position -- which is why identifying it needs the
/// screen, and why the Windows build reports the count rather than the item.
fn pedestal(line: &str) -> Option<Event> {
    if line.starts_with("Spawn Entity with Type(5), Variant(100)")
        || line.starts_with("Spawn Entity with Type(5), Variant(150)")
    {
        Some(Event::Pedestal)
    } else {
        None
    }
}

pub fn parse(raw: &str) -> Option<Event> {
    // Trimming also strips a stray trailing '\r', so a CRLF log does not leave
    // carriage returns glued to item names. On Windows every line is CRLF.
    let mut line = raw.trim();
    for prefix in ["[INFO] - ", "[ASSERT] - ", "[WARN] - "] {
        if let Some(rest) = line.strip_prefix(prefix) {
            line = rest;
        }
    }
    if line.is_empty() {
        return None;
    }
    if line.starts_with("Isaac has shut down") {
        return Some(Event::Shutdown);
    }
    item_added(line)
        .or_else(|| item_removed(line))
        .or_else(|| seed(line))
        .or_else(|| player_init(line))
        .or_else(|| level_init(line))
        .or_else(|| room(line))
        .or_else(|| curse(line))
        .or_else(|| pedestal(line))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_lines_the_game_actually_writes() {
        assert_eq!(
            parse("Adding collectible 46 (Lucky Foot)"),
            Some(Event::ItemAdded { id: 46, name: "Lucky Foot".into() })
        );
        // Repentance suffix tolerated, name unmangled.
        assert_eq!(
            parse("Adding collectible 149 (Ipecac) to Player 0 (Isaac)"),
            Some(Event::ItemAdded { id: 149, name: "Ipecac".into() })
        );
        // The log ships with a level prefix in some builds.
        assert_eq!(
            parse("[INFO] - Adding collectible 1 (The Sad Onion)"),
            Some(Event::ItemAdded { id: 1, name: "The Sad Onion".into() })
        );
        assert_eq!(parse("Removing collectible 46 (Lucky Foot)"), Some(Event::ItemRemoved { id: 46 }));
        assert_eq!(parse("RNG Start Seed: 8LV7 AYCP (123456)"), Some(Event::Seed("8LV7 AYCP".into())));
        assert_eq!(
            parse("Initialized player with Variant 0 and Subtype 2 (Cain)"),
            Some(Event::PlayerInit { subtype: 2 })
        );
        assert_eq!(
            parse("Level::Init m_Stage 4, m_StageType 1"),
            Some(Event::LevelInit { stage: 4, stage_type: 1 })
        );
        assert_eq!(parse("Room 14.26(Devil Room)"), Some(Event::Room { kind: 14, variant: 26 }));
        assert_eq!(parse("Curse of Blind"), Some(Event::Curse("Curse of Blind".into())));
        assert_eq!(parse("Curse of the Maze!"), Some(Event::Curse("Curse of the Maze".into())));
        assert_eq!(
            parse("Spawn Entity with Type(5), Variant(100), Pos(320.00,280.00)"),
            Some(Event::Pedestal)
        );
        assert_eq!(parse("Isaac has shut down"), Some(Event::Shutdown));
    }

    /// Two real AB+ collectibles have brackets in their names. Parsing that stopped
    /// at the first ')' dropped both, so a run with one of them silently reported
    /// the wrong damage for the rest of the game.
    #[test]
    fn item_names_may_contain_brackets() {
        assert_eq!(
            parse("Adding collectible 121 (Odd Mushroom (Thin))"),
            Some(Event::ItemAdded { id: 121, name: "Odd Mushroom (Thin)".into() })
        );
        assert_eq!(
            parse("Adding collectible 120 (Odd Mushroom (Large))"),
            Some(Event::ItemAdded { id: 120, name: "Odd Mushroom (Large)".into() })
        );
        // ...and with the Repentance suffix on top of the brackets.
        assert_eq!(
            parse("Adding collectible 121 (Odd Mushroom (Thin)) to Player 0 (Isaac)"),
            Some(Event::ItemAdded { id: 121, name: "Odd Mushroom (Thin)".into() })
        );
    }

    #[test]
    fn a_crlf_log_does_not_glue_carriage_returns_to_names() {
        assert_eq!(
            parse("Adding collectible 46 (Lucky Foot)\r"),
            Some(Event::ItemAdded { id: 46, name: "Lucky Foot".into() })
        );
    }

    #[test]
    fn ignores_everything_else() {
        assert_eq!(parse(""), None);
        assert_eq!(parse("   "), None);
        assert_eq!(parse("Loading shaders"), None);
        assert_eq!(parse("Adding collectible not-a-number (x)"), None);
    }
}
