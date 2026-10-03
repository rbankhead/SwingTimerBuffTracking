# SwingTimerBuffTracking

A World of Warcraft: Forever addon that overlays your short-duration buffs directly onto Blizzard's native Swing Timer bar (Main Hand, Off Hand, or Ranged — your choice) instead of adding a separate UI element. Each qualifying buff gets its own icon that slides from the bar's right edge to its left edge as it counts down.

## Features

- No buff list to maintain by default — any buff whose remaining time drops under a configurable threshold is tracked automatically (Seals, Slice and Dice, Enrage, and more)
- Optional Allowlist mode to track only specific buffs by name, regardless of duration (e.g. Seals only)
- Blocklist to permanently exclude specific buffs, regardless of any other setting
- Choose which native bar to attach to — useful for Hunters
- Two bar-scale modes, adjustable icon size
- Self-applied-only filter so other players' buffs on you don't clutter the bar
- Settings are per-character

## Installation

Drop the `SwingTimerBuffTracking` folder into your `Interface/AddOns` directory.

## Configuration

Esc > Options > AddOns > SwingTimerBuffTracking, or `/swingbufftracking`.

## Requirements

WoW: Forever (Interface 16001).
