# Design decisions

Claudock is a native macOS utility. The README is its GitHub introduction, not a separate marketing website.

The design review uses variance 3, motion 1, and density 6: predictable placement, native feedback, and enough information to compare accounts quickly. The design-taste-frontend skill's brief, copy, typography, and audit guidance informed the README. Its web-framework and landing-page animation prescriptions do not apply to the SwiftUI app or GitHub-hosted Markdown.

## Interface

- Preserve the Accounts, Overview, and Sessions tabs and the existing Claudock wordmark/icon.
- Use system sans-serif text. Page titles are 20 pt semibold; section headings are 14 pt. Numbers use monospaced digits.
- Give 5-hour, overall Weekly, and Fable limits equal weight in three aligned rows, with 6 pt bars and 15 pt rounded, monospaced percentages. Fixed label, percentage/status, and short reset columns keep bars aligned across accounts, including at 460 pt width.
- Mark elapsed window time with a 2 pt pace tick extending 2 pt above and below each bar. Show it only for a known 5-hour or 7-day duration and a reported reset time. A fill past the tick means usage is ahead of elapsed time.
- Keep full window titles and reset dates on hover and include elapsed time in accessibility labels. At 100% or more, add a symbol and “Full”; stale readings remain muted. Omit missing session/weekly rows and show a missing Fable allowance as an empty track, “—”, and “Not reported”. Keep additional limits compact, with reset times and stale indicators visible.
- Show an API-key profile's Console credit as one meter row aligned with the limit rows: spent of the credit set, "$X left of $Y", and "since" the date it was set, with Set credit… beside it. Use the limit red only below 10% or $5 left, with LOW CREDIT, which also counts toward attention.
- Use plain functional headings such as Daily tokens and Tokens by profile. Put detailed accounting mechanics behind a disclosure.
- Use native controls and SF Symbols. Avoid custom cursor effects, decorative motion, card stacks, and invented usage scores.

## Appearance

Existing appearance preferences remain supported. A user without a saved preference follows the system appearance.

Copper remains the default brand accent. Semantic warning colors and alternate accents use deeper variants in light mode, with brighter variants in dark mode. Primary controls use deeper fills with white labels.

| Light color | Hex | Contrast on light canvas |
| --- | --- | ---: |
| Copper | `#975E41` | 4.82:1 |
| Sage | `#52745A` | 4.80:1 |
| Iris | `#736596` | 4.77:1 |
| Blue | `#477092` | 4.81:1 |
| Warning | `#876735` | 4.78:1 |
| Limit reached | `#AF4E3F` | 4.83:1 |

These are solid sRGB calculations against the app's light canvas, not a claim of a complete accessibility certification. Native control effects and disabled states must also be checked in rendered light and dark views.

## README

- Keep one primary setup link above a readable product image.
- Use real SwiftUI component renders with labeled synthetic data. Do not publish real account screenshots.
- Let GitHub supply its native typography and responsive layout; do not add a second CSS framework.
- Keep the icon and brand, with no badge cloud, fabricated social proof, decorative section numbers, or poetic filler.
- Put detailed setup, token definitions, CLI reference, and troubleshooting in the user guide.
- Keep endpoint, accounting, continuation, architecture, and notarization limitations explicit.
