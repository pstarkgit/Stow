# Stow

Stow is a macOS menu-bar manager for moving selected app icons out of view and
bringing them back when needed.

It uses two plain zones:

- **On Bar**: always visible.
- **In Stow**: hidden until opened.

The app deliberately fails open. Stow never moves another app's icon and never
touches your pointer. If Stow's own control would ever leave the bar, it shows
everything instead.

## Identity

Stow uses the Aurora palette:

`#A3E635` -> `#14B8A6` -> `#4F46E5`

The mark shows one app tile moved beneath the menu bar. The full app icon uses
Aurora color; the small menu-bar form keeps the same geometry at 18 points.

The behavior-first icon study is available at
[`docs/stow-name-icon-study.html`](docs/stow-name-icon-study.html).

## Requirements

- macOS 14 or later
- Accessibility permission
- A stable signing identity is recommended so Accessibility permission survives
  reinstallations

Stow uses Accessibility to identify status items and to open a stowed app's menu.
It does not require Screen Recording.

`Command-Shift-Escape` is the global emergency shortcut for **Show Everything**.
It also cancels pending automatic re-tucks.

## Build And Install

```sh
./test.sh
./install.sh
```

The installer builds a release app, stamps the version and source metadata,
signs it, transactionally replaces `/Applications/Stow.app`, launches it, and
checks that it remains running.

Useful diagnostics:

```sh
swift run Stow --version
swift run Stow --probe
```

## Migration From Airlock

Stow uses bundle identifier `dev.starkpat.stow` and stores configuration at
`~/.config/stow/config.json`.

On its first launch, Stow imports Airlock's configuration, remembered item
positions, and saved seam placement without modifying the Airlock data.
Installing Stow stops a running Airlock process so both apps cannot compete for
the same menu-bar geometry.

Because the bundle identity changes, macOS requires Accessibility permission to
be granted to Stow once.

## How It Works

macOS has no public API for hiding another application's status item, and no
public API for moving one. Stow does neither. It owns one narrow status item, the
boundary, and widens it to push everything to its left off the bar.

Which icons sit left of the boundary is your decision, made once with a real
Command-drag in the real menu bar. macOS honours the drag and remembers every
item's position across restarts, so Stow has nothing to re-arrange at launch.

The Arrange window is a live mirror of your bar with the boundary drawn in it, so
you can see what is stowed while you drag. It records where you put things and
points out drift later: an app that came back to the visible side, or a new app
that appeared, becomes a notice with a "Keep on bar" choice rather than something
Stow moves for you.

Clicking a stowed app in the panel shrinks the boundary for a few seconds, opens
that app's menu where it really is, then widens the boundary again. Profiles are
boundary widths: switching one is instant and cannot be refused.

Configuration is schema-versioned. Older `vaulted` assignments migrate to
`tucked`, and unknown fields are retained so a newer config is not silently
flattened by an older build.

## Repository

`https://github.com/pstarkgit/Stow`
