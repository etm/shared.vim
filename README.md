# shared.vim

> **AI disclaimer:** This code was created with the assistance of AI. But I
> get what the code does and why it does it. I maybe will not remember it as
> long as if I had done it all manually, spending many moons learning
> Vimscript and how to interact with Vim. Anyway. Its a passion project. Use
> at your own discretion.

Automatic live co-editing for Vim on one machine. Everybody who opens the same
file (same resolved path) edits one shared text; there is nothing to configure
or start.

* A single Ruby server on the Unix socket `/tmp/shared-vim/sock`, shared by all
  local users. The first Vim that needs it starts it detached; it then keeps
  running.
* Every real file buffer joins automatically. Names are `$USERNAME` (else
  `$USER`) + a number per user per file: `alice1`, `bob1`, `alice2` (same
  user twice is fine). Set `USERNAME` when several people share an account.
* All participants are shown in the status line, each in their color, your own
  name first.
* Unsaved text is shown in its author's color. Any `:w` clears all colors in
  everybody's Vim, since the file now holds all the text.
* Per-user undo: `u` and `CTRL-R` (with counts) take back only your own
  changes, even after others edited around them.

Requirements: Vim 9.2 with `+ruby`, `+channel`, `+textprop` (`listener_add()`
with the `text` option); Ruby with `json`.

## Install

```vim
set rtp+=~/Projects/shared.vim
```

or put/link the directory into `~/.vim/pack/shared/start/`. Options:

```vim
let g:shared_vim_socket = '/other/path/sock'  " max ~100 chars
let g:shared_vim_max_size = 10000000          " bytes; bigger files are not shared
```

## Files

| file | role |
|---|---|
| `server/shared-vim-server.rb` | the server (`IO.select` loop, one JSON object per line) |
| `ruby/shared_vim_core.rb` | line model, ops, transform, client state, undo stacks |
| `ruby/shared_vim.rb` | Vim side in Ruby: listener, buffer patching, colors, status |
| `plugin/shared.vim` | autocmds, channel, mappings, swap/timestamp handling |
| `test/selftest.rb` | random tests incl. convergence and undo: `ruby test/selftest.rb` |

## How it works

Operational transformation on character positions, with a dumb server:

* **Server:** holds each document as lines plus the author of every unsaved
  char. It applies an op only if it is based on its current revision, then
  acks the sender and forwards it; otherwise it answers `nack`. No transform,
  no history.
* **Client:** one op in flight, the rest queued. Incoming ops are transformed
  against the queue. On `nack` the op in flight is simply sent again: the ops
  it missed arrived before the `nack` and have already transformed it.
* **Vim:** `listener_add()` reports each change with its resulting lines; it is
  replayed onto the model, so the cost depends on the change, not on the file.
  This also catches changes to buffers that are not current (`:diffput`, LSP
  edits). Remote ops patch only the changed lines, hidden from the listener.
* **Undo:** inverses of your own changes, grouped by Vim's undo step, form a
  stack that every foreign op is transformed through. If another user deleted
  the text around something your undo would restore, that part is dropped,
  so undo never revives text inside a deleted section. An undo step that
  came to nothing (someone removed that text) is skipped with a message, and
  the same keypress goes on to your previous change.

Messages (`t` field): `join`/`joined`, `op`/`ack`/`nack`, `saved`, `leave`,
`peers`.

Vim integration details:

* A swap file of another *running* Vim on this host is ignored (edit anyway);
  a dead one still gets the recovery prompt.
* When a peer writes, the other Vims reload the file quietly and put the shared
  text back on top, so Vim's "changed since reading" checks stay quiet and
  unsaved edits survive. Changes by other programs still warn as usual.
* If the server dies, Vims reconnect after 0.5 s and rejoin with their text.
* Colors use text properties with priority 1000, above semantic highlighting.

## Cost

Per edit, measured in Vim: 0.1 ms in a 100 KB file, 0.3–0.9 ms in a 1 MB file
(position dependent). Joining sends the whole file once.

## Limits (by design, to stay simple)

* Only `u` and `CTRL-R` are per-user; `U`, `g-`, `g+` and `:undo` are Vim's
  own and also take back other people's changes (which is then shared).
* After undoing back to the saved text, the buffer still shows `[+]`.
* Unsaved shared state lives only while somebody has the file open, and colors
  of unsaved text are lost when the server restarts.
* No authentication: any local user can connect to the socket.
* Edits that LSP plugins or other scripts make are shared like your own; text
  props of other plugins on a line a peer just changed may be lost until that
  plugin refreshes them.
