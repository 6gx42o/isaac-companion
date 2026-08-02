//! Folds log events into the current run, and holds the embedded item table.
//!
//! Deliberately tolerant, like the Swift reducer: the log is a diagnostic stream, not
//! an API, and anything it cannot express is left alone rather than guessed at.

use crate::parser::Event;
use crate::stats::{Character, Delta};
use std::collections::HashMap;

/// The item table and character table, baked in at build time by `bake-data.py`.
///
/// Tab-separated rather than JSON so the parser is a `split('\t')` and the binary
/// carries no JSON crate. Game data is identical on every platform, so this is the
/// same data the Mac build derives from the user's own install.
const ITEMS_TSV: &str = include_str!("items.tsv");
const CHARS_TSV: &str = include_str!("characters.tsv");

pub struct Item {
    pub id: i64,
    pub name: String,
    pub delta: Delta,
}

pub struct Data {
    pub items: HashMap<i64, Item>,
    pub characters: HashMap<i64, Character>,
}

fn num(s: &str) -> Option<f64> {
    if s.is_empty() {
        None
    } else {
        s.parse().ok()
    }
}

impl Data {
    pub fn load() -> Data {
        let mut items = HashMap::new();
        for line in ITEMS_TSV.lines().skip(1).filter(|l| !l.is_empty()) {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 13 {
                continue;
            }
            let id: i64 = match f[0].parse() {
                Ok(v) => v,
                Err(_) => continue,
            };
            items.insert(
                id,
                Item {
                    id,
                    name: f[1].to_string(),
                    delta: Delta {
                        damage: num(f[2]),
                        damage_multiplier: num(f[3]),
                        tears: num(f[4]),
                        tears_multiplier: num(f[5]),
                        tear_delay: num(f[6]),
                        range: num(f[7]),
                        speed: num(f[8]),
                        shot_speed: num(f[9]),
                        luck: num(f[10]),
                        shots: num(f[11]),
                        flight: if f[12] == "1" { Some(true) } else { None },
                    },
                },
            );
        }

        let mut characters = HashMap::new();
        for line in CHARS_TSV.lines().skip(1).filter(|l| !l.is_empty()) {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 12 {
                continue;
            }
            let id: i64 = match f[0].parse() {
                Ok(v) => v,
                Err(_) => continue,
            };
            characters.insert(
                id,
                Character {
                    id,
                    name: f[1].to_string(),
                    damage: num(f[2]).unwrap_or(3.5),
                    tears: num(f[3]).unwrap_or(0.0),
                    range: num(f[4]).unwrap_or(23.75),
                    speed: num(f[5]).unwrap_or(1.0),
                    shot_speed: num(f[6]).unwrap_or(1.0),
                    luck: num(f[7]).unwrap_or(0.0),
                    flight: f[8] == "1",
                    damage_multiplier: num(f[9]).unwrap_or(1.0),
                    fire_delay_multiplier: num(f[10]).unwrap_or(1.0),
                    unverified: if f[11].is_empty() {
                        vec![]
                    } else {
                        f[11].split(',').map(|s| s.to_string()).collect()
                    },
                },
            );
        }
        Data { items, characters }
    }
}

#[derive(Default, Clone)]
pub struct Pickup {
    pub id: i64,
    pub name: String,
}

#[derive(Default)]
pub struct Run {
    pub seed: Option<String>,
    pub player_subtype: Option<i64>,
    pub stage: i64,
    pub stage_type: i64,
    pub curses: Vec<String>,
    pub items: Vec<Pickup>,
    pub room: i64,
    pub pedestals: usize,
    pub shut_down: bool,
}

impl Run {
    pub fn apply(&mut self, event: Event, data: &Data) {
        match event {
            // A new seed is a new run. Everything resets, exactly like the Swift
            // reducer -- otherwise a second run in one session inherits the first
            // run's build and every number is wrong.
            Event::Seed(s) => {
                let same = self.seed.as_deref() == Some(s.as_str());
                if !same {
                    let subtype = self.player_subtype;
                    *self = Run::default();
                    self.player_subtype = subtype;
                }
                self.seed = Some(s);
            }
            Event::PlayerInit { subtype } => self.player_subtype = Some(subtype),
            Event::ItemAdded { id, name } => {
                // Prefer the table's name: the log's is the English one either way,
                // but the table is what the rest of the UI is keyed on.
                let name = data.items.get(&id).map(|i| i.name.clone()).unwrap_or(name);
                self.items.push(Pickup { id, name });
            }
            Event::ItemRemoved { id } => {
                if let Some(pos) = self.items.iter().rposition(|p| p.id == id) {
                    self.items.remove(pos);
                }
            }
            Event::LevelInit { stage, stage_type } => {
                self.stage = stage;
                self.stage_type = stage_type;
                // Curses are per-floor and the log re-announces them on arrival.
                self.curses.clear();
                self.pedestals = 0;
            }
            Event::Room { kind, .. } => {
                self.room = kind;
                self.pedestals = 0;
            }
            Event::Curse(c) => {
                if !self.curses.contains(&c) {
                    self.curses.push(c);
                }
            }
            Event::Pedestal => self.pedestals += 1,
            Event::Shutdown => self.shut_down = true,
        }
    }

    pub fn character<'a>(&self, data: &'a Data) -> Character {
        self.player_subtype
            .and_then(|s| data.characters.get(&s))
            .cloned()
            .unwrap_or_default()
    }

    pub fn deltas(&self, data: &Data) -> Vec<Delta> {
        self.items
            .iter()
            .filter_map(|p| data.items.get(&p.id))
            .map(|i| i.delta.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_seed_starts_a_clean_run() {
        let data = Data::load();
        let mut run = Run::default();
        run.apply(Event::Seed("AAAA BBBB".into()), &data);
        run.apply(Event::ItemAdded { id: 1, name: "The Sad Onion".into() }, &data);
        assert_eq!(run.items.len(), 1);
        // Same seed again (a replay of the log) must not wipe the build...
        run.apply(Event::Seed("AAAA BBBB".into()), &data);
        assert_eq!(run.items.len(), 1);
        // ...but a different one is a different run.
        run.apply(Event::Seed("CCCC DDDD".into()), &data);
        assert_eq!(run.items.len(), 0);
    }

    #[test]
    fn removal_takes_the_most_recent_copy() {
        let data = Data::load();
        let mut run = Run::default();
        run.apply(Event::ItemAdded { id: 1, name: "a".into() }, &data);
        run.apply(Event::ItemAdded { id: 1, name: "a".into() }, &data);
        run.apply(Event::ItemRemoved { id: 1 }, &data);
        assert_eq!(run.items.len(), 1);
    }

    #[test]
    fn the_embedded_tables_actually_loaded() {
        let data = Data::load();
        // The AB+ collectible range stops at 552; a table that lost its rows would
        // silently compute every stat as base.
        assert!(data.items.len() > 500, "items: {}", data.items.len());
        assert_eq!(data.characters.len(), 18, "characters");
        assert_eq!(data.items[&1].name, "The Sad Onion");
        assert_eq!(data.items[&1].delta.tears, Some(0.7));
        assert_eq!(data.items[&149].delta.damage, Some(40.0));
    }

    /// Cain's base luck must be 0 -- Lucky Foot is his STARTING item and the log
    /// reports it as an ordinary pickup, so a non-zero base double-counts it.
    #[test]
    fn character_bases_exclude_starting_items() {
        let data = Data::load();
        let cain = &data.characters[&2];
        assert_eq!(cain.name, "Cain");
        assert_eq!(cain.luck, 0.0, "Cain base luck must exclude Lucky Foot");
    }
}
