//! The Afterbirth+ stat model, ported from Sources/IsaacCore/StatEngine.swift.
//!
//! Ported line for line rather than reimplemented, because the numbers are the whole
//! point of the app and "close enough" is wrong in a way nobody would notice until
//! they trusted a damage figure that was not real. The fixtures in `tests` below are
//! the same ones the Swift engine is validated against, so a divergence between the
//! two builds fails here rather than on someone's screen.
//!
//! REP: Repentance removed the tear-delay floor and changed Range from tear-height to
//! tile-based. Neither applies to Afterbirth+.

pub const BASE_TEAR_DELAY: f64 = 16.0;
pub const TEAR_CURVE_SLOPE: f64 = 6.0;
pub const TEAR_CURVE_SCALE: f64 = 1.3;
pub const DAMAGE_CURVE_SCALE: f64 = 1.2;
/// Tear-ups alone cannot push delay below this; direct modifiers can.
pub const MIN_DELAY_FROM_STATS: f64 = 5.0;
pub const MIN_DELAY_ABSOLUTE: f64 = 1.0;
pub const MAX_TEARS_PER_SECOND: f64 = 15.0;

/// One item's contribution. Every field is optional in the data, so absent and zero
/// stay distinguishable -- a x1.0 multiplier is not the same as no multiplier when
/// the count of multipliers decides whether the answer is flagged approximate.
#[derive(Clone, Debug, Default)]
pub struct Delta {
    pub damage: Option<f64>,
    pub damage_multiplier: Option<f64>,
    pub tears: Option<f64>,
    pub tears_multiplier: Option<f64>,
    pub tear_delay: Option<f64>,
    pub range: Option<f64>,
    pub speed: Option<f64>,
    pub shot_speed: Option<f64>,
    pub luck: Option<f64>,
    pub shots: Option<f64>,
    pub flight: Option<bool>,
}

#[derive(Clone, Debug)]
pub struct Character {
    pub id: i64,
    pub name: String,
    pub damage: f64,
    pub tears: f64,
    pub range: f64,
    pub speed: f64,
    pub shot_speed: f64,
    pub luck: f64,
    pub flight: bool,
    pub damage_multiplier: f64,
    pub fire_delay_multiplier: f64,
    pub unverified: Vec<String>,
}

impl Default for Character {
    /// Isaac. Used when the log has not said who is playing yet.
    fn default() -> Self {
        Character {
            id: 0,
            name: "Isaac".into(),
            damage: 3.5,
            tears: 0.0,
            range: 23.75,
            speed: 1.0,
            shot_speed: 1.0,
            luck: 0.0,
            flight: false,
            damage_multiplier: 1.0,
            fire_delay_multiplier: 1.0,
            unverified: vec![],
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Stat {
    pub value: f64,
    pub base: f64,
    /// True when the answer depends on an ordering or a stacking rule that no source
    /// settles. Shown as a "~" rather than hidden.
    pub approx: bool,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct Stats {
    pub damage: Stat,
    pub tears: Stat,
    pub tear_delay: Stat,
    pub range: Stat,
    pub shot_speed: Stat,
    pub speed: Stat,
    pub luck: Stat,
    pub shots: i64,
    pub flight: bool,
}

/// The sqrt argument goes negative below t = -1/1.3; clamping at 0 covers every
/// branch in one expression and pins delay at its 16-frame maximum.
pub fn tear_delay(tear_ups: f64) -> f64 {
    BASE_TEAR_DELAY - TEAR_CURVE_SLOPE * (TEAR_CURVE_SCALE * tear_ups + 1.0).max(0.0).sqrt()
}

pub fn tears_per_second(delay: f64) -> f64 {
    (30.0 / (delay + 1.0)).min(MAX_TEARS_PER_SECOND)
}

pub fn compute(character: &Character, deltas: &[Delta]) -> Stats {
    // --- Damage -------------------------------------------------------
    let damage_ups: f64 = deltas.iter().filter_map(|d| d.damage).sum();
    let multipliers: Vec<f64> = deltas.iter().filter_map(|d| d.damage_multiplier).collect();
    let damage_mult = multipliers
        .iter()
        .fold(character.damage_multiplier, |a, m| a * m);
    // Clamped exactly like the tear curve: damage-downs (Odd Mushroom (Thin) is -0.4,
    // and stacks) can push the argument below zero, and an unclamped sqrt yields NaN,
    // which propagates into the payload and blanks the readout instead of being
    // visibly wrong.
    let damage_value =
        character.damage * (DAMAGE_CURVE_SCALE * damage_ups + 1.0).max(0.0).sqrt() * damage_mult;
    let damage_base = character.damage * character.damage_multiplier;
    // Whether AB+ stacks two x1.5 damage multipliers or shares one slot is not settled
    // by any source we could verify, so say so instead of guessing.
    let damage = Stat {
        value: damage_value,
        base: damage_base,
        approx: multipliers.len() > 1,
        reason: if multipliers.len() > 1 {
            Some(format!(
                "{} damage multipliers stack here; AB+ may share one slot",
                multipliers.len()
            ))
        } else {
            None
        },
    };

    // --- Tears --------------------------------------------------------
    let tear_ups: f64 = deltas.iter().filter_map(|d| d.tears).sum::<f64>() + character.tears;
    let mut delay = tear_delay(tear_ups).floor().max(MIN_DELAY_FROM_STATS);
    delay *= character.fire_delay_multiplier;
    let base_delay = (tear_delay(character.tears).floor().max(MIN_DELAY_FROM_STATS)
        * character.fire_delay_multiplier)
        .max(MIN_DELAY_ABSOLUTE);

    // Applied in pickup order. The game's ordering among simultaneous direct
    // modifiers is undocumented, so order only matters -- and is only flagged --
    // when more than one is present.
    let mut direct_count = 0usize;
    for d in deltas {
        if let Some(m) = d.tears_multiplier {
            if m > 0.0 {
                delay /= m;
                direct_count += 1;
            }
        }
        if let Some(add) = d.tear_delay {
            delay += add;
            direct_count += 1;
        }
    }
    delay = delay.max(MIN_DELAY_ABSOLUTE);

    let order_sensitive = direct_count > 1;
    let reason = if order_sensitive {
        Some("order of simultaneous tear modifiers is undocumented".to_string())
    } else {
        None
    };
    let tear_delay_stat = Stat {
        value: delay,
        base: base_delay,
        approx: order_sensitive,
        reason: reason.clone(),
    };
    let tears = Stat {
        value: tears_per_second(delay),
        base: tears_per_second(base_delay),
        approx: order_sensitive,
        reason,
    };

    // --- The straightforward ones ------------------------------------
    let sum = |f: fn(&Delta) -> Option<f64>| -> f64 { deltas.iter().filter_map(f).sum() };
    let range = Stat {
        value: (character.range + sum(|d| d.range)).max(5.0),
        base: character.range,
        ..Default::default()
    };
    let speed = Stat {
        value: (character.speed + sum(|d| d.speed)).max(0.1).min(2.0),
        base: character.speed,
        ..Default::default()
    };
    let shot_speed = Stat {
        value: (character.shot_speed + sum(|d| d.shot_speed)).max(0.6),
        base: character.shot_speed,
        ..Default::default()
    };
    // Luck is genuinely uncapped; the 0...10 clamp lives inside drop rolls only.
    let luck = Stat {
        value: character.luck + sum(|d| d.luck),
        base: character.luck,
        ..Default::default()
    };

    Stats {
        damage,
        tears,
        tear_delay: tear_delay_stat,
        range,
        shot_speed,
        speed,
        luck,
        shots: 1 + deltas.iter().filter_map(|d| d.shots).sum::<f64>() as i64,
        flight: character.flight || deltas.iter().any(|d| d.flight == Some(true)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d() -> Delta {
        Delta::default()
    }
    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 0.01
    }

    /// The exact fixtures the Swift engine is validated against. If the two builds
    /// ever disagree about a number, this is where it shows up.
    #[test]
    fn matches_the_swift_engine() {
        let isaac = Character::default();

        let base = compute(&isaac, &[]);
        assert!(near(base.damage.value, 3.50), "{}", base.damage.value);
        assert!(near(base.tear_delay.value, 10.0), "{}", base.tear_delay.value);
        assert!(near(base.tears.value, 2.7272), "{}", base.tears.value);

        // +Blood of the Martyr -> 3.5*sqrt(1*1.2+1) = 5.19
        let martyr = compute(&isaac, &[Delta { damage: Some(1.0), ..d() }]);
        assert!(near(martyr.damage.value, 5.1865), "{}", martyr.damage.value);

        // +Cricket's Head -> 3.5*sqrt(0.5*1.2+1)*1.5 = 6.64
        let cricket = compute(
            &isaac,
            &[Delta { damage: Some(0.5), damage_multiplier: Some(1.5), ..d() }],
        );
        assert!(near(cricket.damage.value, 6.6408), "{}", cricket.damage.value);

        // +Ipecac -> 3.5*sqrt(40*1.2+1) = 24.50, exactly 7x
        let ipecac = compute(&isaac, &[Delta { damage: Some(40.0), ..d() }]);
        assert!(near(ipecac.damage.value, 24.50), "{}", ipecac.damage.value);

        // +Sad Onion -> 16-6*sqrt(0.7*1.3+1) = 7.71 -> floor 7 -> 30/8 = 3.75 tears/s
        let onion = compute(&isaac, &[Delta { tears: Some(0.7), ..d() }]);
        assert!(near(onion.tear_delay.value, 7.0), "{}", onion.tear_delay.value);
        assert!(near(onion.tears.value, 3.75), "{}", onion.tears.value);
    }

    #[test]
    fn floors_and_caps_hold() {
        let isaac = Character::default();
        // Range floors at 5 however negative the items get.
        let r = compute(&isaac, &[Delta { range: Some(-100.0), ..d() }]);
        assert!(near(r.range.value, 5.0));
        // Speed clamps to 0.1...2.0 at both ends.
        assert!(near(compute(&isaac, &[Delta { speed: Some(-9.0), ..d() }]).speed.value, 0.1));
        assert!(near(compute(&isaac, &[Delta { speed: Some(9.0), ..d() }]).speed.value, 2.0));
        // Shot speed floors at 0.6.
        assert!(near(compute(&isaac, &[Delta { shot_speed: Some(-9.0), ..d() }]).shot_speed.value, 0.6));
        // A damage-down big enough to go negative under the sqrt must not be NaN.
        let neg = compute(&isaac, &[Delta { damage: Some(-50.0), ..d() }]);
        assert!(neg.damage.value.is_finite() && near(neg.damage.value, 0.0));
        // Tears cap at 15/s.
        assert!(tears_per_second(0.0) <= MAX_TEARS_PER_SECOND);
    }

    #[test]
    fn two_direct_tear_modifiers_are_flagged_approximate() {
        let isaac = Character::default();
        let one = compute(&isaac, &[Delta { tears_multiplier: Some(0.5), ..d() }]);
        assert!(!one.tears.approx);
        let two = compute(
            &isaac,
            &[
                Delta { tears_multiplier: Some(0.5), ..d() },
                Delta { tear_delay: Some(10.0), ..d() },
            ],
        );
        assert!(two.tears.approx);
    }
}
