local git = require("hunkr.git")
local diff = require("hunkr.diff")
local threads = require("hunkr.threads")
local input = require("hunkr.input")
local tmux = require("hunkr.tmux")
local watch = require("hunkr.watch")
local tree = require("hunkr.tree")

local M = {}

local CTX = 3
local LINE_HL = { add = "HunkrAddLine", del = "HunkrDelLine" }
local SIGN = { add = "+", del = "-", gap = "⋯", ctx = " " }

local S = {
  tab = nil,
  root = nil,
  base = "HEAD",
  rev = "HEAD",
  files = {},
  index = 0,
  rows = {},
  expanded = {},
  gutter_w = 3,
  sidebar = {},
  diff = {},
}

local ns_diff = vim.api.nvim_create_namespace("hunkr_diff")

local function err(msg)
  vim.notify("hunkr: " .. msg, vim.log.levels.ERROR)
end

function M.is_open()
  return S.tab ~= nil and vim.api.nvim_tabpage_is_valid(S.tab)
end

local function layout_ok()
  return S.diff.win ~= nil
    and vim.api.nvim_win_is_valid(S.diff.win)
    and S.diff.buf ~= nil
    and vim.api.nvim_buf_is_valid(S.diff.buf)
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Virtual lines are truncated rather than wrapped, so comments are folded to fit.
local function text_area()
  return vim.api.nvim_win_get_width(S.diff.win) - (S.gutter_w * 2 + 6)
end

--- A thread draws a rail down the gutter of every line it covers, so a multi-line
--- comment reads as one block instead of a marker per line.
local function rail(lnum)
  local f = S.files[S.index]
  local row = S.rows[lnum]
  if not f or not row then
    return " "
  end
  local side, line = diff.anchor(row)
  return side and line and threads.at(f.path, side, line) and "▌" or " "
end

--- 'statuscolumn' callback: HEAD line number, working tree line number, marker, thread rail.
function M.statuscolumn()
  local w = S.gutter_w
  -- comment blocks render as virtual lines; keep their gutter empty so code stays aligned
  if vim.v.virtnum ~= 0 then
    return table.concat({ "%#HunkrGutter#", string.rep(" ", w * 2 + 4), "%#HunkrComment#", rail(vim.v.lnum), " " })
  end
  local row = S.rows[vim.v.lnum]
  if not row then
    return ""
  end
  local blank = string.rep(" ", w)
  local old = row.old and ("%" .. w .. "d"):format(row.old) or blank
  local new = row.new and ("%" .. w .. "d"):format(row.new) or blank
  local sign_hl = row.kind == "add" and "HunkrAdded" or row.kind == "del" and "HunkrRemoved" or "HunkrGap"
  return table.concat({
    "%#HunkrGutter#",
    old,
    " ",
    new,
    " %#",
    sign_hl,
    "#",
    SIGN[row.kind],
    " %#HunkrComment#",
    rail(vim.v.lnum),
    " ",
  })
end

--- @param keep boolean|nil  leave the cursor alone instead of jumping to the first change
local function render_diff(f, keep)
  local old = f.status == "A" and {} or git.file_lines(S.root, f.path, S.rev)
  local new = f.status == "D" and {} or git.file_lines(S.root, f.path)

  S.expanded[f.path] = S.expanded[f.path] or {}
  local rows
  if not f.added then
    rows = { { kind = "ctx", text = "[binary file]" } }
  else
    rows = diff.rows(old, new, CTX, S.expanded[f.path])
    if #rows == 0 then
      rows = { { kind = "ctx", text = "(no textual changes)" } }
    end
  end
  S.rows = rows
  S.gutter_w = math.max(#tostring(#old), #tostring(#new), 2)

  local texts = {}
  for i, row in ipairs(rows) do
    texts[i] = row.text
  end
  set_lines(S.diff.buf, texts)

  vim.api.nvim_buf_clear_namespace(S.diff.buf, ns_diff, 0, -1)
  for i, row in ipairs(rows) do
    if LINE_HL[row.kind] then
      -- below the built-in Visual/CursorLine highlights, or selecting a changed line shows nothing
      vim.api.nvim_buf_set_extmark(S.diff.buf, ns_diff, i - 1, 0, {
        line_hl_group = LINE_HL[row.kind],
        priority = 50,
      })
    elseif row.kind == "gap" then
      vim.api.nvim_buf_set_extmark(S.diff.buf, ns_diff, i - 1, 0, {
        virt_text = { { ("⋅⋅⋅ %d lines ⋅⋅⋅"):format(row.count), "HunkrGap" } },
        virt_text_pos = "eol",
      })
    end
  end

  vim.bo[S.diff.buf].filetype = vim.filetype.match({ filename = f.path }) or ""
  threads.reanchor(f.path, "new", new)
  threads.render(S.diff.buf, f.path, rows, text_area())

  if keep then
    return
  end
  local first = diff.first_change(rows) or 1
  vim.api.nvim_win_set_cursor(S.diff.win, { first, 0 })
  vim.api.nvim_win_call(S.diff.win, function()
    vim.cmd("normal! zz")
  end)
end

--- Unchanged code stays collapsed until asked for; the same key puts it back.
local function toggle_gap()
  local f = S.files[S.index]
  local cur = vim.api.nvim_win_get_cursor(S.diff.win)[1]
  local row = S.rows[cur]
  if not f or not row then
    return
  end
  local opening = row.kind == "gap"
  local key = opening and row.from or row.gap
  if not key then
    return
  end
  S.expanded[f.path][key] = opening or nil
  render_diff(f, true)
  for i, r in ipairs(S.rows) do
    if (opening and r.gap == key and r.old == key) or (not opening and r.from == key) then
      vim.api.nvim_win_set_cursor(S.diff.win, { i, 0 })
      break
    end
  end
end

local function load_file(idx)
  local f = S.files[idx]
  if not f or not layout_ok() then
    return
  end
  S.index = idx
  render_diff(f)
  local against = S.base ~= "HEAD" and ("  vs " .. S.base) or ""
  vim.wo[S.diff.win].winbar = "%#HunkrWinbar#  " .. f.path .. against .. "  %*"
end

local function load_path(path)
  for i, f in ipairs(S.files) do
    if f.path == path then
      return load_file(i)
    end
  end
end

local function goto_hunk(dir)
  local cur = vim.api.nvim_win_get_cursor(S.diff.win)[1]
  local target = diff.next_change(S.rows, cur, dir)
  if not target then
    return
  end
  vim.api.nvim_win_set_cursor(S.diff.win, { target, 0 })
  vim.cmd("normal! zz")
end

--- Collapse a span of display rows onto one side of the file, ignoring gaps and
--- rows belonging to the other side.
--- @return hunkr.File|nil, "old"|"new"|nil, table|nil { line, anchor, end_line, end_anchor }
local function selection(from, to)
  local f = S.files[S.index]
  if not f then
    return
  end
  local side, first, last, anchor, end_anchor
  for i = from, to do
    local row = S.rows[i]
    local s, lnum = diff.anchor(row)
    if s and lnum and (side == nil or s == side) then
      side = s
      first, anchor = first or lnum, anchor or row.text
      last, end_anchor = lnum, row.text
    end
  end
  if not side then
    return
  end
  local multi = last > first
  return f, side, {
    line = first,
    anchor = anchor,
    end_line = multi and last or nil,
    end_anchor = multi and end_anchor or nil,
  }
end

--- @return hunkr.File|nil, "old"|"new"|nil, integer|nil
local function cursor_line()
  local cur = vim.api.nvim_win_get_cursor(S.diff.win)[1]
  local f, side, at = selection(cur, cur)
  return f, side, at and at.line
end

local function refresh_threads()
  threads.render(S.diff.buf, S.files[S.index].path, S.rows, text_area())
  tree.refresh()
end

local function comment(from, to)
  local f, side, at = selection(from, to)
  if not f then
    return
  end
  local t = threads.at(f.path, side, at.line)
  local editing = t and threads.own_tail(t)
  -- a reply belongs to the thread's range, not to whichever line the cursor sits on
  local first, last = t and t.line or at.line, t and t.end_line or at.end_line
  local span = last and ("%d-%d"):format(first, last) or tostring(first)
  input.open({
    title = ("%s:%s%s"):format(
      vim.fn.fnamemodify(f.path, ":t"),
      span,
      editing and " · edit" or t and " · reply" or ""
    ),
    text = editing and editing.text or nil,
    on_submit = function(text)
      if editing then
        threads.replace(t, text)
      elseif text ~= "" then
        threads.comment(f.path, side, at, text)
      else
        return
      end
      refresh_threads()
    end,
  })
end

local function thread_action(fn)
  return function()
    local f, side, lnum = cursor_line()
    local t = f and threads.at(f.path, side, lnum)
    if t then
      fn(t)
      refresh_threads()
    end
  end
end

--- Jump the review to a thread: its file in the diff, the cursor on its first line.
function M.goto_thread(t)
  if not M.is_open() or not layout_ok() then
    return
  end
  load_path(t.path)
  for i, row in ipairs(S.rows) do
    local side, lnum = diff.anchor(row)
    if side == t.side and lnum == t.line then
      vim.api.nvim_win_set_cursor(S.diff.win, { i, 0 })
      vim.api.nvim_win_call(S.diff.win, function()
        vim.cmd("normal! zz")
      end)
      break
    end
  end
  tree.focus(t.path)
  vim.api.nvim_set_current_win(S.diff.win)
end

function M.close()
  tree.close()
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(S.tab)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      -- the tree is already gone, so the diff may be the last window: empty it, don't close it
      if S.diff.win and vim.api.nvim_win_is_valid(S.diff.win) then
        vim.api.nvim_set_current_win(S.diff.win)
      end
      if S.spare and vim.api.nvim_buf_is_valid(S.spare) then
        vim.api.nvim_win_set_buf(0, S.spare)
        S.spare = nil
      else
        vim.cmd("enew")
      end
    end
  end
  if S.diff.buf and vim.api.nvim_buf_is_valid(S.diff.buf) then
    vim.api.nvim_buf_delete(S.diff.buf, { force = true })
  end
  if S.spare and vim.api.nvim_buf_is_valid(S.spare) and vim.api.nvim_buf_get_name(S.spare) == "" and not vim.bo[S.spare].modified then
    pcall(vim.api.nvim_buf_delete, S.spare, {})
  end
  watch.stop()
  S.tab, S.spare, S.sidebar, S.diff, S.rows = nil, nil, {}, {}, {}
end

function M.export()
  local markdown, total = threads.export()
  if total == 0 then
    return vim.notify("hunkr: no comments yet", vim.log.levels.INFO)
  end
  vim.fn.setreg("+", markdown)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(markdown, "\n", { plain = true }))
  vim.notify(("hunkr: %d comment%s copied to clipboard"):format(total, total == 1 and "" or "s"))
end

local function map(buf, lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "hunkr: " .. desc })
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  return buf
end

local function tree_select()
  if tree.cursor_kind() == "directory" then
    return tree.toggle_dir()
  end
  local path = tree.cursor_path()
  if path then
    load_path(path)
    vim.api.nvim_set_current_win(S.diff.win)
  end
end

local toggle_sidebar

local function shared_keys(buf)
  map(buf, "<C-r>", function()
    M.reload()
  end, "reload from disk")
  map(buf, "<Leader>e", function()
    toggle_sidebar()
  end, "show/hide the file tree")
  map(buf, "<Leader>l", function()
    require("hunkr.picker").threads()
  end, "list comments")
  map(buf, "<Leader>s", function()
    M.send()
  end, "send threads to claude")
  map(buf, "<Leader>x", M.export, "export comments")
  map(buf, "q", M.close, "close")
end

--- nvim-tree re-attaches its own keymaps on every reload, so ours are re-applied each time.
local function attach_tree(buf)
  S.sidebar.buf = buf
  map(buf, "<CR>", tree_select, "open file / toggle folder")
  map(buf, "<Tab>", function()
    vim.api.nvim_set_current_win(S.diff.win)
  end, "focus diff")
  shared_keys(buf)
end

--- Fold the tree away so the diff gets the whole tab; the review stays open either way.
function toggle_sidebar()
  if S.sidebar.win and vim.api.nvim_win_is_valid(S.sidebar.win) then
    -- closing the tree window would otherwise trip the WinClosed teardown
    S.hiding = true
    tree.close()
    S.sidebar = {}
    S.hiding = false
    return vim.api.nvim_set_current_win(S.diff.win)
  end
  local buf = scratch()
  vim.bo[buf].bufhidden = "wipe"
  S.sidebar.win = vim.api.nvim_open_win(buf, true, { split = "left", win = S.diff.win })
  tree.open(S.sidebar.win, S.root, { on_attach = attach_tree, files = S.files })
  local f = S.files[S.index]
  if f then
    tree.focus(f.path)
  end
end

local function build_layout()
  vim.cmd("tabnew")
  S.tab = vim.api.nvim_get_current_tabpage()
  -- nvim-tree takes over this window, leaving the buffer :tabnew made behind
  S.spare = vim.api.nvim_get_current_buf()

  S.diff.buf = scratch()
  S.sidebar.win = vim.api.nvim_get_current_win()
  S.diff.win = vim.api.nvim_open_win(S.diff.buf, false, { split = "right", win = S.sidebar.win })

  local dw = vim.wo[S.diff.win]
  dw.number, dw.relativenumber, dw.wrap, dw.cursorline = false, false, false, true
  dw.signcolumn, dw.foldcolumn = "no", "0"
  dw.statuscolumn = "%!v:lua.require'hunkr.ui'.statuscolumn()"

  map(S.diff.buf, "c", function()
    local cur = vim.api.nvim_win_get_cursor(S.diff.win)[1]
    comment(cur, cur)
  end, "comment on line")
  vim.keymap.set("x", "c", function()
    local from, to = vim.fn.line("v"), vim.fn.line(".")
    -- leave visual mode before the popup steals focus, and do it now rather than on the next tick
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    comment(math.min(from, to), math.max(from, to))
  end, { buffer = S.diff.buf, nowait = true, desc = "hunkr: comment on selection" })
  map(S.diff.buf, "x", thread_action(threads.remove), "delete thread")
  map(S.diff.buf, "R", thread_action(threads.resolve), "resolve thread")
  map(S.diff.buf, "<CR>", toggle_gap, "expand / collapse unchanged lines")
  map(S.diff.buf, "za", toggle_gap, "expand / collapse unchanged lines")
  map(S.diff.buf, "]c", function()
    goto_hunk(1)
  end, "next hunk")
  map(S.diff.buf, "[c", function()
    goto_hunk(-1)
  end, "previous hunk")
  map(S.diff.buf, "<Tab>", function()
    if S.sidebar.win and vim.api.nvim_win_is_valid(S.sidebar.win) then
      vim.api.nvim_set_current_win(S.sidebar.win)
    else
      toggle_sidebar()
    end
  end, "focus tree")
  shared_keys(S.diff.buf)

  tree.open(S.sidebar.win, S.root, { on_attach = attach_tree, files = S.files })

  local group = vim.api.nvim_create_augroup("hunkr", { clear = true })

  -- messages are folded to the window's width, so they have to be redrawn when it changes
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      local f = S.files[S.index]
      if f and layout_ok() then
        threads.render(S.diff.buf, f.path, S.rows, text_area())
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if S.hiding then
        return
      end
      local win = tonumber(ev.match)
      if win == S.sidebar.win or win == S.diff.win then
        vim.schedule(M.close)
      end
    end,
  })
end

--- @param base string|nil  branch or commit to review against, default HEAD
function M.open(base)
  if M.is_open() then
    return vim.api.nvim_set_current_tabpage(S.tab)
  end

  local root = git.root()
  if not root then
    return err("not inside a git repository")
  end
  base = base ~= nil and base ~= "" and base or "HEAD"
  local rev, rev_err = git.base_rev(root, base)
  if not rev then
    return err(rev_err)
  end
  local files, git_err = git.changed_files(root, rev)
  if git_err then
    return err(git_err)
  end
  if #files == 0 then
    return vim.notify("hunkr: no changes against " .. base, vim.log.levels.INFO)
  end

  S.root, S.base, S.rev, S.files, S.index = root, base, rev, files, 0
  threads.load(root, base)
  build_layout()
  watch.start(root, M.reload)
  load_file(1)
  tree.focus(files[1].path)
  vim.api.nvim_set_current_win(S.sidebar.win)
end

--- One key in and out: jump to the review from another tab, close it from inside.
--- @param base string|nil  reopens against a different base when the review is up
function M.toggle(base)
  if M.is_open() and base ~= nil and base ~= "" and base ~= S.base then
    M.close()
    return M.open(base)
  end
  if not M.is_open() then
    return M.open(base)
  end
  if vim.api.nvim_get_current_tabpage() == S.tab then
    return M.close()
  end
  vim.api.nvim_set_current_tabpage(S.tab)
end

--- Hand the review file to a claude pane and let it drive the loop from there.
function M.send()
  if not M.is_open() then
    return err("no review open")
  end
  local n = threads.open_count()
  if n == 0 then
    return vim.notify("hunkr: no open threads", vim.log.levels.INFO)
  end
  threads.save()
  tmux.prompt("/hunkr " .. threads.path(), S.root, function(pane)
    if pane then
      vim.notify(("hunkr: sent %d thread%s to %s"):format(n, n == 1 and "" or "s", pane))
    else
      vim.notify("hunkr: no claude pane found — prompt copied to clipboard", vim.log.levels.WARN)
    end
  end)
end

--- Entry point claude calls over RPC once it has answered threads and edited code.
function M.reload()
  vim.schedule(function()
    if not M.is_open() or not layout_ok() then
      return
    end
    threads.load(S.root, S.base)
    local current = S.files[S.index] and S.files[S.index].path
    S.files = git.changed_files(S.root, S.rev) or {}
    tree.refresh(S.files)
    if #S.files == 0 then
      S.rows = {}
      return set_lines(S.diff.buf, { "(no changes against " .. S.base .. ")" })
    end
    local idx = 1
    for i, f in ipairs(S.files) do
      if f.path == current then
        idx = i
      end
    end
    -- the watcher fires while you are reading, so never yank the cursor off the line you are on
    local view = current == S.files[idx].path and vim.api.nvim_win_call(S.diff.win, vim.fn.winsaveview) or nil
    S.index = 0
    load_file(idx)
    if view then
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(S.diff.buf))
      vim.api.nvim_win_call(S.diff.win, function()
        vim.fn.winrestview(view)
      end)
    end
  end)
  return "ok"
end

return M
