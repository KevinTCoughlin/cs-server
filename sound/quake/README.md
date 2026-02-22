# Quake Sound Files

The `quakesounds` plugin expects WAV files in this directory. Sound files are
**not included** in the repository because Quake/UT sounds are copyrighted.

## Required Files

| File | Announcement |
|------|-------------|
| `firstblood.wav` | First kill of the round |
| `doublekill.wav` | 2 kills in rapid succession |
| `triplekill.wav` | 3 kills in rapid succession |
| `multikill.wav` | 4 kills in rapid succession |
| `ultrakill.wav` | 5 kills in rapid succession |
| `monsterkill.wav` | 6+ kills in rapid succession |
| `killingspree.wav` | 5 kills without dying |
| `rampage.wav` | 10 kills without dying |
| `dominating.wav` | 15 kills without dying |
| `unstoppable.wav` | 20 kills without dying |
| `godlike.wav` | 25 kills without dying |
| `headshot.wav` | Headshot kill |
| `humiliation.wav` | Knife kill |

## Format Requirements

- **Format**: PCM WAV (uncompressed)
- **Channels**: Mono
- **Sample rate**: 22050 Hz
- **Bit depth**: 16-bit

GoldSrc (HL1 engine) requires this exact format. Files that don't match will
either fail to load or sound distorted.

## Where to Find Them

Search for "quake sounds amx mod x" or "quake sounds CS 1.6" — community
sites like GameBanana and AlliedModders have free-to-use sound packs. Many CS
1.6 server resource packs include a `sound/quake/` directory ready to drop in.

## HUD-Only Mode

If no WAV files are present, the plugin automatically falls back to HUD-only
mode — announcements still appear on screen, just without audio.
