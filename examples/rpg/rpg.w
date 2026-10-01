// THE CRYPT OF MALGRAVE
// A tiny turn-based fantasy dungeon crawl, written in word.
//
// Pick a class, then fight your way through the undead (skeletons, zombies,
// and the Lich who raised them), one battle at a time.
//
// In battle:
//   1 - attack        strike for your weapon damage
//   2 - defend        brace; the next blow against you is halved
//   3 - skill         your class ability (costs 1 focus)
//   4 - potion        drink to heal (if you have one)
//
// Run:
//   word run rpg.w Aria                    name your hero with argument 1
//   word run rpg.w Aria /tmp/run.json      and put the journal where you like
//
// With no arguments the hero is Wanderer, and the journal goes to
// crypt-journal.json in the working directory.
//
// Nothing in the game is random. word has random() (SPEC 9), but a dungeon that
// plays out the same way every time can be tested: dev/toolchain/test_examples.sh
// drives one scripted run that has to end in VICTORY and one that has to end in
// DEFEAT.
//
// It's also a tour of the language. It uses four of the five keywords (all but
// break), `loop x in y`, a `:before` and an `:after` contract with `result`,
// arrays of numbers and of text, a map written as JSON, floating point brought
// back to whole hit points with round(), sort(), has(), keys(), copy(), args(),
// kind() == "number", in() and ended(), and fs and json to write a journal at
// the end and read it straight back.

// ------------------------------------------------------------
// Contracts: damage and healing have to stay sane. A hook that
// answers false stops the game with a contract violation, so a bug
// that produced a negative or absurd amount can't slip a wrong
// number into a hit point total.
// ------------------------------------------------------------

deal(amount)
    return amount

deal:before
    if amount < 0
        return false
    if amount > 999
        return false
    return true

mend(amount)
    return amount

mend:before
    if amount <= 0
        return false
    if amount > 999
        return false
    return true

// An :after hook checks the value on the way out instead of on the way in, and
// `result` is what the function returned (SPEC 8.2). Healing for nothing is a
// bug wherever it came from.
mend:after
    if result <= 0
        return false
    return true

// ------------------------------------------------------------
// Classes, the usual stereotypes.
//   Warrior: tough, hits hard.       Skill: Shield Bash (+6).
//   Rogue:   nimble, average.        Skill: Backstab (double).
//   Mage:    fragile, weak swing.    Skill: Fireball (+13).
// ------------------------------------------------------------

class_name(cls)
    if cls == 1
        return "Warrior"
    if cls == 2
        return "Rogue"
    return "Mage"

class_hp(cls)
    if cls == 1
        return 34
    if cls == 2
        return 27
    return 22

class_attack(cls)
    if cls == 1
        return 8
    if cls == 2
        return 6
    return 5

skill_name(cls)
    if cls == 1
        return "Shield Bash"
    if cls == 2
        return "Backstab"
    return "Fireball"

// The one place a fraction belongs in a game of whole hit points: each class
// puts a different multiplier behind its skill. round() brings the damage back
// to a whole number, and SPEC 9 makes that an explicit step instead of a silent
// truncation.
crit_mult(cls)
    if cls == 1
        return 1.25
    if cls == 2
        return 1.5
    return 1.75

skill_damage(cls, base)
    if cls == 1
        return round(base * crit_mult(cls)) + 4
    if cls == 2
        return round(base * crit_mult(cls)) + 3
    return round(base * crit_mult(cls)) + 9

// ------------------------------------------------------------
// The hero is one small array we pass around and mutate in place:
//   hero[0] hp   hero[1] maxhp   hero[2] attack
//   hero[3] class   hero[4] potions   hero[5] focus
// ------------------------------------------------------------

new_hero(cls)
    hero = text(6)
    hero[0] = class_hp(cls)
    hero[1] = class_hp(cls)
    hero[2] = class_attack(cls)
    hero[3] = cls
    hero[4] = 2
    hero[5] = 3
    return hero

// An enemy is a mixed array: a name (text) beside two numbers.
//   foe[0] name   foe[1] hp   foe[2] attack
make_foe(name, hp, atk)
    foe = text(3)
    foe[0] = name
    foe[1] = hp
    foe[2] = atk
    return foe

bar(label, value)
    out(label . ": " . value)

// ------------------------------------------------------------
// Loot is a map from the name of a thing to how many you carry.
// take() asks has() whether you already carry one, and the map goes
// into the journal as it is, since a map is JSON (SPEC 3.7).
// ------------------------------------------------------------

take(loot, item)
    if has(loot, item)
        loot[item] = loot[item] + 1
    else
        loot[item] = 1
    out("You take a " . item . ".")

// The haul, keys in order, each with its count. sort() puts the names in a
// settled order so two runs of the same dungeon read the same way.
show_loot(loot)
    if len(loot) == 0
        out("You carry nothing out of the crypt.")
        return 0
    names = sort(keys(loot))
    line = ""
    loop nm in names
        line = line . nm . " x" . loot[nm] . "  "
    out("Haul: " . copy(line, 0, len(line) - 2))

// ------------------------------------------------------------
// Combat
// ------------------------------------------------------------

// The enemy's turn. Returns the damage dealt to the hero (already applied),
// halved when the hero spent this turn defending.
foe_strike(hero, foe, guarding)
    dmg = foe[2]
    if guarding == 1
        dmg = (dmg >> 1)
    dmg = deal(dmg)
    hero[0] = hero[0] - dmg
    out("The " . foe[0] . " hits you for " . dmg . ".")
    return dmg

drink_potion(hero)
    if hero[4] <= 0
        out("You have no potions left.")
        return 0
    hero[4] = hero[4] - 1
    healed = mend(12)
    hero[0] = hero[0] + healed
    if hero[0] > hero[1]
        hero[0] = hero[1]
    out("You drink a potion and recover " . healed . " HP.")
    return 1

// Fight one enemy to the death. Returns 1 if the hero wins, 0 if the hero falls.
fight(hero, foe)
    out("")
    out("--------------------------------------")
    out("A " . foe[0] . " lurches out of the dark! (HP " . foe[1] . ")")

    loop foe[1] > 0
        if hero[0] <= 0
            return 0

        out("")
        bar("Your HP", hero[0])
        bar(foe[0] . " HP", foe[1])
        out("Potions: " . hero[4] . "   Focus: " . hero[5])
        out("1 attack   2 defend   3 " . skill_name(hero[3]) . "   4 potion")

        // ended() has to come after the menu. To answer, it has to look at the
        // input, so on a terminal it waits for a keystroke, and asked first it
        // would leave the player at a cursor with no moves on screen. The class
        // menu does the same: the prompt, then ended(), then in().
        if ended()
            return 0

        choice = in()
        guarding = 0
        acted = 1

        if kind(choice) != "number"
            out("Enter a number, 1 to 4.")
            acted = 0
        else if choice == 1
            hit = deal(hero[2])
            foe[1] = foe[1] - hit
            out("You strike the " . foe[0] . " for " . hit . ".")
        else if choice == 2
            guarding = 1
            out("You raise your guard.")
        else if choice == 3
            if hero[5] <= 0
                out("You are out of focus.")
                acted = 0
            else
                hero[5] = hero[5] - 1
                hit = deal(skill_damage(hero[3], hero[2]))
                foe[1] = foe[1] - hit
                out(skill_name(hero[3]) . " lands for " . hit . "!")
        else if choice == 4
            if drink_potion(hero) == 0
                acted = 0
        else
            out("That is not a move.")
            acted = 0

        // The enemy answers only a real move, and only if still standing.
        if acted == 1
            if foe[1] > 0
                foe_strike(hero, foe, guarding)

    out("")
    out("The " . foe[0] . " collapses into dust.")
    return 1

// ------------------------------------------------------------
// Class selection
// ------------------------------------------------------------

choose_class()
    out("")
    out("Choose your path:")
    out("  1 - Warrior   (34 HP, strong)")
    out("  2 - Rogue     (27 HP, balanced)")
    out("  3 - Mage      (22 HP, glass cannon)")

    loop true
        out("Your choice (1-3):")

        if ended()
            return 1

        pick = in()

        if kind(pick) == "number"
            if pick >= 1
                if pick <= 3
                    return pick

        out("Pick 1, 2, or 3.")

// ------------------------------------------------------------
// The dungeon: three encounters, then the Lich.
// ------------------------------------------------------------

reward(hero, loot, drop)
    out("")
    out("You catch your breath.")
    hero[4] = hero[4] + 1
    hero[5] = hero[5] + 1
    out("You find a potion (now " . hero[4] . ") and steady your focus (now " . hero[5] . ").")
    take(loot, drop)

// The crypt is a region of enemies, walked with `loop foe in foes` (SPEC 7.2),
// and drop_for() says what each one leaves behind.
build_crypt()
    foes = text(4)
    foes[0] = make_foe("Skeleton", 14, 4)
    foes[1] = make_foe("Zombie", 20, 4)
    foes[2] = make_foe("Skeleton Archer", 16, 5)
    foes[3] = make_foe("Lich Malgrave", 40, 8)
    return foes

drop_for(name)
    if name == "Skeleton"
        return "Bone Charm"
    if name == "Zombie"
        return "Grave Salt"
    if name == "Skeleton Archer"
        return "Black Arrow"
    return "Lich Sigil"

run_dungeon(hero, loot)
    foes = build_crypt()
    seen = 0
    loop foe in foes
        seen = seen + 1
        if seen == 4
            out("")
            out("The passage opens into a cold vaulted crypt.")
            out("Malgrave the Lich turns to face you.")
        if fight(hero, foe) == 0
            return 0
        if seen < 4
            reward(hero, loot, drop_for(foe[0]))
        else
            take(loot, drop_for(foe[0]))
    return 1

// ------------------------------------------------------------
// The journal. A map is JSON (SPEC 12.3), so there's nothing to
// serialize by hand: stringify it, write the file, then read it
// back and parse it. The round trip is printed, so each run shows
// that the file it wrote can be read again.
// ------------------------------------------------------------

write_journal(path, name, cls, hero, loot, won)
    entry = {}
    entry["hero"] = name
    entry["class"] = class_name(cls)
    entry["hp"] = hero[0]
    entry["potions"] = hero[4]
    entry["survived"] = won
    entry["loot"] = loot

    if !write(path, stringify(entry))
        err("Could not write the journal.")
        return 0

    raw = read(path)
    back = parse(raw)
    if back == none
        err("The journal came back unreadable.")
        return 0
    out("Journal written and read back: " . back["hero"] . " the " . back["class"] . ", " . len(back) . " fields.")
    return 1

// ------------------------------------------------------------
// Main
// ------------------------------------------------------------

out("======================================")
out("     T H E   C R Y P T   O F          ")
out("          M A L G R A V E             ")
out("======================================")

a = args()
name = "Wanderer"
if len(a) > 1
    name = a[1]

// args()[2] names the journal, so a test run can put it somewhere temporary
// instead of the working directory (SPEC 9).
journal = "crypt-journal.json"
if len(a) > 2
    journal = a[2]

out("")
out(name . ", you descend into the crypt.")
out("The dead do not rest here. Cut them down and reach the Lich.")

cls = choose_class()
hero = new_hero(cls)

out("")
out(name . " the " . class_name(cls) . " draws a blade.")
bar("HP", hero[0])
bar("Attack", hero[2])
out("Skill: " . skill_name(cls))

loot = {}
won = run_dungeon(hero, loot)

out("")
show_loot(loot)
write_journal(journal, name, cls, hero, loot, won)

out("")
out("======================================")
if won == 1
    out("Malgrave crumbles. The crypt falls silent.")
    out(name . " the " . class_name(cls) . " walks out alive.")
    out("VICTORY")
else
    out("Your light goes out beneath the earth.")
    out(name . " the " . class_name(cls) . " joins the dead.")
    out("DEFEAT")
