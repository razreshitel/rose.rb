#!/usr/bin/env ruby
# frozen_string_literal: true
# Terminal rose bloom.

require 'optparse'
begin
  require 'io/console'
rescue LoadError
end

NAMED_COLORS = {
  'red' => 0xd2122e, 'crimson' => 0xdc143c, 'scarlet' => 0xff2400,
  'rose' => 0xff2e6d, 'pink' => 0xff7fa8, 'blush' => 0xf4a7b9,
  'coral' => 0xff6f61, 'salmon' => 0xfa8072, 'orange' => 0xff7518,
  'amber' => 0xffbf00, 'gold' => 0xffd24a, 'yellow' => 0xffe135,
  'cream' => 0xf6efd8, 'ivory' => 0xfffbea, 'white' => 0xffffff,
  'peach' => 0xffc09f, 'magenta' => 0xe0218a, 'fuchsia' => 0xff3ea5,
  'purple' => 0x8e44ad, 'violet' => 0x7a4dd8, 'lavender' => 0xb57edc,
  'lilac' => 0xc8a2c8, 'blue' => 0x3b6fe0, 'skyblue' => 0x6fb7ff,
  'teal' => 0x14a098, 'mint' => 0x98e2c6, 'green' => 0x2e9e4f,
  'black' => 0x2a2226
}.freeze

def parse_color(str)
  k = str.to_s.strip.downcase.sub(/\A#/, '')
  hex = NAMED_COLORS[k]
  hex ||= k.to_i(16) if k.match?(/\A\h{6}\z/)
  hex ||= k.chars.map { |c| c * 2 }.join.to_i(16) if k.match?(/\A\h{3}\z/)
  abort "Unknown colour '#{str}'. Try --list or RRGGBB hex." unless hex
  [(hex >> 16) & 255, (hex >> 8) & 255, hex & 255].map { |v| v / 255.0 }
end

def smoothstep(a, b, x)
  t = (x - a) / (b - a)
  t = t < 0.0 ? 0.0 : t > 1.0 ? 1.0 : t
  t * t * (3.0 - 2.0 * t)
end

# overshoot ease
def ease_back(x)
  return 0.0 if x <= 0.0
  return 1.0 if x >= 1.0
  c = 1.15
  1.0 + (c + 1.0) * (x - 1.0)**3 + c * (x - 1.0)**2
end

# windows vt on
def enable_vt
  return unless Gem.win_platform?
  require 'fiddle'
  k32 = Fiddle.dlopen('kernel32')
  std = Fiddle::Function.new(k32['GetStdHandle'], [Fiddle::TYPE_LONG], Fiddle::TYPE_VOIDP).call(-11)
  get = Fiddle::Function.new(k32['GetConsoleMode'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  set = Fiddle::Function.new(k32['SetConsoleMode'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG], Fiddle::TYPE_INT)
  buf = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
  set.call(std, buf[0, 4].unpack1('L') | 4) if get.call(std, buf) != 0
rescue StandardError, LoadError
  nil
end

class Rose
  STEPS = 160
  OPEN = 0.34
  PHI = 1.618033988749895
  GOLDEN_ANGLE = 2.399963229728653
  # inner to outer whorls
  BANDS = [
    { base: 0.030, tip: 0.26, appear: 0.05, light: 0.58 },
    { base: 0.100, tip: 0.48, appear: 0.24, light: 0.72 },
    { base: 0.180, tip: 0.72, appear: 0.44, light: 0.86 },
    { base: 0.260, tip: 1.00, appear: 0.63, light: 1.00 }
  ].freeze

  attr_reader :n

  def initialize(size:, main:, second:, dual:, seed:, duration:, repeat:, fps:, guard: 5, fullness: 1.0, padx: 0)
    @n = size
    @cx = @cy = (size - 1) / 2.0
    @rr = size * 0.455
    @main = main
    @second = second
    @dual = dual
    @duration = duration
    @repeat = repeat
    @fps = fps
    @guard = guard.round.clamp(3, 8)
    @fullness = fullness.clamp(0.4, 2.5)
    @padx = padx
    @stop = false
    build_luts
    build_petals(seed)
  end

  def build_luts
    last = STEPS - 1.0
    @iprof = Array.new(STEPS)
    @vedge = Array.new(STEPS)
    STEPS.times do |i|
      u = i / last
      # petal shape
      prof = (0.30 + 0.70 * Math.sin(Math::PI * u * 0.72)) * Math.sqrt([1.0 - u**6, 0.0].max)
      @iprof[i] = 1.0 / [prof, 0.045].max
      # signed flank shade
      vs = u * 2.0 - 1.0
      a = vs.abs
      rim = a < 0.62 ? 1.0 : 1.0 - 0.52 * ((a - 0.62) / 0.38)**1.35
      @vedge[i] = (0.93 + 0.07 * vs) * rim
    end
  end

  # golden ratio descent
  def petal_count(bi, outer)
    return @guard if bi == outer
    (@guard * PHI**(outer - bi) * @fullness).round.clamp(@guard, 34)
  end

  def build_petals(seed)
    rng = Random.new(seed)
    last = STEPS - 1.0
    outer = BANDS.size - 1
    @petals = []
    outer.downto(0) do |bi|
      band = BANDS[bi]
      cnt = petal_count(bi, outer)
      len = (band[:tip] - band[:base]) * @rr
      rmid = (band[:base] + 0.55 * (band[:tip] - band[:base])) * @rr
      hw = [Math::PI * rmid / cnt * 2.15, len * 0.72].min
      spin = bi * GOLDEN_ANGLE + rng.rand * 0.22
      cnt.times do |k|
        ja = (rng.rand - 0.5) * Math::PI * 2 / cnt * 0.24
        jl = 0.92 + rng.rand * 0.16
        jw = 0.90 + rng.rand * 0.20
        jb = 0.86 + 0.20 * ((k * 0.618034) % 1.0)
        lr = Array.new(STEPS)
        lg = Array.new(STEPS)
        lb = Array.new(STEPS)
        STEPS.times do |i|
          u = i / last
          light = band[:light] * (0.50 + 0.48 * u**1.35) * jb
          light *= 0.66 + 0.34 * u / 0.18 if u < 0.18
          light = 1.0 if light > 1.0
          col = @main
          if @dual
            m = smoothstep(0.40, 0.94, u)**1.05 * 0.92
            col = [
              @main[0] + (@second[0] - @main[0]) * m,
              @main[1] + (@second[1] - @main[1]) * m,
              @main[2] + (@second[2] - @main[2]) * m
            ]
          end
          lr[i] = (col[0] * light * 255).round
          lg[i] = (col[1] * light * 255).round
          lb[i] = (col[2] * light * 255).round
        end
        @petals << {
          appear: band[:appear],
          ang: spin + Math::PI * 2 * k / cnt + ja,
          base: band[:base] * @rr, len: len * jl, hw: hw * jw,
          ph: rng.rand * Math::PI * 2, lr: lr, lg: lg, lb: lb
        }
      end
    end
  end

  def frame(t)
    buf = Array.new(@n * @n)
    tc = t < 1.0 ? t : 1.0
    grot = 0.5 * (1.0 - (1.0 - tc)**2) + 0.02 * Math.sin(t * 3.0)
    wob = 1.2 - tc
    @petals.each do |pet|
      x = (t - pet[:appear]) / OPEN
      se = ease_back(x)
      next if se < 0.02
      s1 = se > 1.0 ? 1.0 : se
      ang = pet[:ang] + (1.0 - s1) * 1.35 + grot + 0.035 * wob * Math.sin(t * 19.0 + pet[:ph])
      r0 = pet[:base] * (0.15 + 0.85 * s1)
      ln = pet[:len] * (0.18 + 0.82 * se)
      hw = pet[:hw] * (0.10 + 0.90 * se**1.15)
      draw_petal(buf, ang, r0, ln, hw, pet)
    end
    draw_center(buf, t)
    buf
  end

  def draw_petal(buf, ang, r0, ln, hw, pet)
    return if ln < 1.0 || hw < 0.7
    ca = Math.cos(ang)
    sa = Math.sin(ang)
    bx = @cx + ca * r0
    by = @cy + sa * r0
    tx = @cx + ca * (r0 + ln)
    ty = @cy + sa * (r0 + ln)
    px = -sa * hw
    py = ca * hw
    xs = [bx + px, bx - px, tx + px, tx - px]
    ys = [by + py, by - py, ty + py, ty - py]
    x0 = xs.min.floor - 1
    x1 = xs.max.ceil + 1
    y0 = ys.min.floor - 1
    y1 = ys.max.ceil + 1
    nm = @n - 1
    x0 = 0 if x0 < 0
    y0 = 0 if y0 < 0
    x1 = nm if x1 > nm
    y1 = nm if y1 > nm
    return if x1 < x0 || y1 < y0
    ily = 1.0 / ln
    ihw = 1.0 / hw
    last = STEPS - 1
    halfl = last / 2.0
    lr = pet[:lr]
    lg = pet[:lg]
    lb = pet[:lb]
    y = y0
    while y <= y1
      dy = y - @cy
      row = y * @n
      dyca = dy * ca
      dysa = dy * sa
      x = x0
      while x <= x1
        dx = x - @cx
        u = (dx * ca + dysa - r0) * ily
        if u >= 0.0 && u < 1.0
          ui = (u * last).to_i
          vs = (dyca - dx * sa) * ihw * @iprof[ui]
          if vs > -1.0 && vs < 1.0
            e = @vedge[((vs + 1.0) * halfl).to_i]
            buf[row + x] = ((lr[ui] * e).to_i << 16) | ((lg[ui] * e).to_i << 8) | (lb[ui] * e).to_i
          end
        end
        x += 1
      end
      y += 1
    end
  end

  def draw_center(buf, t)
    g = smoothstep(0.0, 0.55, t)
    rc = 1.8 + @rr * 0.075 * g
    r2 = rc * rc
    x0 = (@cx - rc).floor
    x1 = (@cx + rc).ceil
    y0 = (@cy - rc).floor
    y1 = (@cy + rc).ceil
    nm = @n - 1
    x0 = 0 if x0 < 0
    y0 = 0 if y0 < 0
    x1 = nm if x1 > nm
    y1 = nm if y1 > nm
    mr = @main[0] * 255
    mg = @main[1] * 255
    mb = @main[2] * 255
    y = y0
    while y <= y1
      dy = y - @cy
      row = y * @n
      x = x0
      while x <= x1
        dx = x - @cx
        d2 = dx * dx + dy * dy
        if d2 <= r2
          d = Math.sqrt(d2) / rc
          sw = 0.5 + 0.5 * Math.sin(Math.atan2(dy, dx) * 3.0 + d * 8.0 - t * 2.0)
          f = (0.30 + 0.26 * (1.0 - d)) * (0.72 + 0.28 * sw) * (1.6 - 0.6 * g)
          f = 1.0 if f > 1.0
          buf[row + x] = ((mr * f).to_i << 16) | ((mg * f).to_i << 8) | (mb * f).to_i
        end
        x += 1
      end
      y += 1
    end
  end

  # half block cells
  def render(buf)
    out = +"\e[H"
    pad = ' ' * @padx
    half = @n / 2
    n = @n
    y = 0
    while y < half
      out << pad
      fg = -1
      bg = -1
      rowu = (y * 2) * n
      rowl = rowu + n
      x = 0
      while x < n
        up = buf[rowu + x]
        lo = buf[rowl + x]
        if up
          if fg != up
            out << "\e[38;2;#{(up >> 16) & 255};#{(up >> 8) & 255};#{up & 255}m"
            fg = up
          end
          if lo
            if bg != lo
              out << "\e[48;2;#{(lo >> 16) & 255};#{(lo >> 8) & 255};#{lo & 255}m"
              bg = lo
            end
          elsif bg != -2
            out << "\e[49m"
            bg = -2
          end
          out << '▀'
        elsif lo
          if fg != lo
            out << "\e[38;2;#{(lo >> 16) & 255};#{(lo >> 8) & 255};#{lo & 255}m"
            fg = lo
          end
          if bg != -2
            out << "\e[49m"
            bg = -2
          end
          out << '▄'
        else
          if bg != -2
            out << "\e[49m"
            bg = -2
          end
          out << ' '
        end
        x += 1
      end
      out << "\e[0m"
      out << "\n" if y < half - 1
      y += 1
    end
    out
  end

  def run
    enable_vt
    $stdout.sync = true
    $stdout.write("\e[?25l\e[2J\e[H")
    trap('INT') { @stop = true }
    dt = 1.0 / @fps
    begin
      loop do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        done = false
        until done || @stop
          f0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          t = (f0 - start) / @duration
          t = 1.0 if t >= 1.0
          $stdout.write(render(frame(t)))
          done = t >= 1.0
          spend = Process.clock_gettime(Process::CLOCK_MONOTONIC) - f0
          sleep(dt - spend) if !done && spend < dt
        end
        break if @stop || !@repeat
        k = 0
        while k < 15 && !@stop
          sleep 0.1
          k += 1
        end
      end
    ensure
      $stdout.write("\e[0m\e[?25h\n")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  o = { color: 'red', color2: 'cream', dual: false, size: nil,
        time: 7.0, repeat: false, seed: 11, fps: 30, guard: 5, fullness: 1.0 }
  OptionParser.new do |op|
    op.banner = 'Usage: ruby rose.rb [options]'
    op.on('-c', '--color NAME', 'Main colour, name or hex (default red)') { |v| o[:color] = v }
    op.on('-d', '--dual', 'Double colour mode, petal tips take the second colour') { o[:dual] = true }
    op.on('--color2 NAME', 'Second colour (default cream), implies --dual') { |v| o[:color2] = v; o[:dual] = true }
    op.on('-g', '--guard N', Integer, 'Outer guard petals, 3-8 (default 5)') { |v| o[:guard] = v }
    op.on('--fullness F', Float, 'Inner petal density, 0.4-2.5 (default 1.0)') { |v| o[:fullness] = v }
    op.on('--size N', Integer, 'Canvas size in pixels') { |v| o[:size] = v }
    op.on('--time S', Float, 'Bloom seconds (default 7)') { |v| o[:time] = v }
    op.on('--loop', 'Bloom forever') { o[:repeat] = true }
    op.on('--seed N', Integer, 'Petal layout seed') { |v| o[:seed] = v }
    op.on('--fps N', Integer, 'Frame rate cap (default 30)') { |v| o[:fps] = v }
    op.on('--list', 'List colour names') { puts NAMED_COLORS.keys.join(', '); exit }
    op.on('-h', '--help', 'Show this help') { puts op; exit }
  end.parse!(ARGV)

  cols = 100
  rows = 32
  if IO.respond_to?(:console) && IO.console
    begin
      r, c = IO.console.winsize
      if r.to_i > 1 && c.to_i > 1
        rows = r
        cols = c
      end
    rescue StandardError
    end
  end
  size = o[:size] || [[cols - 2, (rows - 1) * 2, 96].min, 30].max
  size = size.clamp(24, 240)
  size -= size % 2
  padx = [(cols - size) / 2, 0].max

  Rose.new(
    size: size,
    main: parse_color(o[:color]),
    second: parse_color(o[:color2]),
    dual: o[:dual],
    seed: o[:seed],
    duration: [o[:time].to_f, 1.0].max,
    repeat: o[:repeat],
    fps: o[:fps].clamp(5, 60),
    guard: o[:guard],
    fullness: o[:fullness],
    padx: padx
  ).run
end
