import Foundation
import IsaacCore

/// Finds items that widen the trinket or pocket slot, by reading what EID says.
///
/// Derived from the descriptions rather than a hardcoded id list, so the set cannot
/// quietly go stale. In Afterbirth+ this matches:
///   trinkets  -- Mom's Purse (139), Belly Button (458)
///   pocket    -- Starter Deck (251), Little Baggy (252), Deep Pockets (416),
///                Polydactyly (454)
///   actives   -- Schoolbag (534), which is an Afterbirth+ item despite being better
///                known from Repentance: it is in the game's own items.xml with
///                achievement 379, "Extra active item room"
///
/// Every one of them states a capacity of **2**, never "+1", so two of them together
/// still read as 2. Whether AB+ actually stacks them to 3 is not settled by any source
/// here, and the UI does not hard-block a third -- it only reports the capacity.
public enum SlotGrants {
    private static let re = try! NSRegularExpression(
        pattern: #"(?:hold|carry)\s+(?:(\d+)|two)\s+(trinket|rune|card|pill|active)"#,
        options: .caseInsensitive)

    public static func parse(text: String) -> SlotGrant? {
        let stripped = text.replacingOccurrences(
            of: #"\{\{[^}]*\}\}"#, with: "", options: .regularExpression)
        let range = NSRange(stripped.startIndex..., in: stripped)
        guard let m = re.firstMatch(in: stripped, range: range) else { return nil }

        var capacity = 2
        if let r = Range(m.range(at: 1), in: stripped), let n = Int(stripped[r]) { capacity = n }
        guard capacity > 1, let noun = Range(m.range(at: 2), in: stripped) else { return nil }

        let section: ItemSection
        switch stripped[noun].lowercased() {
        case "trinket": section = .trinkets
        case "active": section = .actives
        default: section = .consumables
        }
        return SlotGrant(section: section, capacity: capacity)
    }
}
