" shared.vim: automatic live co-editing of every file over a Unix socket.
if exists('g:loaded_shared_vim') || !has('ruby') || !has('channel') || !has('textprop')
  finish
endif
let g:loaded_shared_vim = 1

let g:shared_vim_root = expand('<sfile>:p:h:h')
let s:sock = get(g:, 'shared_vim_socket', '/tmp/shared-vim/sock')
let s:server = g:shared_vim_root . '/server/shared-vim-server.rb'
let g:shared_vim_ch = v:none
execute 'rubyfile ' . fnameescape(g:shared_vim_root . '/ruby/shared_vim.rb')

let s:colors = [[203, '#ff5f5f'], [75, '#5fafff'], [114, '#87d787'], [215, '#ffaf5f'],
      \ [177, '#d787ff'], [80, '#5fd7d7'], [221, '#ffd75f'], [211, '#ff87af']]

function! s:Colors() abort
  for i in range(8)
    let [c, g] = s:colors[i]
    execute printf('hi SharedSlot%d ctermfg=%d guifg=%s', i, c, g)
    execute printf('hi SharedStat%d ctermbg=%d ctermfg=16 cterm=bold guibg=%s guifg=#000000 gui=bold', i, c, g)
    " priority: above semantic highlighting of LSP plugins
    if empty(prop_type_get('shared_slot' . i))
      call prop_type_add('shared_slot' . i, {'highlight': 'SharedSlot' . i, 'priority': 1000})
    endif
  endfor
endfunction

" Connect; start the server detached (it outlives this Vim) if needed.
function! s:Connect() abort
  if type(g:shared_vim_ch) == v:t_channel && ch_status(g:shared_vim_ch) ==# 'open'
    return 1
  endif
  for i in range(40)
    if getftype(s:sock) ==# 'socket'
      try
        let ch = ch_open('unix:' . s:sock, {'mode': 'nl',
              \ 'callback': 'SharedVimRecv', 'close_cb': 'SharedVimClosed'})
        if ch_status(ch) ==# 'open'
          let g:shared_vim_ch = ch
          return 1
        endif
      catch
      endtry
    endif
    if i == 0 || i == 20
      call job_start(['setsid', '-f', 'ruby', s:server, s:sock],
            \ {'stoponexit': '', 'in_io': 'null', 'out_io': 'null', 'err_io': 'null'})
    endif
    sleep 50m
  endfor
  return 0
endfunction

function! SharedVimJoin(b) abort
  if !bufloaded(a:b) || getbufvar(a:b, '&buftype') !=# '' || bufname(a:b) ==# ''
    return
  endif
  let path = resolve(fnamemodify(bufname(a:b), ':p'))
  if isdirectory(path) || getfsize(path) > get(g:, 'shared_vim_max_size', 10000000) || !s:Connect()
    return
  endif
  let user = !empty($USERNAME) ? $USERNAME : $USER
  ruby SharedVim.safely { SharedVim.join(VIM.evaluate('a:b'), VIM.evaluate('l:path'), VIM.evaluate('l:user')) }
endfunction

function! s:Leave(b) abort
  if s:reloading != a:b
    ruby SharedVim.safely { SharedVim.leave(VIM.evaluate('a:b')) }
  endif
endfunction

function! SharedVimRecv(ch, msg) abort
  ruby SharedVim.safely { SharedVim.recv(VIM.evaluate('a:msg')) }
endfunction

function! SharedVimListener(b, first, last, added, changes) abort
  ruby SharedVim.safely { SharedVim.changed(*%w[a:b a:first a:last a:added a:changes].map { |v| VIM.evaluate(v) }) }
endfunction

" Per-user undo: u and CTRL-R only take back your own changes.
function! SharedVimUndo(count, redo) abort
  ruby SharedVim.safely { SharedVim.undo(VIM.evaluate('bufnr()'), VIM.evaluate('a:count'), VIM.evaluate('a:redo') == 1) }
endfunction

function! SharedVimClosed(ch) abort
  ruby SharedVim.reset
  call timer_start(500, {-> s:Rejoin()})
endfunction

function! s:Rejoin() abort
  for b in range(1, bufnr('$'))
    call SharedVimJoin(b)
  endfor
endfunction

function! SharedVimStatus() abort
  return get(b:, 'shared_vim_status', '')
endfunction

" Swap file of a running Vim: shared, just edit. Of a dead one: Vim's prompt.
function! s:SwapExists() abort
  let info = swapinfo(v:swapname)
  if get(info, 'pid', 0) > 0 && isdirectory('/proc/' . info.pid) && get(info, 'host', '') ==# hostname()
    let v:swapchoice = 'e'
  endif
endfunction

" After a peer's write, reload quietly so Vim learns the new timestamp (else
" W11 and "changed since reading" on :w), then put the shared text back.
" Changes by other programs still get Vim's warning.
function! s:FileChanged() abort
  let b = str2nr(expand('<abuf>'))
  if getbufvar(b, 'shared_vim_peer_saved', 0) && v:fcs_reason !~# '^\%(deleted\|mode\)$'
    call setbufvar(b, 'shared_vim_peer_saved', 0)
    call setbufvar(b, 'shared_vim_restore', bufnr() == b ? getcurpos() : [])
    ruby SharedVim.safely { SharedVim.before_reload(VIM.evaluate('l:b')) }
    let v:fcs_choice = 'reload'
  else
    let v:fcs_choice = 'ask'
  endif
endfunction

function! s:FileChangedPost() abort
  let b = str2nr(expand('<abuf>'))
  let pos = getbufvar(b, 'shared_vim_restore', v:none)
  if type(pos) == v:t_list
    call setbufvar(b, 'shared_vim_restore', v:none)
    ruby SharedVim.safely { SharedVim.restore(VIM.evaluate('l:b')) }
    if !empty(pos) && bufnr() == b
      call setpos('.', pos)
    endif
  endif
endfunction

function! SharedVimSyncTime(b) abort
  if bufnr() == a:b && mode() =~# '^[iR]'
    call setbufvar(a:b, 'shared_vim_synctime', 1)
    return
  endif
  call setbufvar(a:b, 'shared_vim_synctime', 0)
  if getbufvar(a:b, 'shared_vim_new', 0)
    call s:ReloadNew(a:b)
  else
    execute 'checktime ' . a:b
  endif
endfunction

" A file that did not exist when editing started gets W13 instead, without
" FileChangedShell; only a reload stops it. Hidden buffers wait for BufEnter.
let s:reloading = 0
function! s:ReloadNew(b) abort
  let win = bufwinid(a:b)
  if win == -1
    call setbufvar(a:b, 'shared_vim_synctime', 1)
    return
  endif
  call setbufvar(a:b, 'shared_vim_new', 0)
  call setbufvar(a:b, 'shared_vim_peer_saved', 0)
  let pos = getcurpos(win)
  let s:reloading = a:b
  ruby SharedVim.safely { SharedVim.before_reload(VIM.evaluate('a:b')) }
  try
    call win_execute(win, 'silent! edit!')
  finally
    let s:reloading = 0
    ruby SharedVim.safely { SharedVim.restore(VIM.evaluate('a:b')) }
  endtry
  call win_execute(win, printf('call setpos(".", %s)', string(pos)))
endfunction

call s:Colors()
set laststatus=2
if &statusline ==# ''
  set statusline=%<%f\ %h%m%r%=%-14.(%l,%c%V%)\ %P
endif
let &statusline = '%{%SharedVimStatus()%} ' . &statusline

nnoremap <expr> u     get(b:, 'shared_vim_on', 0) ? printf("\<Cmd>call SharedVimUndo(%d, 0)\<CR>", v:count1) : 'u'
nnoremap <expr> <C-r> get(b:, 'shared_vim_on', 0) ? printf("\<Cmd>call SharedVimUndo(%d, 1)\<CR>", v:count1) : "\<C-r>"

augroup shared_vim
  autocmd!
  autocmd BufReadPost,BufNewFile * call SharedVimJoin(str2nr(expand('<abuf>')))
  autocmd BufNewFile * let b:shared_vim_new = 1
  autocmd BufWritePost * let b:shared_vim_new = 0
  autocmd BufWritePost * ruby SharedVim.safely { SharedVim.saved(VIM.evaluate("expand('<abuf>')").to_i) }
  autocmd BufUnload * call s:Leave(str2nr(expand('<abuf>')))
  autocmd ColorScheme * call s:Colors()
  autocmd SwapExists * call s:SwapExists()
  autocmd FileChangedShell * call s:FileChanged()
  autocmd FileChangedShellPost * call s:FileChangedPost()
  " timer: FileChangedShell does not fire inside another autocmd
  autocmd InsertLeave,BufEnter * if get(b:, 'shared_vim_synctime', 0) | call timer_start(0, {-> SharedVimSyncTime(bufnr())}) | endif
augroup END
