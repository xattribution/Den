# Den: rules against generated-looking UI

These rules override anything softer in DESIGN.md. A screen that breaks one is not done.
Sources: the owner's review of the first canvas, plus published catalogs of AI-generated UI
tells (pixelslop's pattern catalog, the ux-skill "detect AI slop" checklist, Superdesign's
"why AI design looks generic").

## Color

1. **No tinted callouts.** Never put status on a colored wash: no amber, yellow, beige, cream,
   peach, mint or pastel "info/warning/success" boxes, light or dark (the dark versions are the
   muddy browns and olives). Attention comes from **position** (top of Today), a **plain word**
   ("Needs you", "Late") and an **ink icon**. Red text plus icon is allowed only for destructive
   or failed, and it is never a background.
2. **No warm off-white or brown-gray neutrals.** Page and text grays are neutral (equal R, G, B,
   or within 2). No cream, sand, parchment, "paper" or latte backgrounds, and no brown-tinted
   secondary text.
3. **No pastel washes of person colors.** A person's color appears only at **full strength**:
   their avatar disc, a filled check, a dot, and the **solid block of their events** in the
   calendar (white text on the deep day shade, black text on the bright night shade, AA or
   better). Never as a tinted card, tinted row, tinted chip background or 10–20 % alpha circle.
   Events for everyone are a solid ink block with the family's dots. Event blocks carry a
   pictogram of the kind of event (ball, tooth, music, car); that's where the life comes from.
   The person palette is the validated "Family colors" pack: bright and cheerful (the owner
   rejected muted, earthy "designer" tones as not family-friendly), the same hex in light and
   dark, always with dark ink text (#141414, 5.4:1 or better on every color). Assignment order:
   Sky `#339FEE`, Grass `#4CC157`, Lavender `#AD87ED`, Tangerine `#F88B1C`, Aqua `#10CACA`,
   Coral `#F05653`, Sunshine `#F4CE23`, Bubblegum `#F075AA`. Every neighbor in this order passes
   the color-blind (ΔE 15.9 worst) and normal-vision (ΔE 25.8 worst) separation checks in both
   themes. Never pick a person color by hand, never add a ninth by eye: run the validator.
4. **No gradients**, glows, radial blobs, gradient text or gradient borders. Nothing purple,
   indigo, lavender, violet, cyan-on-black or neon as an accent.
5. **No brand accent.** Actions are ink (near-black in light, near-white in dark). The only
   chromatic colors are people, the star, and destructive red.
6. **Dark is designed, not inverted.** True black `#000000` page (owner requirement for OLED);
   cards a step up in neutral gray; no colored glows; secondary text checked for contrast on
   both black and the card.

## Shape, depth and containers

7. **No colored side or top borders** on cards, rows or callouts. No "accent stripe" anything.
8. **No decorative shadows.** Elevation by surface color only. A shadow is allowed only on true
   overlays (a sheet, a menu) and is never stacked with a border and a tint on the same element.
9. **Radius follows the object, not one number for everything:** pill for buttons and chips,
   14 for inputs, 20 for grouped sections, full circles for avatars. Never a card inside a card.
10. **No glass:** no `backdrop-filter`, frosted panels or translucent cards.
11. **Group only what belongs together.** Platform-style grouped sections (iOS inset lists) are
    fine; wrapping every block in an identical card is not. Not every section gets a container.

## Icons and decoration

12. **No icon-in-a-circle decoration** (an icon on a tinted or gray disc at the start of a row or
    card). Icons stand alone, in ink, only where people scan for them.
13. **No sparkle, magic-wand, rocket or stars icon for AI.** The assistant is a word ("Ask") or a
    speech bubble.
14. **No emoji in UI chrome.** The one exception is the family's picture pack: original,
    full-color illustrated avatars (animals, critters, snacks, outdoors, play, home) that a
    person picks as their own picture, always inside a ring of their color. They are identity,
    not decoration, and never appear as icons on buttons or headings. No confetti, no bounce or elastic easing, no pulsing, shimmer or drifting
    decoration. Motion only for a state the person caused, and off under Reduce Motion.
15. **No decorative numbers:** no stat tiles, no sparklines, no progress bars that don't measure
    something the family set (a goal is fine; a "productivity score" is not).

## Type and copy

16. **One family, two weights.** Atkinson Hyperlegible Next at 400 and 700 (800 only for the one
    screen heading). No semibold body text, no monospace for flavor, no Inter/Roboto look-alikes.
17. **Body 17 px, left-aligned.** Nothing centered except a single empty state line or a kid tile.
18. **Plain verbs:** "Add", "Approve", "I'll drive", "Let her in". Never "Unlock", "Supercharge",
    "Streamline", "Get started", "Learn more". No exclamation marks, no filler subheadings that
    restate the heading, no invented numbers or placeholder people (John Doe, Acme).

## Interaction

19. **One tap does the thing, inline**, with Undo in place. No modal for anything that can happen
    in the row. No action that exists only on long-press or hover.
20. **Every state is drawn:** empty, loading (only if over a second), offline, error with the way
    out, disabled with the reason. Focus is always visible; touch targets 44 px or more.

## The check before anything ships

Open the screen in light and dark and ask: is there any colored background other than a
person's solid mark, any gradient, glow, shadow on a non-overlay, side stripe, icon disc,
sparkle, emoji, warm beige/cream/amber surface, or text under 4.5:1? If yes, it is not done.
