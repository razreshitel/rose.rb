# frozen_string_literal: true
#
# rose.rb - a blooming red rose animation, in pure Ruby (stdlib only).
#
# Starts as a single red dot and opens into a fully bloomed rose facing the
# viewer - just the flower, no stem, no leaves. One engine renders the rose
# into a canonical premultiplied-linear RGBA frame; the same frames feed three
# sinks: a live 24-bit terminal animation, an animated PNG (APNG) file, and a
# GIF89a fallback. Colours are configurable, single or double (two-tone and
# picotee), all interpolated perceptually in Oklab/Oklch.
#
# Requires only: zlib, optparse, io/console, fiddle (all Ruby standard library).
#
# Usage (ruby is typically NOT on PATH on this box):
#   C:\Ruby33-x64\bin\ruby.exe rose.rb --terminal
#   C:\Ruby33-x64\bin\ruby.exe rose.rb --all -o rose
#   C:\Ruby33-x64\bin\ruby.exe rose.rb --selftest
# or use run.ps1 / run.cmd.

require 'zlib'
require 'optparse'

module Rose
  # ----------------------------------------------------------------------------
  # CONFIG - editable defaults. CLI flags override these.
  # ----------------------------------------------------------------------------
  CONFIG = {
    mode:          :two_tone,   # :single | :two_tone | :picotee
    color_a:       '#C81E2D',   # primary (inner / body)
    color_b:       '#FF9DB0',   # secondary (rim / edge)
    backdrop:      '#101014',   # matte for GIF + file composite reference
    term_bg:       '#101014',   # terminal background (terminal can't be transparent)
    width:         200,
    height:        200,
    supersample:   2,           # SS for file export (1 = fast preview)
    frames:        30,          # unique t-steps (played 2N-2 via ping-pong)
    fps:           16,
    petals_table:  [1, 5, 8, 11, 15], # whorl petal counts, inner -> outer
    petal_width:   0.66,        # petal half-width as a fraction of its length (bigger = more overlap)
    picotee_start: 0.78,        # edge fraction where colour B starts
    picotee_width: 0.18,        # softness of the picotee band
    stagger_base:  0.05,        # bloom delay for the outer rim (opens first)
    stagger:       0.45,        # extra delay per whorl toward the centre
    span:          0.55,        # per-whorl open duration
    out:           'rose',
    ascii:         false,
    oneshot:       false
  }.freeze

  PI  = Math::PI
  TAU = 2.0 * Math::PI
  GA  = PI * (3.0 - Math.sqrt(5.0))   # golden angle, ~2.39996 rad (137.50776 deg)

  module_function

  def clamp01(x); x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x); end
  def lerp(a, b, t); a + (b - a) * t; end

  def smooth(e0, e1, x)
    return 0.0 if e1 == e0
    t = (x - e0) / (e1 - e0)
    t = 0.0 if t < 0.0
    t = 1.0 if t > 1.0
    t * t * (3.0 - 2.0 * t)
  end

  def smoother(x)
    x = 0.0 if x < 0.0
    x = 1.0 if x > 1.0
    x * x * x * (x * (6.0 * x - 15.0) + 10.0)
  end

  # ----------------------------------------------------------------------------
  # Oklab - perceptual colour. All blending/interpolation happens here, never
  # in raw sRGB (avoids muddy grey midtones). Shading is a linear-RGB multiply,
  # which preserves chromaticity (hue + saturation) while changing brightness.
  # ----------------------------------------------------------------------------
  module Oklab
    # sRGB8 (0..255) -> linear (0..1)
    SRGB2LIN = Array.new(256) do |i|
      c = i / 255.0
      c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
    end.freeze

    # linear (0..1, quantised) -> sRGB8 byte
    LIN2SRGB = Array.new(4097) do |i|
      l = i / 4096.0
      c = l <= 0.0031308 ? l * 12.92 : 1.055 * (l**(1.0 / 2.4)) - 0.055
      v = (c * 255.0 + 0.5).to_i
      v < 0 ? 0 : (v > 255 ? 255 : v)
    end.freeze

    module_function

    def lin_byte(l)
      l = 0.0 if l < 0.0
      l = 1.0 if l > 1.0
      LIN2SRGB[(l * 4096.0).to_i]
    end

    def lin_to_oklab(r, g, b)
      l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
      m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
      s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
      l_ = Math.cbrt(l); m_ = Math.cbrt(m); s_ = Math.cbrt(s)
      [
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
      ]
    end

    def oklab_to_lin(ll, aa, bb)
      l_ = ll + 0.3963377774 * aa + 0.2158037573 * bb
      m_ = ll - 0.1055613458 * aa - 0.0638541728 * bb
      s_ = ll - 0.0894841775 * aa - 1.2914855480 * bb
      l = l_ * l_ * l_; m = m_ * m_ * m_; s = s_ * s_ * s_
      [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
      ]
    end

    def in_gamut?(r, g, b)
      r >= -0.001 && r <= 1.001 && g >= -0.001 && g <= 1.001 && b >= -0.001 && b <= 1.001
    end

    # Convert an Oklab colour to linear RGB, reducing chroma (keeping lightness
    # and hue) until it fits inside the sRGB gamut.
    def oklab_clip_to_lin(ll, aa, bb)
      r, g, b = oklab_to_lin(ll, aa, bb)
      return [clampf(r), clampf(g), clampf(b)] if in_gamut?(r, g, b)
      c = Math.hypot(aa, bb)
      h = Math.atan2(bb, aa)
      lo = 0.0; hi = c
      16.times do
        mid = 0.5 * (lo + hi)
        rr, gg, bb2 = oklab_to_lin(ll, mid * Math.cos(h), mid * Math.sin(h))
        if in_gamut?(rr, gg, bb2) then lo = mid else hi = mid end
      end
      r, g, b = oklab_to_lin(ll, lo * Math.cos(h), lo * Math.sin(h))
      [clampf(r), clampf(g), clampf(b)]
    end

    def clampf(x); x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x); end

    # Mix two linear-RGB colours through Oklch (lightness + chroma linear, hue
    # along the shortest arc). m in 0..1.
    def mix_lin(a_lin, b_lin, m)
      la, aa, ba = lin_to_oklab(*a_lin)
      lb, ab, bb = lin_to_oklab(*b_lin)
      ca = Math.hypot(aa, ba); cb = Math.hypot(ab, bb)
      ha = ca < 1e-4 ? nil : Math.atan2(ba, aa)
      hb = cb < 1e-4 ? nil : Math.atan2(bb, ab)
      # If one endpoint is achromatic, borrow the other's hue so we don't swing.
      ha ||= hb || 0.0
      hb ||= ha
      dh = hb - ha
      dh -= TAU while dh > PI
      dh += TAU while dh < -PI
      l = la + (lb - la) * m
      c = ca + (cb - ca) * m
      h = ha + dh * m
      oklab_clip_to_lin(l, c * Math.cos(h), c * Math.sin(h))
    end

    # "#rgb" / "#rrggbb" / small name table -> [r,g,b] linear
    NAMES = {
      'red' => '#E0202E', 'crimson' => '#C81E2D', 'scarlet' => '#FF2400',
      'pink' => '#FF8FB0', 'blush' => '#FF9DB0', 'rose' => '#E63E62',
      'white' => '#FFFFFF', 'cream' => '#FFF4E0', 'gold' => '#FFC83D',
      'yellow' => '#FFD83A', 'orange' => '#FF7A1A', 'magenta' => '#E0218A',
      'purple' => '#7A2E8E', 'coral' => '#FF6F61', 'wine' => '#7B1E2B',
      'black' => '#101014'
    }.freeze

    def parse(str)
      s = str.to_s.strip.downcase
      s = NAMES[s] || s
      raise ArgumentError, "bad colour: #{str.inspect}" unless s.start_with?('#')
      hex = s[1..]
      hex = hex.chars.map { |c| c * 2 }.join if hex.length == 3
      raise ArgumentError, "bad colour: #{str.inspect}" unless hex.length == 6 && hex =~ /\A[0-9a-f]{6}\z/
      r = hex[0, 2].to_i(16); g = hex[2, 2].to_i(16); b = hex[4, 2].to_i(16)
      [SRGB2LIN[r], SRGB2LIN[g], SRGB2LIN[b]]
    end
  end

  # ----------------------------------------------------------------------------
  # Palette - precomputes a 256-entry colour ramp so the per-pixel hot path is a
  # single array lookup. Two-tone is indexed by normalised radius; picotee by
  # the petal-local edge factor. (The perceptual Oklch mixing happens once, at
  # build time, baked into the ramp.)
  # ----------------------------------------------------------------------------
  class Palette
    N = 256
    attr_reader :a_lin

    def initialize(mode:, color_a:, color_b:, picotee_start:, picotee_width:)
      @mode  = mode
      @a_lin = Oklab.parse(color_a)
      b_lin  = Oklab.parse(color_b)
      @use_edge = (mode == :picotee)
      lo = picotee_start
      hi = [picotee_start + picotee_width, 1.0].min
      hi = lo + 0.001 if hi <= lo
      @lut = Array.new(N) do |i|
        x = i / (N - 1.0)
        case mode
        when :single   then @a_lin
        when :two_tone then Oklab.mix_lin(@a_lin, b_lin, Rose.smooth(0.0, 1.0, x))
        when :picotee  then Oklab.mix_lin(@a_lin, b_lin, Rose.smooth(lo, hi, x))
        else @a_lin
        end
      end.freeze
    end

    def lut; @lut; end
    def use_edge?; @use_edge; end

    # Deep, slightly desaturated heart of the rose (for the central bud).
    def bud_lin
      l, a, b = Oklab.lin_to_oklab(*@a_lin)
      Oklab.oklab_clip_to_lin(l * 0.52, a * 0.95, b * 0.95)
    end
  end

  # ----------------------------------------------------------------------------
  # Canvas - the shared framebuffer. Stores PREMULTIPLIED linear-light RGBA
  # floats in a flat array. Premultiplied alpha is what keeps petal edges from
  # developing a dark halo against the transparent background when downsampled.
  # ----------------------------------------------------------------------------
  class Canvas
    attr_reader :w, :h, :buf

    def initialize(w, h)
      @w = w; @h = h
      @buf = Array.new(w * h * 4, 0.0)
    end

    def clear
      @buf.fill(0.0)
    end

    # Premultiplied OVER. src colour (sr,sg,sb) is straight linear; `a` is the
    # source coverage/alpha. out = src*a + dst*(1-a); dst already premultiplied.
    def blend(idx, sr, sg, sb, a)
      return if a <= 0.0
      buf = @buf
      inv = 1.0 - a
      buf[idx]     = sr * a + buf[idx]     * inv
      buf[idx + 1] = sg * a + buf[idx + 1] * inv
      buf[idx + 2] = sb * a + buf[idx + 2] * inv
      buf[idx + 3] = a      + buf[idx + 3] * inv
    end

    # Stamp one rose petal with analytic 1px-wide anti-aliasing. The petal lives
    # in a local frame: v in [0,1] runs base->tip along `theta`, u is lateral.
    # Everything (coverage, shading, picotee edge) is computed per pixel from the
    # same local coordinates. AABB-clipped so cost scales with petal size.
    def stamp_petal(cx, cy, px0, py0, dir, lpx, bwf, curlf,
                    depth_bright, l_bias, base_alpha, bloom_r,
                    plut, use_edge, shape_lut, spine_lut, cup_lut, tip_lut)
      return if lpx < 0.6 || base_alpha <= 0.003
      buf = @buf; w = @w; h = @h
      ct = Math.cos(dir); st = Math.sin(dir)         # petal facing direction
      tpx = px0 + ct * lpx;   tpy = py0 + st * lpx    # petal tip point
      halfw = (bwf + curlf.abs) * lpx + 2.0
      # bounding box from base/tip +- perpendicular half-width
      perpx = -st; perpy = ct
      xs = [px0 + perpx * halfw, px0 - perpx * halfw, tpx + perpx * halfw, tpx - perpx * halfw]
      ys = [py0 + perpy * halfw, py0 - perpy * halfw, tpy + perpy * halfw, tpy - perpy * halfw]
      x0 = xs.min.floor - 1; x1 = xs.max.ceil + 1
      y0 = ys.min.floor - 1; y1 = ys.max.ceil + 1
      x0 = 0 if x0 < 0; y0 = 0 if y0 < 0
      x1 = w - 1 if x1 > w - 1; y1 = h - 1 if y1 > h - 1
      return if x1 < x0 || y1 < y0
      inv_lpx = 1.0 / lpx

      py = y0
      while py <= y1
        dyc = py + 0.5 - cy
        dy0 = py + 0.5 - py0
        rowoff = py * w
        px = x0
        while px <= x1
          dx0 = px + 0.5 - px0
          ly = dx0 * ct + dy0 * st          # along petal
          if ly >= -1.0 && ly <= lpx + 1.0
            lx = -dx0 * st + dy0 * ct        # lateral
            v = ly * inv_lpx
            vi = (v * 1023.0).to_i
            vi = 0 if vi < 0; vi = 1023 if vi > 1023
            wpx = bwf * shape_lut[vi] * lpx
            spn = curlf * spine_lut[vi] * lpx
            lat = (lx - spn).abs - wpx     # lateral distance to the edge
            db = -ly
            dt = ly - lpx
            d = lat
            d = db if db > d
            if dt > 0.0
              if lat > 0.0
                dc = Math.sqrt(lat * lat + dt * dt)  # rounded outer corner
                d = dc if dc > d
              else
                d = dt if dt > d
              end
            end
            cov = 0.5 - d
            if cov > 0.0
              cov = 1.0 if cov > 1.0
              a = cov * base_alpha
              if a > 0.003
                # local lateral position, normalised
                unabs = wpx > 1e-6 ? ((lx - spn).abs / wpx) : 1.0
                unabs = 1.0 if unabs > 1.0
                # colour: two-tone by radius, picotee by edge
                if use_edge
                  tip = tip_lut[vi]
                  edge = unabs > tip ? unabs : tip
                  pi = (edge * 255.0).to_i
                else
                  dxc = px + 0.5 - cx
                  rho = Math.sqrt(dxc * dxc + dyc * dyc) / bloom_r
                  pi = (rho * 255.0).to_i
                end
                pi = 0 if pi < 0; pi = 255 if pi > 255
                col = plut[pi]
                # shading (linear multiply preserves hue): cup + form shadow
                cup = cup_lut[vi]
                lambert = 0.70 + 0.30 * (1.0 - unabs * unabs)
                shade = cup * lambert * depth_bright + l_bias
                shade = 0.0 if shade < 0.0
                # subtle waxy highlight along the centre of the blade
                spec = 0.06 * shape_lut[vi] * (1.0 - unabs) * (1.0 - unabs)
                sr = col[0] * shade + spec
                sg = col[1] * shade + spec
                sb = col[2] * shade + spec
                idx = (rowoff + px) * 4
                inv = 1.0 - a
                buf[idx]     = sr * a + buf[idx]     * inv
                buf[idx + 1] = sg * a + buf[idx + 1] * inv
                buf[idx + 2] = sb * a + buf[idx + 2] * inv
                buf[idx + 3] = a      + buf[idx + 3] * inv
              end
            end
          end
          px += 1
        end
        py += 1
      end
    end

    # Soft-edged filled disk - the tight bud heart that reads as the red dot.
    def stamp_disk(cx, cy, rad, sr, sg, sb, alpha)
      return if rad <= 0.0 || alpha <= 0.0
      buf = @buf; w = @w; h = @h
      x0 = (cx - rad - 1).floor; x1 = (cx + rad + 1).ceil
      y0 = (cy - rad - 1).floor; y1 = (cy + rad + 1).ceil
      x0 = 0 if x0 < 0; y0 = 0 if y0 < 0
      x1 = w - 1 if x1 > w - 1; y1 = h - 1 if y1 > h - 1
      py = y0
      while py <= y1
        ddy = py + 0.5 - cy
        rowoff = py * w
        px = x0
        while px <= x1
          ddx = px + 0.5 - cx
          d = Math.sqrt(ddx * ddx + ddy * ddy) - rad
          cov = 0.5 - d
          if cov > 0.0
            cov = 1.0 if cov > 1.0
            a = cov * alpha
            idx = (rowoff + px) * 4
            inv = 1.0 - a
            buf[idx]     = sr * a + buf[idx]     * inv
            buf[idx + 1] = sg * a + buf[idx + 1] * inv
            buf[idx + 2] = sb * a + buf[idx + 2] * inv
            buf[idx + 3] = a      + buf[idx + 3] * inv
          end
          px += 1
        end
        py += 1
      end
    end

    # Box-average ss x ss blocks (premultiplied, in linear light) -> smaller
    # Canvas. Always returns a NEW Canvas (never self): callers cache one frame
    # per animation step, so aliasing the shared render buffer would make every
    # cached frame identical (the last one drawn).
    def downsample(ss)
      if ss <= 1
        out = Canvas.new(@w, @h)
        out.buf.replace(@buf)
        return out
      end
      ow = @w / ss; oh = @h / ss
      out = Canvas.new(ow, oh)
      ob = out.buf; ib = @buf; w = @w
      inv = 1.0 / (ss * ss)
      oy = 0
      while oy < oh
        ox = 0
        while ox < ow
          r = 0.0; g = 0.0; b = 0.0; a = 0.0
          sy = 0
          while sy < ss
            base = ((oy * ss + sy) * w + ox * ss) * 4
            sx = 0
            while sx < ss
              r += ib[base]; g += ib[base + 1]; b += ib[base + 2]; a += ib[base + 3]
              base += 4
              sx += 1
            end
            sy += 1
          end
          oidx = (oy * ow + ox) * 4
          ob[oidx] = r * inv; ob[oidx + 1] = g * inv; ob[oidx + 2] = b * inv; ob[oidx + 3] = a * inv
          ox += 1
        end
        oy += 1
      end
      out
    end

    # Premultiplied-linear -> straight sRGB8 RGBA bytes. With `bg` (linear rgb)
    # the frame is composited over an opaque backdrop (terminal/GIF); without it
    # transparency is preserved (APNG).
    def to_rgba8(bg = nil)
      buf = @buf
      n = @w * @h
      out = Array.new(n * 4)
      i = 0
      if bg
        bgr, bgg, bgb = bg
        while i < n
          b4 = i * 4
          a = buf[b4 + 3]
          inv = 1.0 - a
          r = buf[b4]     + bgr * inv
          g = buf[b4 + 1] + bgg * inv
          bl = buf[b4 + 2] + bgb * inv
          out[b4]     = Oklab.lin_byte(r)
          out[b4 + 1] = Oklab.lin_byte(g)
          out[b4 + 2] = Oklab.lin_byte(bl)
          out[b4 + 3] = 255
          i += 1
        end
      else
        while i < n
          b4 = i * 4
          a = buf[b4 + 3]
          if a > 1e-6
            ia = 1.0 / a
            out[b4]     = Oklab.lin_byte(buf[b4] * ia)
            out[b4 + 1] = Oklab.lin_byte(buf[b4 + 1] * ia)
            out[b4 + 2] = Oklab.lin_byte(buf[b4 + 2] * ia)
            out[b4 + 3] = (a * 255.0 + 0.5).to_i
            out[b4 + 3] = 255 if out[b4 + 3] > 255
          else
            out[b4] = 0; out[b4 + 1] = 0; out[b4 + 2] = 0; out[b4 + 3] = 0
          end
          i += 1
        end
      end
      out.pack('C*')
    end
  end

  # ----------------------------------------------------------------------------
  # Bloom - maps a single scalar t in [0,1] (plus a whorl's normalised depth) to
  # that whorl's per-petal pose. Outer whorls open last, so at t=0 everything is
  # collapsed onto the centre (a red dot) and the loop returns to it cleanly.
  # ----------------------------------------------------------------------------
  module Bloom
    module_function

    def petal_state(t, depth, cfg)
      # depth: 0 = innermost whorl, 1 = outer rim. Bloom outside-in: the rim
      # opens first (small delay), then inner whorls fill in toward the centre
      # (larger delay), so more and more layers appear inside the open petals.
      delay = cfg[:stagger_base] + cfg[:stagger] * (1.0 - depth)
      tp = Rose.smoother((t - delay) / cfg[:span])
      {
        alpha:       Rose.smooth(0.0, 0.16, tp),
        scale:       0.06 + 0.94 * tp,
        radius_frac: Rose.smooth(0.0, 1.0, tp),
        curl:        0.6 * (1.0 - 0.6 * tp),
        l_bias:      Rose.lerp(-0.10, 0.0, tp)
      }
    end
  end

  # ----------------------------------------------------------------------------
  # RoseModel - whorls of petals on a face-on disk. Petal shape is a teardrop:
  # narrow at the base (centre), broad in the upper third, softly pointed tip.
  # Petals are placed by even spacing within a whorl plus a golden-angle phase
  # per whorl so whorls interleave organically. Drawn back-to-front.
  # ----------------------------------------------------------------------------
  class RoseModel
    LUTN = 1024
    # half-width profile: a broad, rounded petal - some width at the base (so
    # petals overlap at the centre) widening to a broad rounded outer edge.
    SHAPE = Array.new(LUTN) do |i|
      v = i / (LUTN - 1.0)
      (0.50 + 0.50 * v) * (Math.sin(PI * (0.30 + 0.45 * v))**0.6)
    end.freeze
    # spine bow (gentle pinwheel curl)
    SPINE = Array.new(LUTN) { |i| Math.sin(PI * (i / (LUTN - 1.0))) }.freeze
    # cupping: darker, deeper throat at the base, fuller toward the blade
    CUP = Array.new(LUTN) do |i|
      v = i / (LUTN - 1.0)
      Rose.lerp(0.50, 1.0, Rose.smooth(0.0, 0.6, v)) * (1.0 - 0.10 * Rose.smooth(0.88, 1.0, v))
    end.freeze
    # tip proximity, for picotee edge tinting
    TIP = Array.new(LUTN) { |i| Rose.smooth(0.68, 1.0, i / (LUTN - 1.0)) }.freeze

    def initialize(cfg, palette, w, h)
      @cfg = cfg
      @palette = palette
      @table = cfg[:petals_table]
      @nw = @table.length
      @cx = w / 2.0
      @cy = h / 2.0
      @bloom_r = 0.40 * [w, h].min
      @bud_r, @bud_g, @bud_b = palette.bud_lin
    end

    attr_reader :bloom_r

    def draw(canvas, t)
      plut = @palette.lut
      use_edge = @palette.use_edge?
      base_pw = @cfg[:petal_width] || 0.55
      # outer whorls first (drawn underneath), inner whorls on top
      i = @nw - 1
      while i >= 1
        n = @table[i]
        depth = @nw == 1 ? 0.0 : i / (@nw - 1.0)
        bs = Bloom.petal_state(t, depth, @cfg)
        if bs[:alpha] > 0.003
          # petals emanate from near the centre (small base radius) and grow
          # longer toward the rim, so whorls nest and overlap like a real rose.
          r_base_full = 0.12 * @bloom_r * depth
          len_full    = @bloom_r * (0.40 + 0.62 * depth)
          r_base = r_base_full * bs[:radius_frac]
          lpx    = len_full * bs[:scale]
          curlf  = 0.16 * bs[:curl]
          depth_bright = 0.90 + 0.16 * depth
          phase = GA * i
          # tangential lean gives the rose its spiral swirl - tighter at the core
          lean = 0.70 * (1.0 - 0.45 * depth)
          # widen petals a touch toward the rim so adjacent outer petals overlap
          pw = base_pw * (1.0 + 0.22 * depth)
          j = 0
          while j < n
            theta = TAU * j / n + phase
            jit = ((i * 7 + j * 13) % 7) - 3       # deterministic -3..3 wobble
            lj  = lpx * (1.0 + jit * 0.022)        # +-6% length irregularity
            th  = theta + jit * 0.012
            px0 = @cx + Math.cos(th) * r_base
            py0 = @cy + Math.sin(th) * r_base
            dir = th + lean
            canvas.stamp_petal(@cx, @cy, px0, py0, dir, lj, pw, curlf,
                               depth_bright, bs[:l_bias], bs[:alpha], @bloom_r,
                               plut, use_edge, SHAPE, SPINE, CUP, TIP)
            j += 1
          end
        end
        i -= 1
      end
      # centre bud heart, drawn last so it sits on top and is the lone red dot at t=0
      rad = [@bloom_r * 0.085 * (1.0 + 0.40 * t), 1.5].max
      canvas.stamp_disk(@cx, @cy, rad, @bud_r, @bud_g, @bud_b, 1.0)
    end
  end

  # ----------------------------------------------------------------------------
  # Renderer - single source of truth. Renders n unique frames (hi-res, then
  # downsampled once) and the ping-pong play order that loops seamlessly.
  # ----------------------------------------------------------------------------
  class Renderer
    attr_reader :w, :h, :fps

    def initialize(cfg)
      @cfg = cfg
      @w = cfg[:width]; @h = cfg[:height]
      @ss = cfg[:supersample]
      @fps = cfg[:fps]
      @palette = Palette.new(
        mode: cfg[:mode], color_a: cfg[:color_a], color_b: cfg[:color_b],
        picotee_start: cfg[:picotee_start], picotee_width: cfg[:picotee_width]
      )
      @model = RoseModel.new(cfg, @palette, @w * @ss, @h * @ss)
    end

    def frames(n)
      hi = Canvas.new(@w * @ss, @h * @ss)
      out = []
      n.times do |i|
        t = n == 1 ? 1.0 : i / (n - 1.0)
        hi.clear
        @model.draw(hi, t)
        out << hi.downsample(@ss)
      end
      out
    end

    def play_sequence(n)
      return (0...n).to_a if @cfg[:oneshot]
      seq = (0...n).to_a
      seq.concat((1..(n - 2)).to_a.reverse) if n > 2
      seq
    end
  end

  # ----------------------------------------------------------------------------
  # APNG encoder - true-colour, real alpha, infinite loop, pure Ruby + zlib.
  # ----------------------------------------------------------------------------
  module Apng
    SIG = [137, 80, 78, 71, 13, 10, 26, 10].pack('C8').freeze

    module_function

    def chunk(type, data)
      [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
    end

    def zstream(rgba, w, h)
      stride = w * 4
      raw = String.new(capacity: (stride + 1) * h, encoding: 'ASCII-8BIT')
      y = 0
      while y < h
        raw << 0                                   # filter type 0 (None)
        raw << rgba.byteslice(y * stride, stride)  # one scanline
        y += 1
      end
      Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
    end

    # frames: array of RGBA8 byte strings, already in play order.
    def encode(frames, w, h, fps, loop: true)
      out = String.new(encoding: 'ASCII-8BIT')
      out << SIG
      out << chunk('IHDR', [w, h].pack('N2') + [8, 6, 0, 0, 0].pack('C5'))
      out << chunk('acTL', [frames.length, loop ? 0 : 1].pack('N2'))
      seq = 0
      delay_num = 1; delay_den = fps
      frames.each_with_index do |rgba, k|
        out << chunk('fcTL',
                     [seq, w, h, 0, 0].pack('N5') +
                     [delay_num, delay_den].pack('n2') +
                     [1, 0].pack('C2'))   # dispose=background, blend=source
        seq += 1
        z = zstream(rgba, w, h)
        if k.zero?
          out << chunk('IDAT', z)
        else
          out << chunk('fdAT', [seq].pack('N') + z)
          seq += 1
        end
      end
      out << chunk('IEND', '')
      out
    end
  end

  # ----------------------------------------------------------------------------
  # GIF89a encoder - 256-colour fallback, 1-bit alpha, infinite loop, pure Ruby.
  # Palette index 0 is reserved transparent; real colours live in 1..255.
  # ----------------------------------------------------------------------------
  module Gif
    module_function

    # Build a <=255 colour palette by median cut over opaque, matted pixels.
    def build_palette(canvases, bg)
      hist = Hash.new(0)
      canvases.each do |cv|
        buf = cv.buf; n = cv.w * cv.h
        i = 0
        while i < n
          b4 = i * 4
          a = buf[b4 + 3]
          if a >= 0.5
            inv = 1.0 - a
            r = Oklab.lin_byte(buf[b4] + bg[0] * inv)
            g = Oklab.lin_byte(buf[b4 + 1] + bg[1] * inv)
            b = Oklab.lin_byte(buf[b4 + 2] + bg[2] * inv)
            hist[(r << 16) | (g << 8) | b] += 1
          end
          i += 1
        end
      end
      colors = hist.map { |ci, cnt| [(ci >> 16) & 255, (ci >> 8) & 255, ci & 255, cnt] }
      return [[0, 0, 0]] if colors.empty?
      boxes = [colors]
      while boxes.length < 255
        cand = boxes.select { |b| b.length > 1 && box_span(b) > 0 }
        break if cand.empty?
        box = cand.max_by { |b| box_span(b) }
        boxes.delete(box)
        ch = longest_channel(box)
        box.sort_by! { |c| c[ch] }
        mid = box.length / 2
        boxes << box[0...mid] << box[mid..]
      end
      boxes.map { |b| avg_color(b) }
    end

    def box_span(box)
      r = box.map { |c| c[0] }; g = box.map { |c| c[1] }; b = box.map { |c| c[2] }
      [(r.max - r.min), (g.max - g.min), (b.max - b.min)].max
    end

    def longest_channel(box)
      r = box.map { |c| c[0] }; g = box.map { |c| c[1] }; b = box.map { |c| c[2] }
      spans = [r.max - r.min, g.max - g.min, b.max - b.min]
      spans.index(spans.max)
    end

    def avg_color(box)
      tw = 0; r = 0; g = 0; b = 0
      box.each { |c| w = c[3]; tw += w; r += c[0] * w; g += c[1] * w; b += c[2] * w }
      tw = 1 if tw.zero?
      [(r.to_f / tw).round, (g.to_f / tw).round, (b.to_f / tw).round]
    end

    # Map a frame's pixels to palette indices (0 = transparent).
    def index_frame(cv, bg, palette, cache)
      buf = cv.buf; n = cv.w * cv.h
      idx = Array.new(n, 0)
      i = 0
      while i < n
        b4 = i * 4
        a = buf[b4 + 3]
        if a >= 0.5
          inv = 1.0 - a
          r = Oklab.lin_byte(buf[b4] + bg[0] * inv)
          g = Oklab.lin_byte(buf[b4 + 1] + bg[1] * inv)
          b = Oklab.lin_byte(buf[b4 + 2] + bg[2] * inv)
          key = (r << 16) | (g << 8) | b
          pi = cache[key]
          unless pi
            pi = nearest(palette, r, g, b)
            cache[key] = pi
          end
          idx[i] = pi + 1   # shift past reserved transparent slot 0
        end
        i += 1
      end
      idx
    end

    def nearest(palette, r, g, b)
      best = 0; bd = 1 << 30
      palette.each_with_index do |c, i|
        dr = c[0] - r; dg = c[1] - g; db = c[2] - b
        d = dr * dr + dg * dg + db * db
        if d < bd then bd = d; best = i end
      end
      best
    end

    # LSB-first LZW (GIF flavour) at a FIXED code width of min_code_size+1. We
    # emit a CLEAR and reset the dictionary before the table can ever fill, so
    # the code width never changes. This sidesteps the notorious width-bump
    # desync entirely: every conformant decoder stays at the initial width and
    # only ever reacts to explicit CLEAR codes, regardless of its bump rule.
    def lzw_encode(indices, min_code_size)
      clear = 1 << min_code_size
      eoi = clear + 1
      code_size = min_code_size + 1
      limit = 1 << code_size            # codes must stay < limit (fixed width)
      dict = {}
      next_code = clear + 2
      bytes = []
      acc = 0; nbits = 0
      emit = lambda do |code|
        acc |= (code << nbits)
        nbits += code_size
        while nbits >= 8
          bytes << (acc & 0xFF)
          acc >>= 8
          nbits -= 8
        end
      end
      emit.call(clear)
      prefix = indices[0]
      i = 1
      len = indices.length
      while i < len
        c = indices[i]
        key = (prefix << 8) | c
        if dict.key?(key)
          prefix = dict[key]
        else
          emit.call(prefix)
          dict[key] = next_code
          next_code += 1
          if next_code >= limit         # table full -> reset to keep width fixed
            emit.call(clear)
            dict = {}
            next_code = clear + 2
          end
          prefix = c
        end
        i += 1
      end
      emit.call(prefix)
      emit.call(eoi)
      bytes << (acc & 0xFF) if nbits > 0
      bytes
    end

    # Matching fixed-width decoder, used only by --selftest.
    def lzw_decode(bytes, min_code_size)
      clear = 1 << min_code_size
      eoi = clear + 1
      code_size = min_code_size + 1
      limit = 1 << code_size
      mask = limit - 1
      pos = 0; acc = 0; nbits = 0
      read = lambda do
        while nbits < code_size
          acc |= ((bytes[pos] || 0) << nbits); pos += 1; nbits += 8
        end
        v = acc & mask
        acc >>= code_size; nbits -= code_size
        v
      end
      out = []
      dict = nil; next_code = nil; old = nil
      reset = lambda do
        dict = {}
        (0...clear).each { |k| dict[k] = [k] }
        next_code = clear + 2
      end
      reset.call
      loop do
        code = read.call
        if code == clear
          reset.call; old = nil; next
        elsif code == eoi
          break
        end
        entry = dict.key?(code) ? dict[code] : (dict[old] + [dict[old][0]])
        out.concat(entry)
        if old && next_code < limit
          dict[next_code] = dict[old] + [entry[0]]
          next_code += 1
        end
        old = code
      end
      out
    end

    def encode(canvases, w, h, fps, bg, loop: true)
      palette = build_palette(canvases, bg)
      cache = {}
      delay_cs = [2, (100.0 / fps).round].max

      out = String.new(encoding: 'ASCII-8BIT')
      out << 'GIF89a'
      out << [w, h].pack('v2') + [0xF7, 0, 0].pack('C3')  # global table, 256 entries
      # global colour table: index 0 = backdrop sentinel, 1..255 = palette
      gct = String.new(encoding: 'ASCII-8BIT')
      gct << Oklab.lin_byte(bg[0]) << Oklab.lin_byte(bg[1]) << Oklab.lin_byte(bg[2])
      255.times do |i|
        c = palette[i] || [0, 0, 0]
        gct << c[0] << c[1] << c[2]
      end
      out << gct
      # Netscape loop extension
      out << "\x21\xFF\x0BNETSCAPE2.0\x03\x01".b << [loop ? 0 : 1].pack('v') << "\x00".b

      canvases.each do |cv|
        out << "\x21\xF9\x04".b << [0x09].pack('C') << [delay_cs].pack('v') << [0].pack('C') << "\x00".b
        out << "\x2C".b << [0, 0, w, h].pack('v4') << [0].pack('C')
        out << [8].pack('C')  # LZW minimum code size
        data = lzw_encode(index_frame(cv, bg, palette, cache), 8)
        i = 0
        while i < data.length
          chunk = data[i, 255]
          out << [chunk.length].pack('C') << chunk.pack('C*')
          i += 255
        end
        out << "\x00".b  # block terminator
      end
      out << "\x3B".b
      out
    end
  end

  # ----------------------------------------------------------------------------
  # Terminal - live 24-bit animation using the U+2580 upper-half block so each
  # character cell shows two stacked pixels. Windows-correct (VT + UTF-8).
  # ----------------------------------------------------------------------------
  module Terminal
    HALF = "▀"  # upper half block
    RAMP = ' .:-=+*#%@'

    module_function

    def enable_windows_vt
      return unless RUBY_PLATFORM =~ /mingw|mswin/
      require 'fiddle'
      k = Fiddle.dlopen('kernel32')
      get_std = Fiddle::Function.new(k['GetStdHandle'], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
      set_mode = Fiddle::Function.new(k['SetConsoleMode'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      get_mode = Fiddle::Function.new(k['GetConsoleMode'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      set_cp = Fiddle::Function.new(k['SetConsoleOutputCP'], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      h = get_std.call(-11)
      buf = Fiddle::Pointer.malloc(4)
      get_mode.call(h, buf)
      mode = buf[0, 4].unpack1('L')
      set_mode.call(h, mode | 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
      set_cp.call(65001)               # UTF-8 code page
    rescue StandardError
      # Windows Terminal already has VT on; ignore and proceed.
    end

    def console_size
      require 'io/console'
      rows, cols = IO.console&.winsize
      rows = 24 if rows.nil? || rows <= 0
      cols = 80 if cols.nil? || cols <= 0
      [rows, cols]
    rescue StandardError
      [24, 80]
    end

    def run(cfg)
      enable_windows_vt
      STDOUT.set_encoding(Encoding::UTF_8)
      STDOUT.binmode
      STDOUT.sync = true

      rows, cols = console_size
      # Leave a 2-column margin so a full-width row never reaches the last column
      # (that would auto-wrap). Cap the size: the classic Windows console
      # (conhost) is slow at truecolor output, so a smaller grid animates
      # smoothly there. Use --size to go bigger in a fast terminal.
      cap = cfg[:term_size] || 46
      side = [[cols - 2, (rows - 1) * 2].min, cap].min
      side -= 1 if side.odd?
      side = 8 if side < 8

      rcfg = cfg.merge(width: side, height: side, supersample: 1)
      renderer = Renderer.new(rcfg)
      n = cfg[:frames]
      bg = Oklab.parse(cfg[:term_bg])
      uniq = renderer.frames(n)
      seq = renderer.play_sequence(n)
      ascii = cfg[:ascii]
      rgba = uniq.map { |cv| cv.to_rgba8(bg) }

      # Animate in place, redrawing only changed cells each frame (see
      # build_frame). We do NOT gate on tty? - that detection is unreliable
      # across Windows shells. --oneshot plays the bloom exactly once.
      once = cfg[:oneshot]
      cleanup = lambda do
        STDOUT.write("\e[?7h\e[?25h\e[0m\n")  # re-enable wrap, show cursor, reset colour
        STDOUT.flush
      end
      Signal.trap('INT') { cleanup.call; exit(0) }
      at_exit { cleanup.call }

      STDOUT.write("\e[?7l\e[2J\e[H\e[?25l")  # disable auto-wrap, clear, home, hide cursor
      delay = 1.0 / cfg[:fps]
      prev = nil
      begin
        loop do
          seq.each do |i|
            t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            STDOUT.write(build_frame(rgba[i], prev, side, side, ascii))
            STDOUT.flush
            prev = rgba[i]
            dt = delay - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
            sleep(dt) if dt > 0
          end
          break if once
        end
      ensure
        cleanup.call
      end
    end

    # Build the escape-sequence string to turn the previous frame into `cur`.
    # Only cells whose colour changed are emitted; consecutive changed cells are
    # batched after a single cursor move, and an SGR colour code is written only
    # when the colour actually changes. With `prev` nil the whole frame is drawn.
    # This keeps per-frame output small enough for slow consoles (conhost).
    def build_frame(cur, prev, w, h, ascii)
      out = String.new(encoding: 'UTF-8')
      line = 1
      y = 0
      while y < h
        rt_off = y * w * 4
        rb_off = (y + 1) * w * 4
        pr = -1; pg = -1; pb = -1; pR = -1; pG = -1; pB = -1  # last emitted colour
        inrun = false
        x = 0
        while x < w
          ti = rt_off + x * 4
          bi = rb_off + x * 4
          rt = cur.getbyte(ti); gt = cur.getbyte(ti + 1); bt = cur.getbyte(ti + 2)
          rb = cur.getbyte(bi); gb = cur.getbyte(bi + 1); bb = cur.getbyte(bi + 2)
          changed = if prev
                      !(prev.getbyte(ti) == rt && prev.getbyte(ti + 1) == gt &&
                        prev.getbyte(ti + 2) == bt && prev.getbyte(bi) == rb &&
                        prev.getbyte(bi + 1) == gb && prev.getbyte(bi + 2) == bb)
                    else
                      true
                    end
          if changed
            unless inrun
              out << "\e[#{line};#{x + 1}H"  # jump to the start of this run of changed cells
              inrun = true
              pr = -1                        # cursor moved -> force an SGR before the next glyph
            end
            if ascii
              if rt != pr || gt != pg || bt != pb
                out << "\e[38;2;#{rt};#{gt};#{bt}m"
                pr = rt; pg = gt; pb = bt
              end
              lum = (0.299 * rt + 0.587 * gt + 0.114 * bt + 0.299 * rb + 0.587 * gb + 0.114 * bb) / 2.0
              out << RAMP[(lum / 255.0 * (RAMP.length - 1)).round]
            else
              if rt != pr || gt != pg || bt != pb || rb != pR || gb != pG || bb != pB
                out << "\e[38;2;#{rt};#{gt};#{bt};48;2;#{rb};#{gb};#{bb}m"
                pr = rt; pg = gt; pb = bt; pR = rb; pG = gb; pB = bb
              end
              out << HALF
            end
          else
            inrun = false
          end
          x += 1
        end
        line += 1
        y += 2
      end
      out
    end
  end

  # ----------------------------------------------------------------------------
  # CLI
  # ----------------------------------------------------------------------------
  module CLI
    module_function

    def parse(argv)
      cfg = CONFIG.dup
      fronts = []
      paths = {}
      op = OptionParser.new do |o|
        o.banner = "Usage: ruby rose.rb [front-end] [options]"
        o.separator ''
        o.separator 'Front-ends (default --terminal):'
        o.on('--terminal', 'Live animation in the console (default; loops until Ctrl-C)') { fronts << :terminal }
        o.on('--apng [PATH]', 'Write an animated PNG (default path <out>.png)') { |p| fronts << :apng; paths[:apng] = p }
        o.on('--gif [PATH]', 'Write a GIF89a (default path <out>.gif)') { |p| fronts << :gif; paths[:gif] = p }
        o.on('--all', 'Write both files (no terminal)') { fronts << :apng << :gif }
        o.on('--oneshot', 'Play/render once instead of looping') { cfg[:oneshot] = true }
        o.separator ''
        o.separator 'Colour / mode:'
        o.on('--mode MODE', %w[single two-tone two_tone picotee],
             "single | two-tone | picotee (default: #{CONFIG[:mode].to_s.tr('_', '-')})") do |m|
          cfg[:mode] = m.tr('-', '_').to_sym
        end
        o.on('--color-a HEX', "Primary colour, #rrggbb or name (default: #{CONFIG[:color_a]})") { |c| cfg[:color_a] = c }
        o.on('--color-b HEX', "Secondary colour, #rrggbb or name (default: #{CONFIG[:color_b]})") { |c| cfg[:color_b] = c }
        o.on('--picotee-start F', Float, "Edge fraction where B begins (default: #{CONFIG[:picotee_start]})") { |f| cfg[:picotee_start] = f }
        o.on('--picotee-width F', Float, "Picotee band softness (default: #{CONFIG[:picotee_width]})") { |f| cfg[:picotee_width] = f }
        o.on('--backdrop HEX', "GIF/file matte colour (default: #{CONFIG[:backdrop]})") { |c| cfg[:backdrop] = c }
        o.on('--term-bg HEX', "Terminal background colour (default: #{CONFIG[:term_bg]})") { |c| cfg[:term_bg] = c }
        o.separator ''
        o.separator 'Geometry / timing:'
        o.on('--size WxH', "Canvas size (default: #{CONFIG[:width]}x#{CONFIG[:height]})") do |s|
          raise OptionParser::InvalidArgument, s unless s =~ /\A(\d+)x(\d+)\z/
          cfg[:width] = $1.to_i; cfg[:height] = $2.to_i
        end
        o.on('--ss N', Integer, "Supersample 1..3 (default: #{CONFIG[:supersample]})") { |n| cfg[:supersample] = [[n, 1].max, 3].min }
        o.on('--frames N', Integer, "Unique frames (default: #{CONFIG[:frames]})") { |n| cfg[:frames] = [n, 2].max }
        o.on('--fps N', Integer, "Frames per second (default: #{CONFIG[:fps]})") { |n| cfg[:fps] = [n, 1].max }
        o.on('--petals LIST', "Whorl counts inner->outer (default: #{CONFIG[:petals_table].join(',')})") do |s|
          cfg[:petals_table] = s.split(',').map { |x| x.strip.to_i }.reject(&:zero?)
        end
        o.on('--petal-width F', Float, "Petal width, more = more overlap (default: #{CONFIG[:petal_width]})") { |f| cfg[:petal_width] = f }
        o.on('--ascii', 'Terminal glyph fallback (default: off)') { cfg[:ascii] = true }
        o.on('--term-size N', Integer, 'Max terminal grid (default: 46; larger needs a fast terminal)') { |n| cfg[:term_size] = [[n, 8].max, 200].min }
        o.separator ''
        o.on('-o', '--out NAME', "Base name for default file paths (default: #{CONFIG[:out]})") { |s| cfg[:out] = s }
        o.on('--selftest', 'Run internal checks and exit') { cfg[:selftest] = true }
        o.on('-h', '--help', 'Show this help') { puts o; puts defaults_summary; exit(0) }
      end
      op.parse!(argv)

      fronts = [:terminal] if fronts.empty? && !cfg[:selftest]
      cfg[:fronts] = fronts.uniq
      cfg[:apng_path] = paths[:apng] || "#{cfg[:out]}.png"
      cfg[:gif_path]  = paths[:gif]  || "#{cfg[:out]}.gif"
      cfg
    rescue OptionParser::ParseError, ArgumentError => e
      warn "rose: #{e.message}"
      warn op.to_s if op
      exit(2)
    end

    def defaults_summary
      c = CONFIG
      <<~TXT

        Default settings (override any with the flags above):
          mode           #{c[:mode].to_s.tr('_', '-')}
          color-a        #{c[:color_a]}    color-b        #{c[:color_b]}
          picotee-start  #{c[:picotee_start]}       picotee-width  #{c[:picotee_width]}
          backdrop       #{c[:backdrop]}    term-bg        #{c[:term_bg]}
          size           #{c[:width]}x#{c[:height]}       supersample    #{c[:supersample]}
          frames         #{c[:frames]}           fps            #{c[:fps]}
          petals         #{c[:petals_table].join(',')}
          out            #{c[:out]}         (files default to #{c[:out]}.png / #{c[:out]}.gif)
          front-end      terminal, loops forever (Ctrl-C to quit; --oneshot = single pass)
      TXT
    end
  end

  module_function

  def run(argv)
    cfg = CLI.parse(argv)
    return Selftest.run if cfg[:selftest]

    # validate colours early so we fail fast with a clear message
    begin
      Oklab.parse(cfg[:color_a]); Oklab.parse(cfg[:color_b])
      Oklab.parse(cfg[:backdrop]); Oklab.parse(cfg[:term_bg])
    rescue ArgumentError => e
      warn "rose: #{e.message}"; exit(2)
    end

    fronts = cfg[:fronts]
    if fronts.include?(:apng) || fronts.include?(:gif)
      r = Renderer.new(cfg)
      n = cfg[:frames]
      uniq = r.frames(n)
      ordered = r.play_sequence(n).map { |i| uniq[i] }
      if fronts.include?(:apng)
        bytes = Apng.encode(ordered.map { |cv| cv.to_rgba8(nil) }, r.w, r.h, r.fps, loop: !cfg[:oneshot])
        File.binwrite(cfg[:apng_path], bytes)
        puts "wrote #{cfg[:apng_path]} (#{bytes.bytesize} bytes, #{ordered.length} frames)"
      end
      if fronts.include?(:gif)
        bg = Oklab.parse(cfg[:backdrop])
        bytes = Gif.encode(ordered, r.w, r.h, r.fps, bg, loop: !cfg[:oneshot])
        File.binwrite(cfg[:gif_path], bytes)
        puts "wrote #{cfg[:gif_path]} (#{bytes.bytesize} bytes, #{ordered.length} frames)"
      end
    end
    Terminal.run(cfg) if fronts.include?(:terminal)
  end

  # ----------------------------------------------------------------------------
  # Selftest - the correctness gate for the tricky parts.
  # ----------------------------------------------------------------------------
  module Selftest
    module_function

    def assert(cond, msg)
      if cond
        puts "  ok: #{msg}"
      else
        puts "  FAIL: #{msg}"
        @failed = true
      end
    end

    def run
      @failed = false
      puts 'rose selftest:'
      test_oklab
      test_canvas
      test_apng
      test_gif
      if @failed
        puts 'SELFTEST FAILED'
        exit(1)
      else
        puts 'all selftests passed'
        exit(0)
      end
    end

    def test_oklab
      # round-trip a colour through oklab
      lin = Oklab.parse('#C81E2D')
      l, a, b = Oklab.lin_to_oklab(*lin)
      r2, g2, b2 = Oklab.oklab_to_lin(l, a, b)
      assert((lin[0] - r2).abs < 1e-3 && (lin[1] - g2).abs < 1e-3 && (lin[2] - b2).abs < 1e-3,
             'oklab round-trip')
      # red -> pink midpoint is a clean salmon, not grey
      mix = Oklab.mix_lin(Oklab.parse('#C81E2D'), Oklab.parse('#FF9DB0'), 0.5)
      r = Oklab.lin_byte(mix[0]); g = Oklab.lin_byte(mix[1]); bl = Oklab.lin_byte(mix[2])
      assert(r > g + 30 && r > bl + 30, "two-tone midpoint stays reddish (#{r},#{g},#{bl})")
    end

    def test_canvas
      cv = Canvas.new(60, 60)
      cv.stamp_petal(30.0, 30.0, 30.0, 30.0, 0.0, 24.0, 0.42, 0.05,
                     1.0, 0.0, 1.0, 24.0,
                     Array.new(256) { [0.6, 0.0, 0.0] }, false,
                     RoseModel::SHAPE, RoseModel::SPINE, RoseModel::CUP, RoseModel::TIP)
      buf = cv.buf
      aa = false; solid = false
      (0...(60 * 60)).each do |i|
        a = buf[i * 4 + 3]
        aa = true if a > 0.02 && a < 0.98
        solid = true if a > 0.98
      end
      assert(aa, 'canvas produces anti-aliased (partial-alpha) edges')
      assert(solid, 'canvas produces solid interior')
    end

    def test_apng
      frames = [rgba_solid(4, 4, 255, 0, 0, 255), rgba_solid(4, 4, 0, 255, 0, 255)]
      bytes = Apng.encode(frames, 4, 4, 16, loop: true)
      assert(bytes.byteslice(0, 8).bytes == [137, 80, 78, 71, 13, 10, 26, 10], 'APNG signature')
      chunks = walk_png(bytes)
      types = chunks.map { |c| c[:type] }
      assert(types.first == 'IHDR' && types.last == 'IEND', 'IHDR first, IEND last')
      ai = types.index('acTL'); di = types.index('IDAT')
      assert(ai && di && ai < di, 'acTL precedes IDAT')
      crc_ok = chunks.all? { |c| c[:crc] == Zlib.crc32(c[:type] + c[:data]) }
      assert(crc_ok, 'all chunk CRCs valid')
      # sequence numbers across fcTL + fdAT must be contiguous from 0
      seqs = []
      chunks.each do |c|
        seqs << c[:data].byteslice(0, 4).unpack1('N') if c[:type] == 'fcTL'
        seqs << c[:data].byteslice(0, 4).unpack1('N') if c[:type] == 'fdAT'
      end
      assert(seqs == (0...seqs.length).to_a, "fcTL/fdAT sequence contiguous #{seqs.inspect}")
      idat = chunks.find { |c| c[:type] == 'IDAT' }
      raw = Zlib.inflate(idat[:data])
      assert(raw.bytesize == (4 * 4 + 1) * 4, 'frame0 inflates to (w*4+1)*h bytes')
    end

    def test_gif
      # LZW round-trip on a varied pattern + a long run, large enough to force
      # many dictionary resets (the path real decoders are picky about).
      idx = []
      20_000.times { |i| idx << (i * 7 + (i / 3)) % 200 }
      idx.concat([42] * 5000)               # long identical run
      enc = Gif.lzw_encode(idx, 8)
      dec = Gif.lzw_decode(enc, 8)
      assert(dec == idx, "GIF LZW round-trip (#{idx.length} indices, multi-reset)")
      # full GIF structure
      cv = Canvas.new(8, 8)
      cv.stamp_disk(4.0, 4.0, 3.0, 0.6, 0.0, 0.0, 1.0)
      bytes = Gif.encode([cv], 8, 8, 16, [0.05, 0.05, 0.08], loop: true)
      assert(bytes.byteslice(0, 6) == 'GIF89a', 'GIF89a header')
      assert(bytes.getbyte(bytes.bytesize - 1) == 0x3B, 'GIF trailer 0x3B')
      assert(bytes.include?('NETSCAPE2.0'), 'Netscape loop extension present')
    end

    def rgba_solid(w, h, r, g, b, a)
      ([r, g, b, a] * (w * h)).pack('C*')
    end

    def walk_png(bytes)
      out = []
      pos = 8
      while pos < bytes.bytesize
        len = bytes.byteslice(pos, 4).unpack1('N')
        type = bytes.byteslice(pos + 4, 4)
        data = bytes.byteslice(pos + 8, len)
        crc = bytes.byteslice(pos + 8 + len, 4).unpack1('N')
        out << { type: type, data: data, crc: crc }
        pos += 12 + len
      end
      out
    end
  end
end

Rose.run(ARGV) if __FILE__ == $PROGRAM_NAME
