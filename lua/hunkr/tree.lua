local api = require("nvim-tree.api")
local core = require("nvim-tree.core")
local threads = require("hunkr.threads")

local M = {}

local ns = vim.api.nvim_create_namespace("hunkr_tree")

local S = { active = false, root = nil, saved = nil, on_pick = nil, on_attach = nil, paths = {} }

--- Every path the tree may show: the review's files and the directories leading to them.
local function index(files)
  S.paths = {}
  for _, f in ipairs(files) do
    local abs = S.root .. "/" .. f.path
    S.paths[abs] = true
    for dir in vim.fs.parents(abs) do
      if dir == S.root then
        break
      end
      S.paths[dir] = true
    end
  end
end

local function explorer()
  return core.get_explorer()
end

function M.buf()
  local e = explorer()
  local win = e and require("nvim-tree.view").get_winnr()
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or nil
end

--- nvim-tree keeps a single Explorer for the whole editor (core.lua: `local TreeExplorer`),
--- so hunkr borrows its filter state and must hand it back exactly as it found it.
--- The tree must mirror the review's file list, not the working tree: nvim-tree's own
--- git_clean filter would hide files whose changes are already committed on the branch.
local function borrow_filters()
  local e = explorer()
  if not e or S.saved then
    return
  end
  S.saved = {
    enabled = e.filters.enabled,
    state = vim.deepcopy(e.filters.state),
    custom_function = e.filters.custom_function,
    ignore_list = e.filters.ignore_list,
    exclude_list = e.filters.exclude_list,
  }
  e.filters.enabled = true
  for name in pairs(e.filters.state) do
    e.filters.state[name] = name == "custom"
  end
  e.filters.custom_function = function(abs)
    return not S.paths[abs]
  end
  -- the user's own custom/exclude patterns would punch holes in that list
  e.filters.ignore_list, e.filters.exclude_list = {}, {}
end

local function return_filters()
  local e = explorer()
  if e and S.saved then
    e.filters.enabled = S.saved.enabled
    e.filters.state = S.saved.state
    e.filters.custom_function = S.saved.custom_function
    e.filters.ignore_list = S.saved.ignore_list
    e.filters.exclude_list = S.saved.exclude_list
  end
  S.saved = nil
end

--- @return "directory"|"file"|nil
function M.cursor_kind()
  local node = api.tree.get_node_under_cursor()
  return node and node.type or nil
end

function M.toggle_dir()
  api.node.open.edit()
end

--- @return string|nil repo-relative path; nil for directories and for nodes outside the repo
function M.cursor_path()
  local node = api.tree.get_node_under_cursor()
  local abs = node and node.type ~= "directory" and node.absolute_path
  if not abs or not vim.startswith(abs, S.root .. "/") then
    return nil
  end
  return abs:sub(#S.root + 2)
end

local function draw_badges()
  local e, buf = explorer(), M.buf()
  if not (e and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for line, node in pairs(e:get_nodes_by_line(core.get_nodes_starting_line())) do
    local abs = node.absolute_path
    local rel = abs and vim.startswith(abs, S.root .. "/") and abs:sub(#S.root + 2)
    local n = rel and threads.count(rel) or 0
    if n > 0 and line <= vim.api.nvim_buf_line_count(buf) then
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
        virt_text = { { "  ▌" .. n, "HunkrComment" } },
        virt_text_pos = "eol",
      })
    end
  end
end

api.events.subscribe(api.events.Event.TreeRendered, function()
  if S.active then
    vim.schedule(draw_badges)
  end
end)

-- nvim-tree re-attaches its own keymaps on every reload, so re-apply ours after it does
api.events.subscribe(api.events.Event.TreeAttachedPost, function()
  if S.active and S.on_attach then
    vim.schedule(function()
      local buf = M.buf()
      if buf then
        S.on_attach(buf)
      end
    end)
  end
end)

--- nvim-tree applies its window options only to windows it opened itself; hunkr hands
--- it one, so the diff window's gutter and winbar would otherwise leak into the tree.
local function dress(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  for k, v in pairs(require("nvim-tree.view-state").Active.winopts) do
    vim.api.nvim_set_option_value(k, v, { win = winid, scope = "local" })
  end
  vim.wo[winid].statuscolumn, vim.wo[winid].winbar = "", ""
end

--- @param opts { on_attach: fun(buf: integer), files: hunkr.File[] }
function M.open(winid, root, opts)
  S.root = vim.uv.fs_realpath(root) or root
  S.on_attach = opts.on_attach
  S.active = true
  index(opts.files)

  api.tree.open({ winid = winid, path = S.root })
  dress(require("nvim-tree.view").get_winnr())
  borrow_filters()
  api.tree.reload()
  api.tree.expand_all()

  local buf = M.buf()
  if buf then
    S.on_attach(buf)
  end
  draw_badges()
end

--- Repaint git status and thread badges without collapsing what the user expanded.
--- @param files hunkr.File[]|nil  pass when the review's file list itself changed
function M.refresh(files)
  if S.active then
    if files then
      index(files)
    end
    api.tree.reload()
    draw_badges()
  end
end

function M.focus(path)
  if S.active and path then
    api.tree.find_file({ buf = S.root .. "/" .. path, open = false, focus = false })
  end
end

function M.close()
  if not S.active then
    return
  end
  S.active = false
  return_filters()
  pcall(api.tree.close_in_this_tab)
  pcall(api.tree.reload)
end

return M
