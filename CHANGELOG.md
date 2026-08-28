# Stow release notes

Newest first. `install.sh` refuses to install unless the newest `##` heading below
matches `StowVersion.current`, so release notes cannot silently fall behind the
code. The parser skips fenced blocks, which is why the format example is fenced.

Format:

```
## <x.y.z>

- One line per user-visible change, in plain language.
- Engineering detail belongs in the commit body, not here.
```

## 0.1.32

- Clicking a hidden app now waits until its menu-bar item is visibly restored before
  opening its menu, preventing menus such as ACME from appearing at the screen's far-left edge.

## 0.1.31

- The menu-bar popup is wider and keeps up to ten hidden apps visible in one row
  before switching to horizontal scrolling.
- Multi-widget apps now move a misplaced item beside one of their existing widgets,
  preventing saved app ordering from snapping it back across Stow's boundary.

## 0.1.30

- Rules now explain why a profile is active and keep a bounded activity history of
  automatic applies, restores, failures, manual overrides, and cooldowns.
- Rule order is explicit priority, duplicate application triggers are highlighted as
  conflicts, and priority can be changed with move-up and move-down controls.
- Activity rows can disable the rule that caused them, while the popover shows the
  reason for an active automatic profile.

## 0.1.29

- The first built-in profile is now Default and captures the configured starting
  arrangement; existing untouched Presenting profiles migrate without changing IDs.
- The menu-bar panel now shows the active profile, switches profiles directly, and
  offers one-step Undo after a profile change.
- Doctor now verifies all four profile shortcuts and the running automation engine.
- Failed profile arrangements restore both the prior configuration and Undo state.

## 0.1.28

- Profiles can now be created, renamed, duplicated, and saved from the current
  arrangement; custom profiles can be deleted without remapping built-in shortcuts.
- The Profiles screen is scrollable and exposes one compact editing toolbar.
- Built-in profiles remain protected so Command-Shift-1 through 4 stay stable.

## 0.1.27

- Rules can now apply a profile when a chosen application becomes frontmost and
  restore the previous profile when that application loses focus.
- Manual profile selections temporarily override the matching automatic rule until
  the user switches to another application.
- The Rules screen now creates, enables, disables, and removes live automation rules.

## 0.1.26

- Profiles now switch the real menu-bar arrangement, with Presenting, Screen Share,
  Focus, and Everything retaining distinct app-zone snapshots.
- Command-Shift-1 through Command-Shift-4 apply profiles globally, even when the
  Stow window is closed.
- Changes made in Arrange are saved automatically to the active profile.

## 0.1.25

- The menu-bar panel now states exactly how many apps are hidden and offers one
  state-aware Show or Hide action without contradictory status text.
- Arrange saves every drag automatically, removes the redundant Apply step, trims
  repeated tile metadata, and keeps system-item details collapsed until requested.
- The opened app now uses native navigation symbols, tighter hierarchy, calm feature
  previews, and Settings controls limited to behavior that works today.

## 0.1.24

- Arrangement now waits for each icon to remain in place before moving the next app,
  retries one fresh verified transaction after a transient refusal, and clears an old
  failure warning before the retry begins.
- Boundary identity now requires both position and width, preventing a neighboring app
  from being mistaken for Stow while the menu bar is reflowing.
- Structural failures such as missing Accessibility or boundary evidence still stop
  immediately instead of repeating an operation that cannot succeed.

## 0.1.23

- Updates no longer reinstall an identical build just because GitHub added a
  merge commit, and relaunches now bypass stale Launch Services registrations.
- Failed updates now show the underlying installer error while preserving the
  previous working app.

## 0.1.22

- Stow no longer recreates an already correctly placed boundary during launch,
  preventing intermittent startup arrangement failures that left every app visible.

## 0.1.21

- Press-action coverage now resolves apps while they are tucked off-screen and
  excludes Stow's own boundary, eliminating false unresolved counts.
- Standalone row and probe diagnostics now exclude display-wide spacer mechanisms
  from occupancy, matching the live panel's capacity calculation.

## 0.1.20

- Bar Doctor now verifies the live Stow boundary and emergency shortcut instead
  of labeling those working systems as future plans.
- Health scoring includes every check, so partial or unmeasurable evidence can no
  longer produce a full ring or an all-healthy verdict.
- Capacity math excludes Stow's own expanded boundary instead of reporting it as
  thousands of points of occupied app space.
- Product attribution now reads “built by GSD-ai.”

## 0.1.19

- Redesigned the menu-bar panel as a horizontal shelf that mirrors the menu bar,
  keeping up to six hidden apps in one icon run and scrolling larger sets.
- Replaced raw capacity measurements with a plain hidden-app status and a direct
  Arrange command.
- Show All, Hide All, and Add Apps now live in the shelf's trailing segment instead
  of a separate full-strength gradient button.
- Settings and Diagnostics are now labelled, while refresh and release notes remain
  in the main window where they do not crowd the everyday panel.
- The Aurora background now fades continuously instead of ending in a visible band
  through the app list.

## 0.1.18

- Show Everything now cancels every pending automatic re-tuck, so an old timer
  cannot hide an app again after an emergency restore.
- Launch arrangement failures now appear in the Stow panel with the affected app
  and a recovery action.
- Removed the old movable-boundary planner, placement-floor probe, slot map, and
  their developer-only command modes. Stow now has one stationary boundary path.
- Arrangement transactions now have deterministic tests for partial failure,
  verification failure, reverse-order rollback, and rollback failure.
- Configuration files now carry a schema version. Legacy `vaulted` values are
  rewritten as `tucked` while fields from newer builds are preserved.

## 0.1.17

- Stow now has exactly two runtime zones, On Bar and In Stow; old Deep Storage
  assignments migrate safely into In Stow.
- Arrangement changes are verified as one transaction and rolled back automatically
  if any selected app fails to land.
- Uninstalled apps are removed from Arrange automatically.
- Press Command-Shift-Escape at any time to Show Everything.
- Move failures now name the affected app and give one recovery action.

## 0.1.16

- Enlarged and thickened the Stow menu-bar mark so it matches the visual weight
  of neighboring icons at 18 points.

## 0.1.15

- Renamed the app to Stow and introduced the bar-and-tile Stow mark.
- Existing Airlock configuration and menu-bar positions are imported automatically
  on first launch without changing the Airlock data.
- Stow keeps Airlock's safe two-zone behavior: On Bar and In Stow.

## 0.1.14

- Stow now uses one reliable hatch with two zones: On Bar and In Stow.
- Existing Deep Storage assignments are treated as In Stow, avoiding the unsafe
  two-hatch path that could sweep unrelated menu-bar items.
- Arrange always moves only the apps you selected around a stationary hatch.

## 0.1.13

- Unsafe zone layouts now fail open: Stow keeps every menu-bar item visible instead of
  sweeping pinned apps away.
- Arrange disables Apply and asks you to move icons first when the requested zones cannot be
  represented without hiding an app you did not choose.
- Stow's own menu-bar control is restored automatically if a hatch ever crosses it.

## 0.1.12

- Renamed the app from Rail to Airlock and moved the source to its GitHub repository.
- Replaced the rail-and-bead artwork with an Aurora hatch mark shared by the menu bar and app icon.
- Updated the visible zones to On Bar, In Stow and Deep Storage, with inner and outer hatches.
- Existing Rail configuration, remembered app positions and seam placement are imported on first run.
- Stow uses a new bundle identity, so Accessibility must be granted once after the first install.

## 0.1.11

- Clicking a tucked app now brings it BACK to the bar so you can actually use it, then puts it away
  again after 15 seconds. It used to open the app's menu while the icon itself stayed off-screen,
  which works for reading a menu and not for anything you need to click. The wait is configurable.
- The lock icon can now be tucked, and it appears in Arrange. Stow was excluding everything of
  Apple's on the assumption that those items cannot be moved; tested directly, they can. Control
  Center's six items (clock, wifi, sound, battery, and the rest) still cannot be tucked individually,
  because macOS reports all six as one app and Stow arranges by app.
- Arrange is much faster: 0.26s at launch, against 0.71 to 1.26s at the start of this release. Two
  causes. It was moving Stow's own seam around to place the boundary, which meant destroying and
  recreating a menu bar item several times per apply; it now moves the apps instead. And it was
  re-measuring the height of your menu bar on every single look at the bar, which never changes
  unless you plug in a display.
- Fixed: an arrange that fails now says so in the log, and leaves your bar in a state that matches
  what it actually did. If your apps were already tucked it puts them back; if this was the first
  arrange and nothing had moved yet, it shows everything rather than claiming to have hidden things.
  It used to fail silently and leave everything on show either way.
- Fixed: if Stow could not put a revealed app back, it forgot about it and the app stayed out on the
  bar for good. It holds onto it now and tries again, once by itself a few seconds later and then
  whenever you next click something. It does not keep retrying forever, because each attempt is slow
  enough that you would feel it.
- Apps that were already hidden now show up in Arrange instead of vanishing from it. OneDrive was
  missing entirely for this reason. Note that an app macOS itself has dropped for lack of room has no
  window at all, so Stow lists it but cannot move it.
- Fixed: an app you had PINNED could be swept off the bar and never come back, because Stow could
  not see the item it needed to move. Vendor Agent did this on every launch.
- Fixed: Arrange sometimes reported an app it had failed to move as fine, or failed one it had
  moved. It was checking positions against a stale reading.

## 0.1.10

- Arrange applies your zones by moving the APPS instead of moving Stow's seam. Same bar, same
  zones, measured in one run: 5.88s before, 0.79s after.
- The menu bar icon matches its neighbours. It was drawing at 76% of its canvas where they fill
  about 88%, measured in a zoomed capture as 65x73px against AuthBar's 78x84. Now 34x32px beside
  its neighbour's 35x32, measured by colour extent from a screen capture rather than judged by
  eye.
- Stow no longer rearranges the bar when other apps launch or quit. That was making everything
  look like it was fighting for position: an arrange briefly reveals the whole bar, so every
  unrelated app starting anywhere produced two visible reflows. Zones are applied when you
  change one, and macOS remembers item positions across a restart by itself.
- Apps you did not choose no longer get hidden. A seam pushes everything to its left, so hiding
  one app used to take its neighbours with it, which is what the two warning banners were
  apologising for. The seam now stays put and apps move around it, so nothing is swept by
  accident. During this change Stow moved NoteBuddy back onto the bar, which had been swept off.
- If macOS refuses a move, Arrange now says so instead of quietly leaving the app where it was.
- The vault still uses the old approach, so nothing changes for a setup that uses it.

## 0.1.9

- Arrange is quicker again. Stow now checks whether the seam is already where it needs to be
  before moving it, which costs nothing, instead of always moving it at least once. A drag went
  from about 7s to between 5.6s and 6.4s.

## 0.1.8

- Arrange is much quicker, and it no longer freezes while you drag. Dropping a tile records the
  zone straight away; the seams then settle once for a whole burst of drags instead of once per
  drag. A repeat drag went from about 8s to between 1.6s and 3.9s.
- Fixed: every seam placement was aimed one icon short. A boundary is an app's LEFT edge, so a
  seam aimed there sat on the app instead of past it, and a correction pass then had to fix it
  on every single apply. Three separate places aimed differently; now they agree.
- Fixed: dragging a tile while the bar was still settling did nothing at all. Those drops are
  accepted now.
- The leftmost position a seam can reach is measured once per display instead of on every
  apply, which was costing up to 3s by itself.

## 0.1.7

- Fixed: "Reveal tucked" emptied the bar instead of restoring it. With nothing vaulted, the
  vault seam sat unplaced and still pushed, so pressing Reveal swept every app off. Five
  pinned apps went missing before this fix, none after.
- Fixed: the panel reported impossible headroom, such as "-3599pt free" with "5510 in use" on
  a 2560pt display. It was counting Stow's own seam, which is about 5,000pt wide while hiding.
  The Arrange pane already excluded it; now both surfaces get the number from one place.
- The panel is a lot shorter. What Stow is hiding now sits directly under the title, and the
  bar-budget card is one line instead of five. Showing one hidden app went from 378pt tall to
  225pt. The full arithmetic is still in Diagnostics.
- "Update now" only appears when there is actually an update. Release notes moved to a
  sparkles button in the icon row, and the version moved up into that row too.

## 0.1.6

- Arrange is a board you drag apps around, not a list. Three regions, SHOWN then TUCKED then
  VAULTED, with the seams drawn between them. Drag an app from one to another and it applies
  straight away.
- The panel now shows what Stow is HIDING, as bigger icons you can click. Clicking one opens
  that app's menu without un-hiding anything. The old panel listed what was already on the bar,
  which is the one set you can reach by clicking the icons themselves.
- When your choices hide an app you did not pick, Stow now says so in a warning block above the
  buttons instead of a line of small text below them.
- Fixed: the panel reported deeply negative headroom while hiding, because it counted Stow's own
  seam as bar space. The Arrange pane was fixed for this and the panel was not.

## 0.1.5

- Three zones, the way the design always described them. Every app is Shown, Tucked or
  Vaulted. Shown stays on the bar, Tucked comes back when you reveal, Vaulted stays away
  until you go looking for it.
- A Reveal button brings your tucked apps back without disturbing the vault. This is the
  state one seam could not express, and the reason for the second one.
- Stow now costs three slots: its icon plus two invisible seams. That is the price of three
  zones, and it is the same shape Bartender and Ice use.
- The Arrange pane shows a three-way picker per app instead of a checkbox, and warns in two
  places rather than one: an app you pinned that a seam will sweep off anyway, and an app
  you tucked that sits behind the vault and so will not come back on a reveal.

## 0.1.4

- Stow's seam is invisible now. It used to draw a bright full-height gradient among your
  icons, which read as a large block Stow had added to your bar. It is a plain gap, the
  way Ice's and Bartender's spacers are: the coloured dividers those apps show you live
  in their preferences, not in the bar.
- The seam is also as narrow as macOS allows, about 17pt. That is the floor for any
  status item, since macOS adds roughly 16pt of padding to whatever width is asked for.
- Honest about cost: Stow takes TWO slots, a visible icon plus the invisible seam. The
  README claimed one at 10pt and both halves were wrong. The two cannot be merged, since
  a wide status item's icon is not drawn at all and the token would vanish exactly while
  hiding.

## 0.1.3

- Stow hides your menu bar items now. Check or uncheck an app in Arrange, press
  Apply, and the unchecked ones leave the bar. Verified against a real bar: hide two,
  bring them back, no item ends up on the wrong side.
- A hidden app stays in the list, so you can always un-hide it. Previously it
  vanished from the list the moment it was hidden and took its own checkbox with it.
- Your choices survive quitting Stow. They used to be silently undone on relaunch.
- No manual setup step. Stow places its own seam, so you do not have to Command-drag
  anything into position first.
- Click any app in the panel's list to open that app's menu, without un-hiding
  anything. Verified on 1Password, Outlook and Murmur.
- System items are named individually (Battery, Clock, Wi-Fi, Now Playing) instead of
  six rows all reading "Control Center", and they are summarised on one line rather
  than filling the list, since Stow does not offer to hide them.
- Launching Stow while it is already running opens its window. Previously nothing
  happened and the window was reachable only through the menu bar icon.
- Fixed: applying while already hidden could leave Stow's seam spanning the whole bar,
  pushing every item off it.
- Fixed: the Arrange pane reported a negative cut position and negative headroom while
  hiding, because it measured the seam's own pushing width as if it were bar space.
- The panel opens straight away instead of pausing for about a second.

## 0.1.2

- Stow now works on an external display. On a notchless monitor it previously
  found no menu bar items at all and the probe reported nothing, because it
  asked macOS how tall the menu bar is and macOS answered 22 when the real
  answer was 30. It measures the bar directly now.
- Clicking the Stow icon opens a real panel: your bar budget in points, what is
  on the bar right now, and the update controls.
- A window with a sidebar: Arrange, Profiles, Rules, Doctor, What's New and
  Settings. Profiles and Rules show the shape they will take and say plainly
  that nothing acts on them yet, rather than pretending to work.
- The Doctor reports what it can actually measure: whether Accessibility is
  granted, the per-display point arithmetic, and press-action coverage. Where a
  check cannot be made yet it says so instead of showing a made-up result.
- What's New reads the release notes out of the installed app, and marks which
  version you are running.
- The bar budget measures the frontmost app's menus and the system's own items
  instead of treating both as zero, so headroom is a real number.
- Settings, Profiles and Rules are stored to disk, in
  `~/.config/stow/config.json`.
- Stow has an app icon.

## 0.1.1

- `Stow --probe` now runs on a notched display. It previously stopped at
  "no status items matched" and reported nothing at all.
- The probe answers the off-screen frame question with a push it performs
  itself, instead of depending on other apps' menu bar items being in the
  right place. The answer is PASS: a status item pushed off the bar keeps a
  readable width.
- The probe no longer reports press-action coverage it cannot actually
  measure. On this version of macOS every item belongs to one host process,
  so it says so plainly rather than printing a number that means nothing.

## 0.1.0

- First scaffold. Not yet a working menu bar manager.
- `Stow --probe` answers the two questions the whole design rests on: can an
  off-screen status item's frame be read, and which items respond to an
  Accessibility press action. Run this before anything else.
- The Stow mark, five states, and the Aurora Lime identity gradient.
- Bar budget arithmetic in points rather than slot counts, because an item
  carrying a countdown is several times the width of a plain glyph.
