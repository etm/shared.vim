#!/usr/bin/env ruby
# Random self-test of the core. Run: ruby test/selftest.rb
require_relative '../lib/shared_vim_core'
include SharedVimCore

ALPHA = %w[a b ä € x] + ["\n"]
def rnd_str(n) = Array.new(n) { ALPHA.sample }.join
def rnd_lines(n) = Array.new(n) { rnd_str(rand(0..4)).delete("\n") }
def doc(t) = t.lines.join("\n")

# A random edit of a client, the way Vim's listener reports it.
def rnd_edit(t, insert_only: false)
  n = t.lines.size - 1                     # buffer lines (model has a final "")
  a = rand(0..n)
  e = insert_only ? a : rand(a..[a + 2, n].min)
  old = t.lines[a...e]
  nl = rnd_lines(rand(0..2))
  if insert_only && a < n                  # insert some chars into one line
    l = t.lines[a].dup
    l.insert(rand(0..l.length), rnd_str(rand(1..3)).delete("\n"))
    return t.replace_op(a, a + 1, [l])
  end
  t.replace_op(a, e, insert_only ? nl.reject(&:empty?) : nl) || (old.empty? ? nil : nil)
end

# 1. line model
3000.times do
  t = Text.new(rnd_lines(rand(0..5)) + [''])
  before = doc(t)
  authors = t.authors.map(&:dup)
  a = rand(0..t.lines.size - 1)
  e = rand(a..t.lines.size - 1)
  nl = rnd_lines(rand(0..3))
  expect = (t.lines[0...a] + nl + t.lines[e..]).join("\n")
  op = t.replace_op(a, e, nl) or next
  inv, = t.apply(op, 7)
  raise "replace #{before.inspect} #{a}...#{e} #{nl.inspect}: #{doc(t).inspect}" unless doc(t) == expect
  raise 'length' unless t.length == expect.length
  raise 'authors shape' unless t.authors.zip(t.lines).all? { |a, l| a.sum { |_, n| n } <= l.length && Text.compact(a) == a }
  t.apply(inv, nil)
  raise "inverse: #{doc(t).inspect} != #{before.inspect}" unless doc(t) == before && t.authors == authors
end

# 1b. author runs match a per-char reference ("\n" has no author)
def flat(t)
  t.lines.each_with_index.flat_map do |l, i|
    a = t.authors[i].flat_map { |s, n| [s] * n }
    a += [nil] * (l.length - a.size)
    i == 0 ? a : [nil] + a
  end
end
1000.times do
  t = Text.new(rnd_lines(rand(0..5)) + [''])
  ref = flat(t)
  20.times do
    op = rnd_edit(t) or next
    slot = [nil, 0, 1, 2].sample
    pos = 0
    op.each do |c|
      if c.is_a?(String) then ref[pos, 0] = [slot] * c.length; pos += c.length
      elsif c > 0 then pos += c
      else ref[pos, -c] = []
      end
    end
    t.apply(op, slot)
    doc(t).each_char.with_index { |ch, i| ref[i] = nil if ch == "\n" }
    raise "runs: #{t.authors.inspect} vs #{ref.inspect}" unless flat(t) == ref && t.authors.all? { |a| Text.compact(a) == a }
  end
end

# Simulation: server rejects ops based on an old revision.
def simulate(rounds, start, undo_by: nil)
  server = Text.new(start.dup)
  srev = 0
  clients = Array.new(3) { |i| Doc.new(Text.new(start.dup), 0, i) }
  up = Array.new(3) { [] }
  down = Array.new(3) { [] }
  send = ->(i) { up[i] << [clients[i].rev, clients[i].pending.first] }
  step = lambda do |allow_edits, &edit|
    i = rand(3)
    case rand(3)
    when 0
      return unless allow_edits
      d = clients[i]
      idle = d.pending.empty?
      edit.(i, d)
      send.(i) if idle && d.pending.any?
    when 1
      return if up[i].empty?
      rev, op = up[i].shift
      if rev == srev
        server.apply(op, i)
        srev += 1
        3.times { |j| down[j] << (j == i ? [:ack] : [:op, op, i]) }
      else
        down[i] << [:nack]
      end
    when 2
      return if down[i].empty?
      m = down[i].shift
      d = clients[i]
      case m[0]
      when :ack then send.(i) if d.ack
      when :nack then send.(i) if d.nack
      else d.remote(m[1], m[2])
      end
    end
  end
  drain = -> { step.(false) {} until up.all?(&:empty?) && down.all?(&:empty?) }
  rounds.times { step.(true) { |i, d| yield(i, d) } }
  drain.()
  if undo_by
    d = clients[undo_by]
    idle = d.pending.empty?
    true while d.undo![0]
    send.(undo_by) if idle && d.pending.any?
    drain.()
  end
  [server, clients]
end

# 2. convergence of 3 clients, random message delays
300.times do |round|
  server, clients = simulate(60, rnd_lines(rand(0..4)) + ['']) do |_, d|
    d.own(rnd_edit(d.text), rand(1000))
  end
  clients.each_with_index do |c, i|
    raise "round #{round}: client #{i} #{doc(c.text).inspect} != #{doc(server).inspect}" unless doc(c.text) == doc(server)
    raise "round #{round}: client #{i} authors differ" unless c.text.authors == server.authors
  end
end

# 3. undoing all of client 0's inserts removes exactly its text
300.times do |round|
  start = rnd_lines(rand(1..4)) + ['']
  server, clients = simulate(60, start, undo_by: 0) do |i, d|
    d.own(rnd_edit(d.text, insert_only: i == 0), "k#{rand(1000)}")
  end
  clients.each { |c| raise "undo round #{round}: diverged" unless doc(c.text) == doc(server) }
  raise "undo round #{round}: client 0 text left" if server.authors.any? { |a| a.any? { |s, _| s == 0 } }
end

# 3b. same with mixed edits: still converges
300.times do |round|
  server, clients = simulate(60, rnd_lines(rand(1..4)) + [''], undo_by: 0) do |_, d|
    d.own(rnd_edit(d.text), "k#{rand(1000)}")
  end
  clients.each { |c| raise "mixed undo round #{round}: diverged" unless doc(c.text) == doc(server) && c.text.authors == server.authors }
end

# 4. alone, undo restores the start exactly (nothing dropped)
300.times do |round|
  start = rnd_lines(rand(1..4)) + ['']
  d = Doc.new(Text.new(start.dup), 0, 0)
  20.times { |k| d.own(rnd_edit(d.text), k) }
  true while d.undo![0]
  raise "alone round #{round}: #{doc(d.text).inspect} != #{start.join("\n").inspect}" unless doc(d.text) == start.join("\n")
  true while d.undo!(true)[0]
  true while d.undo![0]
  raise "alone redo round #{round}" unless doc(d.text) == start.join("\n")
end

# 5. A edits, B deletes around it, A undoes
def pair(start)
  a = Doc.new(Text.new(start.dup), 0, 0)
  b = Doc.new(Text.new(start.dup), 0, 1)
  sync = ->(from, to) { to.remote(from.pending.first, from.slot); from.ack }
  [a, b, sync]
end
a, b, sync = pair(['x  y', ''])                 # A types foo, B deletes it
a.own(a.text.replace_op(0, 1, ['x foo y']), 1); sync.(a, b)
b.own(b.text.replace_op(0, 1, ['x  y']), 2); sync.(b, a)
done, skipped = a.undo!
raise 'case 1: expected a skipped group' unless done.nil? && skipped == 1
a, b, sync = pair(['foo bar baz', 'next', ''])  # A deletes bar, B deletes the line
a.own(a.text.replace_op(0, 1, ['foo  baz']), 1); sync.(a, b)
b.own(b.text.replace_op(0, 1, []), 2); sync.(b, a)
done, skipped = a.undo!
raise "case 3: #{doc(a.text).inspect}" unless done.nil? && skipped == 1 && doc(a.text) == "next\n"
a, b, sync = pair(['foo bar baz', ''])          # B deletes only " baz": keep the undo
a.own(a.text.replace_op(0, 1, ['foo  baz']), 1); sync.(a, b)
b.own(b.text.replace_op(0, 1, ['foo ']), 2); sync.(b, a)
a.undo!
raise "neighbour kept: #{doc(a.text).inspect}" unless doc(a.text) == "foo bar\n"

# 6. cursor mapping
raise 'xform' unless OT.xform_index([2, 'XY', 3], 3) == 5
raise 'xform' unless OT.xform_index([1, -2, 2], 2) == 1

puts 'selftest ok'
