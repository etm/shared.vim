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

# Vim side of shared.vim, loaded with :rubyfile from plugin/shared.vim.
# The model of a buffer is its lines plus a final "" (the last newline).
# Local changes come from listener_add() and are replayed onto the model;
# remote ops are patched into the changed lines, hidden from the listener.
require 'json'
require File.join(VIM.evaluate('g:shared_vim_root'), 'lib', 'shared_vim_core')

module SharedVim
  Core = SharedVimCore
  OT = Core::OT
  TYPES = (0..7).map { |i| "shared_slot#{i}" }
  CTYPES = (0..7).map { |i| "shared_cursor#{i}" }

  # want, reset: cursor / reset message due once no own op is pending;
  # drawn: cursor props shown
  Buf = Struct.new(:nr, :path, :doc, :name, :peers, :listener, :ignore, :want, :drawn, :reset)

  @bufs = {}   # bufnr => Buf
  @paths = {}  # path => bufnr

  class << self
    def u(s) = s.to_s.dup.force_encoding('UTF-8')
    def vs(s) = "'" + s.to_s.gsub("'", "''") + "'"
    def vl(a) = '[' + a.map { |x| vs(x) }.join(',') + ']'
    def cmd(c) = VIM.command(c)
    def ev(e) = VIM.evaluate(e)
    def lines(b) = ev("getbufline(#{b}, 1, '$')").map { |l| u(l) }
    def tx(h) = cmd("call ch_sendraw(g:shared_vim_ch, #{vs(JSON.generate(h))} .. \"\\n\")")

    def safely
      yield
    rescue StandardError => e
      VIM.message("shared.vim: #{e.class}: #{e.message}")
    end

    # --- called from plugin/shared.vim ------------------------------------

    def join(b, path, user)
      return if @bufs[b]
      s = @bufs[b] = Buf.new(b, u(path), nil, nil, [], nil, false)
      @paths[s.path] = b
      tx(t: 'join', path: s.path, user: u(user), lines: lines(b) + [''])
    end

    def leave(b)
      s = @bufs.delete(b) or return
      @paths.delete(s.path)
      unhook(s)
      tx(t: 'leave', path: s.path)
    end

    def reset
      @bufs.each_value { |s| unhook(s) }
      @bufs.clear
      @paths.clear
    end

    # listener_add() callback.
    def changed(b, first, last, added, changes)
      s = @bufs[b] or return
      return if s.ignore || !s.doc
      key = ev("undotree(#{b}).seq_cur")
      begin
        changes.each do |c|
          nl = c['text'].map { |l| u(l) }
          raise 'listener text does not fit' unless nl.size == c['end'] + c['added'] - c['lnum']
          own(s, s.doc.text.replace_op(c['lnum'] - 1, c['end'] - 1, nl), key)
        end
      rescue StandardError
        resync(s)
      end
      render(s, first, last - 1 + added)
      render_cursors(s)
    end

    # :SharedReset, around Vim reloading the file: the difference is shared as
    # a normal edit, then everybody's colors are cleared. The reset message
    # must reach the server after that edit, so it waits for the last ack.
    def reset_start(b)
      s = @bufs[b] or return
      return unless s.doc
      flush(s)
      s.ignore = true
    end

    def reset_end(b)
      s = @bufs[b] or return
      return unless s.doc
      flush(s)
      s.ignore = false
      resync(s)
      clear(s)
      s.reset = true
      send_reset(s)
    end

    def send_reset(s)
      return unless s.reset && s.doc.pending.empty?
      tx(t: 'reset', path: s.path)
      s.reset = false
    end

    # Server of the newest installed gem, if this plugin runs from a gem.
    def newest_server
      Gem::Specification.reset  # a new version may have been installed
      specs = Gem::Specification.find_all_by_name('shared.vim')
      return nil unless specs.any? { |sp| sp.gem_dir == ev('g:shared_vim_root') }
      f = File.join(specs.max_by(&:version).gem_dir, 'tools', 'shared-vim-server')
      File.file?(f) ? f : nil
    end

    # Others with a known cursor: [[name, slot], ...].
    def others(b)
      s = @bufs[b] or return []
      return [] unless s.doc
      (s.peers || []).select { |_, slot| slot != s.doc.slot && s.doc.cursors.key?(slot) }
    end

    # Jump to the cursor of name, or without one to the next cursor after
    # ours in the text (wrapping), so repeating it visits everybody.
    def jump(b, name)
      list = others(b)
      return VIM.message('shared.vim: no other cursor here') if list.empty?
      s = @bufs[b]
      shown = s.doc.shown_cursors
      if name.empty?
        cur = cursor_offset(s) or return
        order = list.map { |_, slot| shown[slot] }.sort
        target = order.find { |p| p > cur } || order.first
      else
        slot = list.find { |n, _| n == name }&.last
        return VIM.message("shared.vim: no cursor of #{name}") unless slot
        target = shown[slot]
      end
      cmd("normal! m'")  # jumplist: CTRL-O goes back
      set_cursor(s, target)
    end

    # Our cursor moved.
    def cursor(b)
      s = @bufs[b] or return
      return unless s.doc
      flush(s)
      pos = cursor_offset(s) or return
      return if pos == s.doc.mine
      s.doc.mine = pos
      send_cursor(s)
    end

    def saved(b)
      s = @bufs[b] or return
      return unless s.doc
      flush(s)
      tx(t: 'saved', path: s.path)
      clear(s)
    end

    # Vim reloads after a peer's write: hide that from the listener until
    # restore() has put the shared text back.
    def before_reload(b)
      s = @bufs[b] or return
      flush(s)
      s.ignore = true
    end

    def restore(b)
      s = @bufs[b] or return
      flush(s)
      write_all(s)
      flush(s)
    ensure
      s.ignore = false if s
    end

    # Per-user undo, redo with forward = true.
    def undo(b, count, forward)
      s = @bufs[b] or return
      return unless s.doc
      flush(s)
      skipped = 0
      count.times do
        idle = s.doc.pending.empty?
        done, n = s.doc.undo!(forward)
        skipped += n
        unless done
          VIM.message(forward ? 'Already at newest change' : 'Already at oldest change')
          break
        end
        send_op(s) if idle && !s.doc.pending.empty?
        quietly(s) { done.each { |_, region, size| patch(s, size, region) } }
        set_cursor(s, OT.first_change(done[0][0]))
      end
      render_cursors(s)
      VIM.message("shared.vim: skipped #{skipped} change#{'s' if skipped > 1} removed by someone else") if skipped > 0
    end

    def recv(line)
      m = JSON.parse(u(line))
      b = @paths[m['path']] or return
      s = @bufs[b]
      if m['t'] == 'denied'
        @bufs.delete(b)
        @paths.delete(s.path)
        return VIM.message("shared.vim: #{File.basename(s.path)} not shared, no permission")
      end
      case m['t']
      when 'joined' then joined(s, m)
      when 'ack'
        send_op(s) if s.doc.ack
        send_reset(s)
        send_cursor(s) if s.want
      when 'nack' then send_op(s) if s.doc.nack
      when 'cnack' then send_cursor(s) if s.doc.mine
      when 'op' then remote(s, m['op'], m['slot'])
      when 'cursor'
        s.doc.cursor(m['slot'], m['pos'])
        render_cursors(s)
      when 'saved'
        clear(s)
        cmd("call setbufvar(#{b}, 'shared_vim_peer_saved', 1)")
        cmd("call SharedVimSyncTime(#{b})")
      when 'reset' then clear(s)
      when 'peers'
        s.peers = m['peers']
        if s.doc
          slots = s.peers.map { |_, slot| slot }
          s.doc.cursors.select! { |slot, _| slots.include?(slot) }
          render_cursors(s)
        end
      end
      status(s)
    end

    # --- internals ----------------------------------------------------------

    def joined(s, m)
      text = Core::Text.new(m['lines'], m['authors'])
      s.doc = Core::Doc.new(text, m['rev'], m['slot'])
      s.name = m['name']
      if m['created'] then resync(s)  # typing between join and reply
      else write_all(s)
      end
      own(s, text.normalize_op)
      s.listener = ev("listener_add('SharedVimListener', #{s.nr}, {'text': v:true})")
      cmd("call setbufvar(#{s.nr}, 'shared_vim_on', 1)")
      render(s, 1, text.lines.size - 1)
      (m['cursors'] || []).each { |slot, pos| s.doc.cursor(slot, pos) }
      render_cursors(s)
      cursor(s.nr)
    end

    def unhook(s)
      cmd("call listener_remove(#{s.listener})") if s.listener
      cmd("call prop_remove({'bufnr': #{s.nr}, 'types': #{vl(CTYPES)}, 'all': 1})") if s.drawn
      cmd("call setbufvar(#{s.nr}, 'shared_vim_on', 0)")
      cmd("call setbufvar(#{s.nr}, 'shared_vim_status', '')")
    end

    def send_op(s) = tx(t: 'op', path: s.path, rev: s.doc.rev, op: s.doc.pending.first)

    # A position belongs to one revision. Without pending ops our text is the
    # server's at our rev; otherwise it waits for the last ack. The server
    # answers cnack if it is further, and the ops we lack arrive before that.
    def send_cursor(s)
      if s.doc.pending.empty?
        tx(t: 'cursor', path: s.path, rev: s.doc.rev, pos: s.doc.mine)
        s.want = false
      else
        s.want = true
      end
    end

    # Own op that the buffer already shows (key: undo group). Sends it.
    def own(s, op, key = nil)
      region = s.doc.own(op, key)
      send_op(s) if region && s.doc.pending.size == 1
      region
    end

    def remote(s, op, slot)
      flush(s)  # unreported local changes must be in the model first
      cur = cursor_offset(s)
      old_size = s.doc.text.lines.size
      op, region = s.doc.remote(op, slot)
      region = Core::Region.merge(region, own(s, s.doc.text.normalize_op))
      quietly(s) { patch(s, old_size, region) }
      set_cursor(s, OT.xform_index(op, cur)) if cur
      render_cursors(s)
    end

    def flush(s) = cmd("call listener_flush(#{s.nr})")

    # Change the buffer without the listener reporting it.
    def quietly(s)
      flush(s)
      s.ignore = true
      yield
      flush(s)
    ensure
      s.ignore = false
    end

    # Model lines [lo, lo+old) became [lo, lo+new); the buffer is the model
    # without its final "".
    def patch(s, old_size, region)
      return unless region
      lo, oc, nc = region
      t = s.doc.text
      ob = [lo + oc, old_size - 1].min - lo
      nb = [lo + nc, t.lines.size - 1].min - lo
      nl = t.lines[lo, nb]
      c = [ob, nb].min
      cmd("call setbufline(#{s.nr}, #{lo + 1}, #{vl(nl[0, c])})") if c > 0
      cmd("call appendbufline(#{s.nr}, #{lo + c}, #{vl(nl[c..])})") if nb > ob
      cmd("silent call deletebufline(#{s.nr}, #{lo + c + 1}, #{lo + ob})") if ob > nb
      render(s, lo + 1, lo + nb)
    end

    # Differing middle part of buffer and model: [buffer lines, pre, suf].
    def compare(s)
      bl = lines(s.nr)
      ml = s.doc.text.lines[0..-2]
      pre, suf = 0, 0
      pre += 1 while pre < bl.size && pre < ml.size && bl[pre] == ml[pre]
      suf += 1 while suf < bl.size - pre && suf < ml.size - pre && bl[-1 - suf] == ml[-1 - suf]
      [bl, pre, suf]
    end

    # Make the buffer show the model, touching only differing lines.
    def write_all(s)
      bl, pre, suf = compare(s)
      patch(s, bl.size + 1, [pre, bl.size - pre - suf, s.doc.text.lines.size - 1 - pre - suf])
    end

    # Buffer and model differ in an unknown way: send the difference.
    def resync(s)
      bl, pre, suf = compare(s)
      own(s, s.doc.text.replace_op(pre, s.doc.text.lines.size - 1 - suf, bl[pre, bl.size - pre - suf]))
      render(s, pre + 1, bl.size - suf)
    end

    def cursor_offset(s)
      return nil unless ev('bufnr()') == s.nr
      ln = ev("line('.')")
      line = s.doc.text.lines[ln - 1] or return nil
      s.doc.text.offset(ln - 1) + u(line.b.byteslice(0, ev("col('.')") - 1)).scrub.length
    end

    def set_cursor(s, off)
      return unless ev('bufnr()') == s.nr
      t = s.doc.text
      l, c = t.locate([off, t.length].min)
      l = [l, t.lines.size - 2].min
      cmd("call cursor(#{l + 1}, #{t.lines[l][0, c].to_s.bytesize + 1})")
    end

    # Color lines first..last by author, one prop_add_list() per color.
    def render(s, first, last)
      t = s.doc.text
      first = [first, 1].max
      last = [last, t.lines.size - 1].min
      return if last < first
      cmd("call prop_remove({'bufnr': #{s.nr}, 'types': #{vl(TYPES)}, 'all': 1}, #{first}, #{last})")
      items = Hash.new { |h, k| h[k] = [] }
      (first..last).each do |ln|
        line = t.lines[ln - 1]
        col = 1  # byte column
        i = 0
        t.authors[ln - 1].each do |slot, n|
          b = line[i, n].bytesize
          items[slot % 8] << [ln, col, ln, col + b] if slot
          col += b
          i += n
        end
      end
      items.each do |k, v|
        cmd("call prop_add_list({'bufnr': #{s.nr}, 'type': '#{TYPES[k]}'}, #{v})")
      end
    end

    # Other users' cursors in the color of their name. At a line end there is
    # no char to color, a virtual space stands in.
    def render_cursors(s)
      cmd("call prop_remove({'bufnr': #{s.nr}, 'types': #{vl(CTYPES)}, 'all': 1})") if s.drawn
      t = s.doc.text
      s.drawn = !s.doc.cursors.empty?
      s.doc.shown_cursors.each do |slot, pos|
        l, c = t.locate([pos, t.length].min)
        if l > t.lines.size - 2  # after the final newline
          l = [t.lines.size - 2, 0].max
          c = t.lines[l].length
        end
        line = t.lines[l]
        opts = "'bufnr': #{s.nr}, 'type': '#{CTYPES[slot % 8]}', " +
               (c < line.length ? "'length': #{line[c].bytesize}" : "'text': ' '")
        cmd("call prop_add(#{l + 1}, #{line[0, c].bytesize + 1}, {#{opts}})")
      end
    end

    def clear(s)
      s.doc.text.saved!
      cmd("call prop_remove({'bufnr': #{s.nr}, 'types': #{vl(TYPES)}, 'all': 1})")
      cmd("call setbufvar(#{s.nr}, '&modified', 0)")
    end

    def status(s)
      peers = (s.peers || []).sort_by { |n, _| n == s.name ? 0 : 1 }
      str = peers.map { |n, slot| "%#SharedStat#{slot % 8}# #{n} %*" }.join(' ')
      cmd("call setbufvar(#{s.nr}, 'shared_vim_status', #{vs(str)})")
      cmd('redrawstatus!')
    end
  end
end
