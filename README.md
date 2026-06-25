# Rose on Ruby. The Ruby Rose

Pure Ruby + standard library only.

## Run it

```powershell
ruby rose.rb                      # watch it bloom live in the console (Ctrl-C to quit)
ruby rose.rb --all -o rose        # write rose.png (APNG) and rose.gif
ruby rose.rb --apng myrose.png    # just the APNG
ruby rose.rb --help               # all options
```

## Colours (single & double-colour)

Colours are perceptually interpolated in Oklab/Oklch, so gradients stay clean
(red→pink lands on salmon, never grey). Three modes:

| Mode | What it does |
|------|--------------|
| `--mode single`   | One colour (`--color-a`). |
| `--mode two-tone` | **Concentric** double-colour: inner petals `--color-a` blending out to `--color-b` at the rim. |
| `--mode picotee`  | **Edge-tint** double-colour: petals are `--color-a` with `--color-b` painted on the edges/tips. |

Colours accept `#rrggbb`, `#rgb`, or names (`red crimson pink blush white cream
gold yellow orange magenta purple coral wine`).

```powershell
ruby rose.rb --all --mode two-tone --color-a crimson --color-b blush -o classic
ruby rose.rb --all --mode picotee  --color-a white   --color-b crimson -o picotee
ruby rose.rb --all --mode single   --color-a "#B11226" -o deepred
ruby rose.rb --all --mode picotee  --color-a gold --color-b magenta --picotee-start 0.7 -o fancy
```

## --help

```
Front-ends (default --terminal):
  --terminal            live console animation (loops until Ctrl-C)
  --apng [PATH]         write an animated PNG   (default <out>.png)
  --gif  [PATH]         write a GIF89a          (default <out>.gif)
  --all                 write both files
  --oneshot             play once, do not loop

Colour / mode:
  --mode single|two-tone|picotee
  --color-a HEX|name    --color-b HEX|name
  --picotee-start 0..1  --picotee-width 0..1
  --backdrop HEX        matte behind the rose (GIF/terminal)
  --term-bg HEX         terminal background

Geometry / timing:
  --size WxH            e.g. 200x200
  --ss 1|2|3            supersample (2 = smooth export, 1 = fast)
  --frames N            unique frames (played 2N-2 via ping-pong)
  --fps N
  --petals "1,5,8,11,15"  whorl petal counts, inner -> outer
  --ascii               terminal glyph fallback

Misc:
  -o, --out NAME        base name for default file paths
  --selftest            run internal correctness checks
  -h, --help
```
