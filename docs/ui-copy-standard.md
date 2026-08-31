# Dashboard UI Copy Standard

Every string rendered by the dashboard must do exactly one of three jobs:

1. **Inform** — state a fact about the realm: a value, its unit, and when it
   was captured. (`World  healthy  up 5h 23m`)
2. **Orient** — say what this view or panel shows or where its data comes
   from, in one line. (`Now vs window peak vs direction`)
3. **Guide** — name the next action and the key or command that performs it.
   (`7 Operations schedules the fix`)

A string that does none of these is filler and gets deleted.

## Rules

- **No filler.** If deleting the string loses no information, delete it.
  Banned patterns: "at a glance", "with confidence", "summary-first",
  "worth noticing", decorative subtitles that restate the title.
- **No internal jargon.** Use words the operator actually says. Banned:
  "boundary" (say *safety* or *limits*), "wiring" (say *settings* or
  *configuration*), "hot path" (say *top severity*), "drilldown" (say
  *open*), "footprint" (say *resource use*), "ledger", "deck".
- **Labels must earn their place.** A label that only restates its value
  ("action state: Complete") is label soup — merge it into the value line
  or delete it.
- **One home per fact.** Key hints live in the command rail, not repeated
  in panel footers. Realm/console identity lives in the banner, not again
  in the sidebar.
- **Titles are plain nouns.** Name the thing ("Host Pressure"), don't
  decorate it ("Pressure Deck").
- **Errors answer three questions:** what failed, why (when known), and the
  exact command or key that fixes it. One clear error beats a cascade.
- **Empty states say what would appear and how to make it appear.**
  ("No backup timers configured yet — b runs one now, sudo backup
  schedule --daily HH:MM installs the timer.")
- **Panel intros must add a fact the title doesn't carry** (units, source,
  window, or available actions) — otherwise no intro line at all.
