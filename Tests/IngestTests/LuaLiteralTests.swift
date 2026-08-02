import Testing
@testable import Ingest

@Suite("LuaLiteralParser")
struct LuaLiteralTests {

    @Test("Concat keys resolve through locals, exactly as EID writes them")
    func concatKeys() throws {
        var p = LuaLiteralParser("""
            local C_ID = "5.100."
            EID.ItemData = {
                [C_ID .. 1] = { Tears = 0.7 }, -- The Sad Onion
                [C_ID .. 4] = { Damage = 0.5, DamageMultiplier = 1.5 }, -- Cricket's Head
            }
            """)
        let t = try p.table(assignedTo: "EID.ItemData")
        #expect(t["5.100.1"]?.tableValue?["Tears"]?.numberValue == 0.7)
        #expect(t["5.100.4"]?.tableValue?["DamageMultiplier"]?.numberValue == 1.5)
    }

    @Test("Nested tables and mixed key kinds")
    func nested() throws {
        var p = LuaLiteralParser("""
            local C_ID = "5.100."
            EID.ItemData = {
                [C_ID .. 34] = { HeldEffect = {AngelDevilChance = 12.5}, RoomEffect = {Damage = 2} },
                [C_ID .. 118] = { TearsMultiplier = 0.33, Variables = {[1] = 13, [2] = 0.9} },
                ["5.350.7"] = { Luck = -1, Flight = true, Note = nil },
            }
            """)
        let t = try p.table(assignedTo: "EID.ItemData")
        #expect(t["5.100.34"]?.tableValue?["RoomEffect"]?.tableValue?["Damage"]?.numberValue == 2)
        #expect(t["5.100.118"]?.tableValue?["Variables"]?.tableValue?["1"]?.numberValue == 13)
        #expect(t["5.350.7"]?.tableValue?["Flight"]?.boolValue == true)
        #expect(t["5.350.7"]?.tableValue?["Luck"]?.numberValue == -1)
    }

    @Test("Array-of-arrays with escaped quotes, # markers and unicode arrows")
    func descriptionRows() throws {
        var p = LuaLiteralParser(#"""
            EID.descriptions[languageCode].collectibles={
                {"1", "The Sad Onion", "↑ {{Tears}} +0.7 Tears"}, -- comment
                {"12", "", "50% chance to teleport to the \"Dark Room\""},
                {"2", "The Inner Eye", "↓ {{Tears}} x0.48 Tears multiplier#↓ +3 Tear delay"},
            }
            """#)
        let t = try p.table(assignedTo: "EID.descriptions[languageCode].collectibles")
        #expect(t.array.count == 3)
        let first = t.array[0].tableValue!
        #expect(first.array[0].stringValue == "1")
        #expect(first.array[1].stringValue == "The Sad Onion")
        #expect(first.array[2].stringValue == "↑ {{Tears}} +0.7 Tears")
        #expect(t.array[1].tableValue!.array[2].stringValue?.contains("\"Dark Room\"") == true)
        #expect(t.array[2].tableValue!.array[2].stringValue?.contains("#") == true)
    }

    @Test("Block comments and negative/decimal numbers")
    func commentsAndNumbers() throws {
        var p = LuaLiteralParser("""
            --[[ a block
                 comment with { braces } inside ]]
            T = {
                a = -17.62,   -- Number One's range penalty
                b = 5.25,
                c = 1e2,
            }
            """)
        let t = try p.table(assignedTo: "T")
        #expect(t["a"]?.numberValue == -17.62)
        #expect(t["b"]?.numberValue == 5.25)
        #expect(t["c"]?.numberValue == 100)
    }

    // Regression: Swift reads "\r\n" as ONE Character, so a line-comment skip that
    // compares against "\n" never terminates and silently eats the rest of the file.
    // EID ships a mix of LF and CRLF, so this is not hypothetical.
    @Test("CRLF files parse")
    func crlfLineEndings() throws {
        let src = "EID.EntityTransformations={\r\n"
            + "\t-- Collectibles\r\n"
            + "\t[\"5.100.8\"] = \"4\",\r\n"
            + "\t[\"5.100.12\"] = \"2,15\", -- Magic Mushroom\r\n"
            + "}\r\n"
        var p = LuaLiteralParser(src)
        let t = try p.table(assignedTo: "EID.EntityTransformations")
        #expect(t.dict.count == 2)
        #expect(t["5.100.12"]?.stringValue == "2,15")
    }

    @Test("Inline fractions are evaluated (EID writes Multiplier = 1/3)")
    func fractions() throws {
        var p = LuaLiteralParser("""
            T = { LuckChance = {Top = 1, Bottom = 10, Multiplier = 1/3 }, d = 3 }
            """)
        let t = try p.table(assignedTo: "T")
        let m = t["LuckChance"]?.tableValue?["Multiplier"]?.numberValue
        #expect(abs((m ?? 0) - 1.0 / 3.0) < 1e-9)
        #expect(t["d"]?.numberValue == 3)
    }

    @Test("A missing target is an error, not a silent empty table")
    func missingTarget() {
        var p = LuaLiteralParser("X = { a = 1 }")
        #expect(throws: LuaParseError.self) { try p.table(assignedTo: "EID.ItemData") }
    }
}
