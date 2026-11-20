# This file is part of shared.vim.
#
# shared.vim is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# shared.vim is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# shared.vim (file LICENSE in the main directory). If not, see
# <http://www.gnu.org/licenses/>.

# Pure-Ruby core shared by the server, the Vim client and the self-test.
#
# A document is held as lines, exactly doc.split("\n", -1): a document ending
# in "\n" has a final "" element. An operation (op) covers the whole document
# and is an Array of:
#   Integer > 0  retain that many chars
#   Integer < 0  delete that many chars
#   String       insert it
# Positions are characters, not bytes; "\n" counts as one.

require 'etc'

module SharedVimCore
  module OT
    module_function

    def push(op, c)
      return op if c == 0 || c == ''
      last = op[-1]
      if c.is_a?(String)
        last.is_a?(String) ? op[-1] = last + c : op << c
      elsif c > 0
        last.is_a?(Integer) && last > 0 ? op[-1] += c : op << c
      else
        last.is_a?(Integer) && last < 0 ? op[-1] += c : op << c
      end
      op
    end

    # Returns [a', b'] with a then b' == b then a'. On equal positions the
    # insert of a goes first.
    # undo: a is an undo entry; its inserts into text that b deleted on both
    # sides (or at the document's start/end) are dropped, b' deletes them.
    def transform(a, b, undo: false)
      a1 = []
      b1 = []
      ia = ib = 0
      ca = a[0]
      cb = b[0]
      before = :start  # what b did to the char before the current position
      until ca.nil? && cb.nil?
        if ca.is_a?(String)
          after = cb.nil? ? :end : cb.is_a?(String) ? :ins : cb < 0 ? :del : :keep
          if undo && before != :keep && %i[end del].include?(after) && (before == :del || after == :del)
            push(b1, -ca.length)
          else
            push(a1, ca); push(b1, ca.length)
          end
          ca = a[ia += 1]
          next
        end
        if cb.is_a?(String)
          push(a1, cb.length); push(b1, cb)
          cb = b[ib += 1]
          before = :keep
          next
        end
        raise ArgumentError, 'transform: ops of different length' if ca.nil? || cb.nil?
        m = [ca.abs, cb.abs].min
        if ca > 0 && cb > 0 then push(a1, m); push(b1, m)
        elsif ca < 0 && cb > 0 then push(a1, -m)
        elsif ca > 0 && cb < 0 then push(b1, -m)
        end
        before = cb < 0 ? :del : :keep
        ca = ca > 0 ? ca - m : ca + m
        ca = a[ia += 1] if ca == 0
        cb = cb > 0 ? cb - m : cb + m
        cb = b[ib += 1] if cb == 0
      end
      [a1, b1]
    end

    # Where char index idx of the old document ends up after op.
    def xform_index(op, idx)
      pos = 0
      res = idx
      op.each do |c|
        break if pos > idx
        if c.is_a?(String) then res += c.length
        elsif c > 0 then pos += c
        else res -= [-c, idx - pos].min; pos -= c
        end
      end
      res
    end

    def noop?(op) = op.all? { |c| c.is_a?(Integer) && c > 0 }

    # Char position of the first change.
    def first_change(op) = op[0].is_a?(Integer) && op[0] > 0 ? op[0] : 0
  end

  # Changed line region: model lines [lo, lo + old) became [lo, lo + new).
  module Region
    module_function

    # r2 applies after r1.
    def merge(r1, r2)
      return r2 unless r1
      return r1 unless r2
      lo = [r1[0], r2[0]].min
      hi = [r1[0] + r1[2], r2[0] + r2[1]].max
      [lo, hi - lo - r1[2] + r1[1], hi - lo - r2[1] + r2[2]]
    end
  end

  # Lines plus, per line, the authors as runs [[slot, count], ...] (slot nil =
  # saved text). Runs are compact: no empty runs, equal neighbours merged, no
  # trailing nil run; chars past the last run are saved text.
  class Text
    attr_reader :lines, :authors, :length

    EMPTY = [].freeze

    def initialize(lines, authors = nil)
      @lines = lines.empty? ? [''] : lines
      @authors = authors ? authors.map { |a| Text.compact(a) } : Array.new(@lines.size, EMPTY)
      @lens = @lines.map(&:length)  # summing Integers is fast, see offset
      @length = @lens.sum + @lines.size - 1
    end

    def offset(line) = @lens[0, line].sum + line

    # [line index, column] of char position pos (binary search).
    def locate(pos)
      raise ArgumentError, "position #{pos} beyond end (#{@length})" if pos > @length
      lo = 0
      hi = @lines.size - 1
      while lo < hi
        mid = (lo + hi) / 2
        if offset(mid) + @lens[mid] >= pos then hi = mid
        else lo = mid + 1
        end
      end
      [lo, pos - offset(lo)]
    end

    # Replace del chars at pos by ins. Returns [region, deleted text].
    def splice(pos, del, ins, slot)
      l1, c1 = locate(pos)
      l2, = locate(pos + del)
      seg = @lines[l1..l2].join("\n")
      q = []  # runs of seg, padded to full length; "\n" is always nil
      (l1..l2).each do |l|
        q << [nil, 1] if l > l1
        q.concat(@authors[l].map(&:dup))
        rest = @lens[l] - @authors[l].sum { |_, n| n }
        q << [nil, rest] if rest > 0
      end
      deleted = seg[c1, del]
      nseg = seg[0, c1] + ins + seg[(c1 + del)..]
      head = Text.take(q, c1)
      Text.take(q, del)
      q = head + [[slot, ins.length]] + q
      nlines = nseg.empty? ? [''] : nseg.split("\n", -1)
      nauth = nlines.each_with_index.map do |l, i|
        Text.take(q, 1) if i > 0
        Text.compact(Text.take(q, l.length))
      end
      @lines[l1..l2] = nlines
      @authors[l1..l2] = nauth
      @lens[l1..l2] = nlines.map(&:length)
      @length += ins.length - del
      [[l1, l2 - l1 + 1, nlines.size], deleted]
    end

    # Apply op, new text by slot. Returns [inverse op, changed line region].
    def apply(op, slot)
      total = op.sum { |c| c.is_a?(String) ? 0 : c.abs }
      raise ArgumentError, "op covers #{total} chars, text has #{@length}" unless total == @length
      pos = 0
      inv = []
      region = nil
      op.each do |c|
        if c.is_a?(String)
          r, = splice(pos, 0, c, slot)
          region = Region.merge(region, r)
          OT.push(inv, -c.length)
          pos += c.length
        elsif c > 0
          OT.push(inv, c)
          pos += c
        else
          r, deleted = splice(pos, -c, '', slot)
          region = Region.merge(region, r)
          OT.push(inv, deleted)
        end
      end
      [inv, region]
    end

    # Op replacing lines [a, e) by nl, trimmed to the changed chars; nil if
    # equal. A line must follow e (the final "" always does).
    def replace_op(a, e, nl)
      raise ArgumentError, "lines #{a}...#{e} out of range" unless a <= e && e < @lines.size
      off = offset(a)
      oc = @lines[a...e].map { |l| l + "\n" }.join.chars
      nc = nl.map { |l| l + "\n" }.join.chars
      p = 0
      p += 1 while p < oc.size && p < nc.size && oc[p] == nc[p]
      q = 0
      q += 1 while q < oc.size - p && q < nc.size - p && oc[-1 - q] == nc[-1 - q]
      return nil if p == oc.size && p == nc.size
      del = oc.size - p - q
      op = []
      OT.push(op, off + p)
      OT.push(op, -del)
      OT.push(op, nc[p, nc.size - p - q].join)
      OT.push(op, @length - off - p - del)
    end

    # Vim always shows a final newline; keep the model ending in one.
    def normalize_op = @lines.last == '' && @lines.size > 1 ? nil : OT.push([@length], "\n")

    # Everything written: no unsaved authors left.
    def saved! = @authors.fill(EMPTY)

    # Remove the first n chars from runs q (modified in place), return them.
    def self.take(q, n)
      out = []
      while n > 0 && (r = q.first)
        k = [r[1], n].min
        out << [r[0], k]
        n -= k
        r[1] -= k
        q.shift if r[1] == 0
      end
      out
    end

    def self.compact(runs)
      out = []
      runs.each do |s, n|
        next if n == 0
        if out.last && out.last[0] == s then out[-1] = [s, out.last[1] + n]
        else out << [s, n]
        end
      end
      out.pop if out.last && out.last[0].nil?
      out.empty? ? EMPTY : out
    end
  end

  # File permissions of some user, as the server sees them: the mode bits of
  # owner, group (incl. supplementary groups) and others. ACLs are ignored.
  module Access
    module_function

    # May uid read path (an existing file) or create it (a new one)? Every
    # directory on the way must be searchable. nil if this process cannot
    # tell, e.g. a file in a private home directory of another account.
    def allowed?(uid, path)
      return true if uid == 0
      dir = File.dirname(path)
      dirs = [dir]
      dirs << (dir = File.dirname(dir)) until dir == '/'
      return false unless dirs.all? { |d| can?(uid, File.stat(d), 1) }
      if File.exist?(path) then can?(uid, File.stat(path), 4)
      else can?(uid, File.stat(File.dirname(path)), 3)
      end
    rescue SystemCallError
      nil
    end

    # bits: 4 read, 2 write, 1 search. As in Unix, only the first class that
    # applies counts: an owner without read permission may not read.
    def can?(uid, st, bits)
      shift = if st.uid == uid then 6
              elsif groups(uid).include?(st.gid) then 3
              else 0
              end
      (st.mode >> shift) & bits == bits
    end

    def groups(uid)
      (@groups ||= {})[uid] ||= begin
        pw = Etc.getpwuid(uid)
        [pw.gid] + Etc.enum_for(:group).select { |g| g.mem.include?(pw.name) }.map(&:gid)
      rescue ArgumentError
        []
      end
    end
  end

  # Client side of one shared document: one op in flight, the rest queued.
  # undo/redo: [key, ops] groups, newest first. All their ops form one
  # sequence starting at the current text, so every op that is not recorded
  # (remote ops, normalizations) is transformed through them.
  class Doc
    attr_reader :text, :rev, :pending, :slot, :undo, :redo, :cursors
    attr_accessor :mine  # own cursor position, nil until known

    def initialize(text, rev, slot)
      @text = text
      @rev = rev
      @slot = slot
      @pending = []
      @undo = []
      @redo = []
      @groups = 0
      # Cursors of others, slot => char position in the server's text. They
      # move with the ops in the server's order, exactly as on the server:
      # other orders can end differently (an insert at a collapsed delete).
      @cursors = {}
    end

    # Own op. Returns [inverse, region].
    def local(op)
      res = @text.apply(op, @slot)
      @pending << op
      @mine = OT.xform_index(op, @mine) if @mine
      res
    end

    def cursor(slot, pos) = @cursors[slot] = pos

    # Cursors of others in our text, i.e. after our pending ops.
    def shown_cursors = @cursors.transform_values { |p| @pending.reduce(p) { |q, op| OT.xform_index(op, q) } }

    def move_cursors(op) = @cursors.transform_values! { |p| OT.xform_index(op, p) }

    # Own op; recorded for undo under key (an undo group), else not undoable.
    # Returns the region, nil for a no-op.
    def own(op, key = nil)
      return nil if op.nil? || OT.noop?(op)
      inv, region = local(op)
      if key
        if @undo[0] && @undo[0][0] == key then @undo[0][1].unshift(inv)
        else @undo.unshift([key, [inv]])
        end
        @redo.clear
      else
        move_stacks(op)
      end
      region
    end

    # Undo (or redo) the newest group, skipping groups that others emptied.
    # Returns [[op, region, line count before]... or nil, skipped count].
    def undo!(forward = false)
      from, to = forward ? [@redo, @undo] : [@undo, @redo]
      skipped = 0
      while (entry = from.shift)
        ops = entry[1].reject { |e| OT.noop?(e) }
        if ops.empty?
          skipped += 1
          next
        end
        group = []
        done = ops.map do |e|
          size = @text.lines.size
          inv, region = local(e)
          group.unshift(inv)
          [e, region, size]
        end
        to.unshift([:"g#{@groups += 1}", group])
        return [done, skipped]
      end
      [nil, skipped]
    end

    def move_stacks(op)
      [@undo, @redo].each do |stack|
        stack.map! { |key, ops| [key, ops.map { |e| e1, op = OT.transform(e, op, undo: true); e1 }] }
      end
    end

    # Server applied our op in flight. Returns the next op to send, or nil.
    def ack
      move_cursors(@pending.shift)
      @rev += 1
      @pending.first
    end

    # Resend: the ops we missed arrived before the nack and transformed it.
    def nack = @pending.first

    # Op of somebody else. Returns [op transformed for our text, region].
    def remote(op, slot)
      move_cursors(op)
      @pending.map! { |p| p1, op = OT.transform(p, op); p1 }
      @rev += 1
      _, region = @text.apply(op, slot)
      @mine = OT.xform_index(op, @mine) if @mine
      move_stacks(op)
      [op, region]
    end
  end
end
