import Foundation
import Testing

@testable import MileageCore

@MainActor
private func makePreferences() -> (Preferences, UserDefaults, String) {
    // A private suite so tests never read or clobber the installed app's real settings.
    let suite = "com.e7nt.mileage.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (Preferences(defaults: defaults), defaults, suite)
}

@Suite("Menu bar glyph preferences")
@MainActor
struct PreferencesTests {
    @Test("Falls back to the built-in glyph until the user picks one")
    func defaultsUntilOverridden() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(preferences.barGlyph(for: .claude) == "C")
        #expect(preferences.barGlyph(for: .codex) == "X")
        // The settings field stays empty so the default is visibly not a user choice.
        #expect(preferences.customBarGlyph(for: .claude).isEmpty)
    }

    @Test("A chosen glyph replaces the default")
    func storesCustomGlyph() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        preferences.setBarGlyph("Cl", for: .claude)

        #expect(preferences.barGlyph(for: .claude) == "Cl")
        #expect(preferences.customBarGlyph(for: .claude) == "Cl")
        // Other providers are untouched.
        #expect(preferences.barGlyph(for: .codex) == "X")
    }

    @Test("Clearing the field returns to the default rather than a blank bar")
    func clearingRestoresDefault() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        preferences.setBarGlyph("◆", for: .deepseek)
        #expect(preferences.barGlyph(for: .deepseek) == "◆")

        preferences.setBarGlyph("", for: .deepseek)
        #expect(preferences.barGlyph(for: .deepseek) == "D")
        #expect(preferences.customBarGlyph(for: .deepseek).isEmpty)

        // Whitespace is the same as empty; it would otherwise render as an invisible glyph.
        preferences.setBarGlyph("   ", for: .deepseek)
        #expect(preferences.barGlyph(for: .deepseek) == "D")
    }

    @Test("Long entries are capped so one provider cannot crowd out the others")
    func capsLength() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        preferences.setBarGlyph("Claude Code", for: .claude)
        #expect(preferences.barGlyph(for: .claude) == "Cla")
    }

    @Test("A multi-scalar emoji counts as one character, not several")
    func emojiCountsAsOneCharacter() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Family emoji: many scalars, one grapheme. Naive truncation would corrupt it.
        preferences.setBarGlyph("👨‍👩‍👧", for: .claude)
        #expect(preferences.barGlyph(for: .claude) == "👨‍👩‍👧")

        preferences.setBarGlyph("🐋🟣⚫🔵", for: .deepseek)
        #expect(preferences.barGlyph(for: .deepseek) == "🐋🟣⚫")
    }

    @Test("Changing a glyph notifies the menu bar to redraw")
    func notifiesOnChange() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        var notifications = 0
        preferences.onChange = { notifications += 1 }

        preferences.setBarGlyph("◆", for: .claude)
        preferences.setBarGlyph("", for: .claude)

        #expect(notifications == 2)
    }

    @Test("Settings survive a relaunch")
    func persistsAcrossInstances() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        preferences.setBarGlyph("▲", for: .codex)

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.barGlyph(for: .codex) == "▲")
    }
}
