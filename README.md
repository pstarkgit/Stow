# Stow

Stow is a macOS menu-bar manager for moving selected app icons out of view and
bringing them back when needed.

It uses two plain zones:

- **On Bar**: always visible.
- **In Stow**: hidden until opened.

The app deliberately fails open. If a requested arrangement would hide an app
that was not selected, Stow leaves the menu bar visible instead of applying it.

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

Stow uses Accessibility to identify and move status items. It does not require
Screen Recording.

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

macOS has no public API for hiding another application's status item. Stow keeps
a narrow status item at a stable boundary and moves selected app icons around
that boundary with targeted Command-drag events.

Before applying an arrangement, Stow verifies that only selected apps would
leave the visible bar. Unsafe or unrepresentable layouts are rejected and the
bar is restored.

## Repository

`https://github.com/pstarkgit/Stow`
