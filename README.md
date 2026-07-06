# Rose on Ruby. The Ruby Rose

A red rose that blooms in your terminal. Pure Ruby, no gems.

```
ruby rose.rb          # bloom (Ctrl-C to quit)
ruby rose.rb --help   # all options
```

## Options

```
-c, --color NAME     Main colour, name or hex (default red)
-d, --dual           Double colour, petal tips take the second colour
    --color2 NAME    Second colour (default cream), implies --dual
-g, --guard N        Outer guard petals, 3-8 (default 5)
    --fullness F     Inner petal density, 0.4-2.5 (default 1.0)
    --size N         Canvas size in pixels
    --time S         Bloom seconds (default 7)
    --loop           Bloom forever
    --seed N         Petal layout seed
    --fps N          Frame rate cap (default 30)
    --list           List colour names
-h, --help           Show this help
```
