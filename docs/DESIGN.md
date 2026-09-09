# Design decisions

Claudock is a native macOS utility. The README is its GitHub introduction, not a separate marketing website.

The design review uses variance 3, motion 1, and density 6: predictable placement, native feedback, and enough information to compare accounts quickly. The design-taste-frontend skill's brief, copy, typography, and audit guidance informed the README. Its web-framework and landing-page animation prescriptions do not apply to the SwiftUI app or GitHub-hosted Markdown.

## Interface

- Preserve the Accounts, Overview, and Sessions tabs and the existing Claudock wordmark/icon.
- Use system sans-serif text. Page titles are 20 pt semibold; section headings are 14 pt. Numbers use monospaced digits.
- An explicitly reported Fable limit leads each account with a 32 pt percentage and a 6 pt bar. The 5-hour and overall weekly pair follows with smaller 18 pt percentages.
- Keep labels, reset times, stale indicators, and scan coverage visible. A missing Fable allowance is not zero.
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
