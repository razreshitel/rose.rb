# Rose on Ruby. The Ruby Rose

A red rose that blooms in your terminal, in pure Ruby. It starts as a single dot and opens into a full flower facing the viewer, just the bloom, no stem or leaves. Rendered live with 24-bit truecolor Unicode half-blocks.

Pure Ruby and the standard library only. No gems, no ImageMagick, no ffmpeg. It uses `optparse`, `io/console`, and `fiddle` (the last only to switch on ANSI colour on Windows).

## Run it

```powershell
ruby rose.rb                 # watch it bloom (holds on the open flower, Ctrl-C to quit)
ruby rose.rb -c pink         # any main colour, by name or hex
ruby rose.rb -d              # double-colour: red petals fading to cream tips
ruby rose.rb --loop          # bloom over and over
ruby rose.rb --help          # every option
```

## Colour

`-c` / `--color` sets the main colour. Pass a name, a `#rrggbb`, a bare `rrggbb`, or a 3-digit `rgb` hex.

```powershell
ruby rose.rb -c crimson
ruby rose.rb -c "#B11226"
ruby rose.rb --list          # print all colour names
```

Names: red, crimson, scarlet, rose, pink, blush, coral, salmon, orange, amber, gold, yellow, cream, ivory, white, peach, magenta, fuchsia, purple, violet, lavender, lilac, blue, skyblue, teal, mint, green, black.

### Double-colour mode

`-d` / `--dual` gives the petals two colours: the main colour at the base blending out to a second colour at the tips, the classic bicolour rose look. The second colour defaults to cream; set it with `--color2` (which turns on dual mode on its own).

```powershell
ruby rose.rb -d                                  # red base, cream tips
ruby rose.rb -d -c crimson --color2 blush        # crimson to blush
ruby rose.rb --color2 gold -c purple             # purple to gold
```

## Petals

Real roses have the fewest, largest petals on the outside (the "guard petals", reflecting the 5-fold symmetry of the rose family) and grow denser toward a tightly furled centre. This rose matches that: petal counts follow a golden-ratio descent from the core outward (Fibonacci-like 21, 13, 8, 5 by default), and each whorl is offset by the golden angle (about 137.5 degrees) for a natural spiral.

- `-g` / `--guard N` sets the number of outer guard petals, 3 to 8 (default 5). Fewer guards give a tighter, more classic rose; more give a fuller, peony-like bloom.
- `--fullness F` scales the density of the inner whorls, 0.4 to 2.5 (default 1.0).

```powershell
ruby rose.rb -g 3                   # spare, few outer petals
ruby rose.rb -g 8 --fullness 1.6    # lush and full
```

## All options

```
-c, --color NAME     Main colour, name or hex (default red)
-d, --dual           Double colour mode, petal tips take the second colour
    --color2 NAME    Second colour (default cream), implies --dual
-g, --guard N        Outer guard petals, 3-8 (default 5)
    --fullness F     Inner petal density, 0.4-2.5 (default 1.0)
    --size N         Canvas size in pixels
    --time S         Bloom seconds (default 7)
    --loop           Bloom forever
    --seed N         Petal layout seed (change for a different arrangement)
    --fps N          Frame rate cap (default 30)
    --list           List colour names
-h, --help           Show this help
```

## How it works

- **Geometry.** Concentric whorls of petals on a face-on disk, each petal a rounded teardrop placed by even spacing plus a golden-angle phase, with a slight tangential lean for the spiral swirl. Whorls are drawn outer-first so the inner, furled petals overlap on top, and a swirling bud disk sits at the heart.
- **Bloom.** A single scalar `t` in `[0, 1]` drives every petal through a staggered overshoot ease, inner whorls open first, guard petals last. At `t = 0` everything collapses to the centre, a single dot.
- **Shading.** Each petal carries a per-petal brightness and a signed flank shadow along its edges, so overlapping petals stay distinct instead of blending into a flat mass while the flower opens.
- **Rendering.** Two vertical pixels per character cell using the Unicode upper and lower half-blocks with 24-bit foreground and background colour, so the vertical resolution is doubled. The canvas auto-sizes to the terminal.

## Requirements

- Ruby (any modern version).
- A terminal with 24-bit truecolor and Unicode support. Windows Terminal works out of the box; the program enables ANSI processing on Windows automatically.
