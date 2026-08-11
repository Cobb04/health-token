# Daily hydration heatmap research

Researched 2026-08-11 against fixed commits from mature open-source calendar
heatmaps and Apple platform guidance. This note recommends a native macOS design;
it does not copy source code or visual assets from those projects.

## Recommendation

Replace the seven visible history rows in Settings with a rolling daily heatmap,
but keep the exact current-day value above it. Use the GitHub contribution-grid
grammar—weeks as columns, weekdays as rows, month labels, rounded cells, and an
intensity legend—while giving the scale hydration-specific semantics.

For the first version:

- show the last 365 Hydration Days, ending today, in a horizontally scrollable
  plot pinned to the newest week;
- keep the Settings window at its current width rather than shrinking 53 weeks
  into illegible cells;
- show `今天约 700 mL` and `近 7 日约 4.2 L` as text above the plot, so key
  information never requires hovering;
- reveal `8月11日 · 约 700 mL · 约 2.3 瓶` when the pointer rests on a day;
- expose two ranges without changing daily aggregation: `季度` shows the latest
  84 days with larger cells, while `年度` shows the latest 365 days in a
  horizontally scrollable plot.

This follows the compact-chart guidance to keep data prominent, maximize plot
width, and make interaction supplementary rather than necessary. Apple also
warns that small chart marks are hard to target and recommends expanding the hit
area to the whole plot for inspection. [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)

## Data semantics

### One source of truth

Continue deriving each cell from Drink Records within the local Hydration Day;
do not persist a second mutable heatmap total. Calendar arithmetic, time-zone
behavior, and half-open day intervals remain as decided in
[`daily-hydration-time-boundaries.md`](daily-hydration-time-boundaries.md).

The calendar input must be a continuous sequence of local days. React Activity
Calendar fills holes between its first and last date and left-pads the first week
before splitting data into seven-day columns; Airbnb HorizonCalendar derives
days with the caller-provided `Calendar`, advances with calendar day arithmetic,
and respects `firstWeekday`. Use the same principles, with the user's current
locale deciding whether the first row is Sunday or Monday.

- [React Activity Calendar `calendar.ts` at `460438b`, lines 17–75](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/lib/calendar.ts#L17-L75)
- [HorizonCalendar `Calendar+Helpers.swift` at `cf15e05`, lines 74–132](https://github.com/airbnb/HorizonCalendar/blob/cf15e05d8c3a3545678fdce07ec150dfa3a21e99/Sources/Internal/Calendar%2BHelpers.swift#L74-L132)

### Missing is not zero

Use three states, not two:

1. **Outside the displayed date range or future padding:** no cell and no
   accessibility element.
2. **Before Health Token began tracking:** `无数据`, rendered as a hollow neutral
   cell.
3. **Tracked day with no Drink Records:** `记录 0 mL`, rendered as the solid
   zero-level cell. Do not claim the user drank zero water.

The initial implementation treats the earliest surviving Drink Record as the
first provable tracking day. Earlier dates remain `无数据`; later empty days are
`没有饮水记录`. A durable `trackingStartedAt` can be added later if product
research shows that retaining an installation boundary after every record is
undone is valuable. Cal-Heatmap deliberately keeps a nullable `defaultValue`,
while React Activity Calendar turns holes into explicit zero activities;
retaining both concepts is what lets Health Token avoid misrepresenting
pre-tracking days.

## Validated prototype decision

The interactive prototype compared a rolling-year view, a large-cell recent
view, and a twelve-month atlas. User validation selected the first two as one
segmented control: `季度` keeps the recent 84-day density and `年度` keeps the
365-day view. The atlas variant is not part of the implementation. Both tabs
retain the same exact today/seven-day summaries, hover semantics, bottle-based
scale, and newest-day anchoring.

- [Cal-Heatmap `Options.ts` at `279e4ee`, lines 76–112 and 257–280](https://github.com/wa0x6e/cal-heatmap/blob/279e4eea42e962daf710ec721871cd5ffca97907/src/options/Options.ts#L76-L112)
- [React Activity Calendar `calendar.ts` at `460438b`, lines 54–75](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/lib/calendar.ts#L54-L75)

### Stable intensity levels

Use five discrete levels rather than a gradient normalized to the current
period. React Activity Calendar models activity as explicit levels (zero through
four), and Cal-Heatmap accepts an explicit scale domain and clamps outliers.
Stable bins prevent the same 700 mL day from changing color merely because a
different day entered or left the rolling window.

For Health Token's goal-free MVP, define levels from the user's configured bottle
capacity `B`:

| Level | Meaning |
|---|---|
| 0 | tracked, `0 mL` recorded |
| 1 | `0 < mL < B` |
| 2 | `B <= mL < 2B` |
| 3 | `2B <= mL < 3B` |
| 4 | `mL >= 3B` |

Label the legend `0 · <1瓶 · 1瓶 · 2瓶 · 3+瓶`. This scale reports logging volume,
not whether the amount is healthy or sufficient. If a user-configurable daily
goal is introduced later, goal percentages can replace bottle multiples; do not
silently introduce a medical default goal.

- [React Activity Calendar activity/level contract at `460438b`, lines 34–49](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/components/ActivityCalendar.tsx#L34-L49)
- [Cal-Heatmap scale normalization at `279e4ee`, lines 10–22](https://github.com/wa0x6e/cal-heatmap/blob/279e4eea42e962daf710ec721871cd5ffca97907/src/helpers/ScaleHelper.ts#L10-L22)

## Layout and interaction

Use 7 rows and week columns. Cal-Heatmap's GitHub-day template uses exactly this
mapping; React Activity Calendar derives plot dimensions from cell size and gap,
draws month/weekday labels separately, and puts an oversized calendar inside a
horizontal scrolling container.

- [Cal-Heatmap `ghDay.ts` at `279e4ee`, lines 3–33](https://github.com/wa0x6e/cal-heatmap/blob/279e4eea42e962daf710ec721871cd5ffca97907/src/templates/ghDay.ts#L3-L33)
- [React Activity Calendar layout at `460438b`, lines 272–343 and 483–505](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/components/ActivityCalendar.tsx#L272-L343)

Recommended geometry for the 430-point Settings window:

- 10-point rounded cells, 3-point gaps, 3-point corner radius;
- month labels above; show only Monday, Wednesday, Friday labels at leading;
- 12–16 points between the textual summary, plot, and legend;
- current day gets a 2-point accent ring, which remains visible without relying
  on a different fill color;
- horizontal scrolling lands at the trailing edge on first appearance and does
  not reset while the Settings window remains open.

For pointer inspection, use the full plot as the hover target and resolve the
nearest week/day cell. Keep the selected-day text in the section rather than
placing a large floating card over tiny marks. A lightweight tooltip may appear
after a short rest; React Activity Calendar uses a 150 ms hover rest and flips or
shifts the tooltip at container edges, which is a useful interaction reference.

- [React Activity Calendar tooltip at `460438b`, lines 29–79](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/components/Tooltip.tsx#L29-L79)

## Native implementation choice

Use **Swift Charts `Chart` + `RectangleMark`**, inside a horizontal SwiftUI
`ScrollView` with a fixed plot width. Apple explicitly supports heatmaps with
`RectangleMark`; Swift Charts also supplies a default accessibility element for
marks and Audio Graphs. The app targets macOS 13, so do not depend on the newer
`.chartScrollableAxes` API—let the outer `ScrollView` provide scrolling.

- [Apple `RectangleMark`](https://developer.apple.com/documentation/charts/rectanglemark)
- [Apple HIG: chart accessibility](https://developer.apple.com/design/human-interface-guidelines/charts#Enhancing-the-accessibility-of-a-chart)

Do not add a third-party calendar dependency. A custom `LazyHGrid` is acceptable
only if Swift Charts cannot achieve the cell geometry during prototyping; it
would require reimplementing axes, hit testing, and chart accessibility. Avoid
`Canvas`: 365 rectangles do not justify giving up per-mark semantics, and custom
rendering still needs an `accessibilityChartDescriptor`, which Apple permits on
any chart-like view.

- [Apple `accessibilityChartDescriptor(_:)`](https://developer.apple.com/documentation/swiftui/view/accessibilitychartdescriptor(_:))

## Color and accessibility contract

Use an adaptive neutral zero cell and four monotonic shades of the app's system
blue accent. Supply explicit light and dark palettes; React Activity Calendar
also maintains distinct system-responsive schemes and adds a subtle stroke to
separate adjacent cells. When Increase Contrast is active, strengthen the cell
stroke and separation rather than only increasing saturation.

- [React Activity Calendar theme at `460438b`, lines 13–54](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/lib/theme.ts#L13-L54)
- [React Activity Calendar cell stroke at `460438b`, lines 24–29](https://github.com/grubersjoe/react-activity-calendar/blob/460438bef11c642cc9ed47f869aeedfc68574e03/src/styles/styles.ts#L24-L29)
- [Apple `colorSchemeContrast`](https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast)

Color must not be the only carrier of meaning:

- keep the labeled five-step legend and exact selected-day text visible;
- give every day an accessibility label such as `8月11日，记录约 700 毫升，约
  2.3 瓶`;
- expose the data chronologically through Swift Charts/Audio Graphs and provide
  the chart summary `过去一年饮水记录，共记录…`;
- when `accessibilityDifferentiateWithoutColor` is enabled, supplement color
  with a bottom-up water-level inset (0%, 25%, 50%, 75%, 100%) inside each cell;
- omit padded future cells from VoiceOver and label pre-tracking cells `无数据`;
- verify light, dark, Increase Contrast, Differentiate Without Color, grayscale,
  keyboard navigation, and VoiceOver with Accessibility Inspector.

Apple says charts must not rely only on color, critical information must not
require interaction, dense data may be navigated in logical subsets, and custom
chart views can supply an accessibility descriptor. SwiftUI exposes both the
Differentiate Without Color and Increase Contrast preferences to the view.

- [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- [Apple `accessibilityDifferentiateWithoutColor`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilitydifferentiatewithoutcolor)
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## Prototype acceptance checks

1. The same mL value keeps the same intensity as the rolling period advances.
2. A pre-tracking day, a tracked 0 mL day, and a future padding position are
   visually and semantically distinct.
3. Today remains visible and selected after launch, wake, day change, clock
   change, and time-zone change.
4. Pointer inspection reaches every cell without requiring pixel-perfect cell
   targeting; keyboard and VoiceOver can reach equivalent information.
5. Light, dark, increased-contrast, grayscale, and Differentiate Without Color
   states remain legible.
6. Changing bottle capacity recomputes the legend and colors without changing
   historical mL totals.
7. The chart says `记录` / `估算`, never claims a health judgment or exact intake.
