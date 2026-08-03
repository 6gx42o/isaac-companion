//! The item, enemy and achievement browser.
//!
//! Two kinds of data, kept apart on purpose:
//!
//! **Baked in.** Names, ids, kinds, pools, cache flags and stat numbers. These come from
//! the game's own XML by way of `bake-data.py`, and they are the same facts the Mac build
//! ships. They are compiled into the binary, so the browser works on a machine that has
//! never run the game.
//!
//! **Read from the user's own install.** Sprites are Nicalis's art and descriptions are
//! the External Item Descriptions mod's text; neither is ours to redistribute, so neither
//! is in here. The sprite route below reads PNGs out of the player's own game folder and
//! serves the bytes untouched -- the browser decodes them, which is also why this crate
//! still needs no image library and no dependencies at all.

use std::path::{Path, PathBuf};

pub struct Entry {
    pub id: i64,
    pub kind: String,
    pub name: String,
    pub pools: Vec<String>,
    pub cache: Vec<String>,
    pub special: bool,
    /// Sprite filename in the game's own art folder. Empty for things with no art.
    pub gfx: String,
    /// Lower-cased name, kept so a search does not re-allocate per keystroke per row.
    pub search: String,
}

pub struct Enemy {
    pub kind: i64,
    pub variant: i64,
    pub name: String,
    pub hp: Option<f64>,
    pub boss: bool,
    pub search: String,
}

pub struct Achievement {
    pub id: i64,
    pub name: String,
    pub condition: String,
    pub search: String,
}

pub struct Catalogue {
    pub items: Vec<Entry>,
    pub enemies: Vec<Enemy>,
    pub achievements: Vec<Achievement>,
    /// Where the game's extracted sprites are, if we found any.
    pub sprite_dir: Option<PathBuf>,
}

fn split(s: &str) -> Vec<String> {
    s.split(',').filter(|p| !p.is_empty()).map(|p| p.to_string()).collect()
}

impl Catalogue {
    pub fn load() -> Self {
        let mut items = Vec::new();
        for line in include_str!("browse.tsv").lines().skip(1) {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 6 {
                continue;
            }
            let name = f[2].to_string();
            items.push(Entry {
                id: f[0].parse().unwrap_or(0),
                kind: f[1].to_string(),
                search: name.to_lowercase(),
                name,
                pools: split(f[3]),
                cache: split(f[4]),
                special: f[5] == "1",
                gfx: f.get(6).copied().unwrap_or("").to_string(),
            });
        }

        let mut enemies = Vec::new();
        for line in include_str!("enemies.tsv").lines().skip(1) {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 5 {
                continue;
            }
            let name = f[2].to_string();
            enemies.push(Enemy {
                kind: f[0].parse().unwrap_or(0),
                variant: f[1].parse().unwrap_or(0),
                search: name.to_lowercase(),
                name,
                hp: f[3].parse().ok(),
                boss: f[4] == "1",
            });
        }

        let mut achievements = Vec::new();
        for line in include_str!("achievements.tsv").lines().skip(1) {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 3 {
                continue;
            }
            let name = f[1].to_string();
            let condition = f[2].to_string();
            achievements.push(Achievement {
                id: f[0].parse().unwrap_or(0),
                search: format!("{} {}", name.to_lowercase(), condition.to_lowercase()),
                name,
                condition,
            });
        }

        Catalogue {
            items,
            enemies,
            achievements,
            sprite_dir: find_sprites(),
        }
    }

    /// Case-insensitive substring over names. Deliberately not fuzzy: the Mac build's
    /// colour and description search leans on data this binary does not carry, and a
    /// half-clever match that quietly ranks the wrong item is worse than a plain one.
    pub fn search_items(&self, q: &str, limit: usize) -> Vec<&Entry> {
        let q = q.trim().to_lowercase();
        self.items
            .iter()
            .filter(|e| q.is_empty() || e.search.contains(&q))
            .take(limit)
            .collect()
    }

    pub fn search_enemies(&self, q: &str, limit: usize) -> Vec<&Enemy> {
        let q = q.trim().to_lowercase();
        self.enemies
            .iter()
            .filter(|e| q.is_empty() || e.search.contains(&q))
            .take(limit)
            .collect()
    }

    pub fn search_achievements(&self, q: &str, limit: usize) -> Vec<&Achievement> {
        let q = q.trim().to_lowercase();
        self.achievements
            .iter()
            .filter(|a| q.is_empty() || a.search.contains(&q))
            .take(limit)
            .collect()
    }

    /// The PNG bytes for one item's sprite, straight off the user's disk.
    ///
    /// Returns None when the game is not installed here or has not been extracted, and
    /// the browser then shows names without art -- which is the honest degradation, since
    /// shipping the art is not an option.
    pub fn sprite(&self, name: &str) -> Option<Vec<u8>> {
        let dir = self.sprite_dir.as_ref()?;
        // Never let a request escape the sprite directory: this string arrives from an
        // HTTP path, and `..` in it would otherwise read anywhere on the disk.
        if name.contains('/') || name.contains('\\') || name.contains("..") {
            return None;
        }
        let path = dir.join(name);
        if !path.is_file() {
            return None;
        }
        std::fs::read(path).ok()
    }
}

/// Where the game keeps its extracted item art.
///
/// `resources/gfx/items/collectibles` only exists after the game's own ResourceExtractor
/// has been run -- which on Windows is a native .exe sitting in the game folder, rather
/// than the Rosetta detour it needs on a Mac.
fn find_sprites() -> Option<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    for base in [
        r"C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth",
        r"C:\Program Files\Steam\steamapps\common\The Binding of Isaac Rebirth",
        r"D:\Steam\steamapps\common\The Binding of Isaac Rebirth",
        r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth",
    ] {
        roots.push(PathBuf::from(base));
    }
    // The Mac path too, so the cross-build can be exercised on the machine it is built
    // on rather than only after copying it to Windows.
    if let Ok(home) = std::env::var("HOME") {
        roots.push(
            Path::new(&home)
                .join("Library/Application Support/Steam/steamapps/common/The Binding of Isaac Rebirth"),
        );
    }
    if let Ok(explicit) = std::env::var("ISAAC_GAME_ROOT") {
        roots.insert(0, PathBuf::from(explicit));
    }

    for root in roots {
        for tail in [
            "resources/gfx/items/collectibles",
            "resources-dlc3/gfx/items/collectibles",
        ] {
            let dir = root.join(tail);
            if dir.is_dir() {
                return Some(dir);
            }
        }
    }

    // And the copy the Mac app harvests, for a machine that runs both.
    if let Ok(home) = std::env::var("HOME") {
        let dir = Path::new(&home)
            .join("Library/Application Support/IsaacCompanion/cache/harvested/sprites");
        if dir.is_dir() {
            return Some(dir);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_baked_tables_actually_loaded() {
        // Guards against a silently truncated or mis-columned TSV, which would show up
        // as an empty browser rather than as a build error.
        let cat = Catalogue::load();
        assert!(cat.items.len() > 700, "only {} items", cat.items.len());
        assert!(cat.enemies.len() > 700, "only {} enemies", cat.enemies.len());
        assert!(
            cat.achievements.len() > 390,
            "only {} achievements",
            cat.achievements.len()
        );

        let brim = cat.items.iter().find(|e| e.name == "Brimstone").expect("Brimstone");
        assert_eq!(brim.id, 118);
        assert!(brim.special, "Brimstone is one of the 12 special items");
        assert!(brim.pools.contains(&"devil".to_string()));
        assert_eq!(brim.gfx, "Collectibles_118_Brimstone.png");
    }

    #[test]
    fn achievement_names_are_the_name_not_the_sentence() {
        // achievements.xml announces `"A Bag of Pennies" has appeared in the basement`.
        // Taking everything before the first quote gave names with half a sentence
        // stuck to them.
        let cat = Catalogue::load();
        let bag = cat
            .achievements
            .iter()
            .find(|a| a.name.contains("Bag of Pennies"))
            .expect("the Bag of Pennies achievement");
        assert_eq!(bag.name, "A Bag of Pennies");
        assert!(!bag.name.contains('"'));
        assert!(!bag.name.contains("appeared"));
    }

    #[test]
    fn search_is_case_insensitive_and_bounded() {
        let cat = Catalogue::load();
        let hits = cat.search_items("BRIMSTONE", 50);
        assert!(hits.iter().any(|e| e.name == "Brimstone"));
        // Empty query lists everything, up to the limit.
        assert_eq!(cat.search_items("", 5).len(), 5);
        assert!(cat.search_items("zzzznotanitem", 50).is_empty());

        assert!(cat.search_enemies("monstro", 50).iter().any(|e| e.name == "Monstro"));
        assert!(cat
            .search_achievements("pennies", 50)
            .iter()
            .any(|a| a.condition.contains("pennies") || a.name.contains("Pennies")));
    }

    #[test]
    fn a_sprite_request_cannot_escape_the_sprite_folder() {
        // The name arrives from an HTTP path. Without this a request for
        // ../../../etc/passwd would be served happily.
        let dir = std::env::temp_dir().join(format!("isaac-spr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("ok.png"), b"png-bytes").unwrap();
        let secret = dir.parent().unwrap().join("secret.txt");
        std::fs::write(&secret, b"do not serve me").unwrap();

        let cat = Catalogue {
            items: vec![],
            enemies: vec![],
            achievements: vec![],
            sprite_dir: Some(dir.clone()),
        };
        assert_eq!(cat.sprite("ok.png").as_deref(), Some(&b"png-bytes"[..]));
        assert!(cat.sprite("../secret.txt").is_none());
        assert!(cat.sprite("..\\secret.txt").is_none());
        assert!(cat.sprite("sub/ok.png").is_none());
        assert!(cat.sprite("missing.png").is_none());

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(&secret);
    }

    #[test]
    fn no_sprite_folder_means_no_art_rather_than_a_crash() {
        let cat = Catalogue {
            items: vec![],
            enemies: vec![],
            achievements: vec![],
            sprite_dir: None,
        };
        assert!(cat.sprite("anything.png").is_none());
    }
}
