# shared.vim

> **AI disclaimer:** This code was created with the assistance of AI. But I
> get what the code does and why it does it. I maybe will not remember it as
> long as if I had done it all manually, spending many moons learning
> Vimscript and how to interact with Vim internals. Anyway. Its a passion
> project. Use at your own discretion.

Live co-editing for Vim on one machine. Everybody who opens the same
file (same resolved path) edits one shared text; there is nothing to configure
or start.

* A single Ruby server on the Unix socket `/tmp/shared-vim/sock`, shared by all
  local users. The first Vim that needs it starts it detached; it exits 60 s
  after the last Vim has disconnected.
* Every real file buffer joins automatically. Names are `$USERNAME` (else
  `$USER`) + a number per user per file: `alice1`, `bob1`, `alice2` (same
  user twice is fine). Set `USERNAME` when several people share an account.
* All participants are shown in the status line, each in their color, your own
  name first.
* Unsaved text is shown in its author's color. Any `:w` clears all colors in
  everybody's Vim, since the file now holds all the text.
* Per-user undo: `u` and `CTRL-R` (with counts) take back only your own
  changes, even after others edited around them.

## Why this one

Most collaborative-editing plugins are built for working over a network: one
person starts or hosts a session, the others join it by address. shared.vim is
for the other case: you, or you and your friends, on the same computer, for
example several ssh logins to one server.

* **Nothing to set up or start.** No session, no host, no port, no join
  command. Open a file, and if somebody else has it open, you edit together.
* **No network.** Everything goes through a Unix domain socket on the local
  machine; nothing is exposed to other hosts.
* **You see who is there.** Everybody who has the file open is in the status
  line, unsaved text is in its author's color, and the same person may have a
  file open multiple times.
* **Per-user undo.** `u` takes back only your own changes, and never revives
  text that somebody else has deleted in the meantime.
* **Plain Vim.** Most current projects are Neovim only.

## Requirements

Vim 9.2 with `+ruby`, `+channel`, `+textprop` (`listener_add()`
with the `text` option); Ruby with `json`.

Neovim is not supported at this point: it lacks `listener_add()`, text
properties, Vim channels and the built-in `:ruby`.

A and I would need to port the whole affair to LUA to share
max code between vim and neovim. Lets do that when people want it.

## Install

```sh
gem install shared.vim
shared-vim-install
```

`shared-vim-install` writes a small stub plugin to
`~/.vim/pack/shared/start/shared.vim/plugin/shared.vim` (another Vim directory
can be given as argument). At each start the stub asks RubyGems for the newest
installed `shared.vim` gem and loads the plugin from there, so nothing has to be
added to the vimrc and gem updates need no reinstall. Vim's Ruby must see the
gems, i.e. be the same Ruby that `gem` installs for. To uninstall, delete the
stub and `gem uninstall shared.vim`.

From a checkout instead:

```vim
set rtp+=~/Projects/shared.vim
```

Options:

```vim
let g:shared_vim_socket = '/other/path/sock'  " max ~100 chars
let g:shared_vim_max_size = 10000000          " bytes; bigger files are not shared
```

## Files

| file | role |
|---|---|
| `tools/shared-vim-server` | the server (`IO.select` loop, one JSON object per line) |
| `tools/shared-vim-install` | installs the stub plugin that loads the gem |
| `lib/shared_vim_core.rb` | line model, ops, transform, client state, undo stacks |
| `lib/shared_vim.rb` | Vim side in Ruby: listener, buffer patching, colors, status |
| `plugin/shared.vim` | autocmds, channel, mappings, swap/timestamp handling |
| `test/test.rb` | random tests incl. convergence and undo: `rake test` |

`rake` builds the gem into `pkg/`, `rake install` installs it.

## How it works

Operational transformation on character positions, with a dumb server:

* **Server:** holds each open document in memory, as lines plus, per line, the
  authors of unsaved text as runs (slot, length). It applies an op only if it is based on its current revision, then
  acks the sender and forwards it; otherwise it answers `nack`. No transform,
  no history.
* **Client:** one op in flight, the rest queued. Incoming ops are transformed
  against the queue. On `nack` the op in flight is simply sent again: the ops
  it missed arrived before the `nack` and have already transformed it.
* **Vim:** `listener_add()` reports each change with its resulting lines; it is
  replayed onto the model, so the cost depends on the change, not on the file.
  This also catches changes to buffers that are not current (`:diffput`, and
  presumably edits by LSP plugins, untested). Remote ops patch only the changed lines, hidden from the listener.
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
  unsaved edits survive. Changes by other programs still warn as usual. A file
  that did not exist when editing started is reloaded with `:edit!` instead
  (Vim's W13 warning has no hook), once it is visible and not in insert mode.
* If the server dies, Vims reconnect after 0.5 s. The first to rejoin brings
  its text; the others take over the server's text, so their edits not yet
  sent are lost.
* Colors use text properties with priority 1000, meant to stay above semantic
  highlighting of LSP plugins (untested).

## Cost

Per edit, measured in Vim: 0.1 ms in a 100 KB file, 0.3–0.9 ms in a 1 MB file
(position dependent). Joining sends the whole file once.

Memory: the server and every Vim that has the file open each keep a model of
it, about twice the file size (1 MB file: 2 MB, 10 MB file: 23 MB).

## Related projects

If you need editing over a network, or Neovim, one of these may fit better:

* [CoVim](https://github.com/FredKSchott/CoVim): Vim, Python/Twisted, a
  server you start and connect to.
* [instant.nvim](https://github.com/jbyuki/instant.nvim): Neovim, Lua, built-in
  server, virtual cursors; no longer maintained.
* [livecode.nvim](https://github.com/jxm35/livecode.nvim): Neovim, Lua,
  operational transformation, local or LAN server.
* [live-share.nvim](https://github.com/azratul/live-share.nvim): Neovim, Lua,
  session sharing.
* [Floobits](https://github.com/Floobits/vim-plugin): Vim/Neovim, hosted
  service.
* [tandem](https://github.com/typeintandem/vim): Vim and other editors,
  peer-to-peer.
* [Ethersync](https://github.com/ethersync/ethersync): editor-independent
  sync tool with plugins for several editors.

## Limits (by design, to stay simple)

* Only `u` and `CTRL-R` are per-user; `U`, `g-`, `g+` and `:undo` are Vim's
  own and also take back other people's changes (which is then shared).
* After undoing back to the saved text, the buffer still shows `[+]`.
* Unsaved shared state lives only while somebody has the file open, and colors
  of unsaved text are lost when the server restarts.
* No authentication: any local user can connect to the socket.
* The size limit (`g:shared_vim_max_size`) is checked only by each Vim; the
  server accepts files of any size.
* Edits that LSP plugins or other scripts make are shared like your own; text
  props of other plugins on a line a peer just changed may be lost until that
  plugin refreshes them.
