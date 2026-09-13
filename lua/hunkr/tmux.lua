local M = {}

local remembered

local function sh(cmd)
  local res = vim.system(cmd, { text = true }):wait()
  return res.code == 0 and res.stdout or nil
end

--- tmux only knows a pane's tty, so join it against `ps` to find which pane runs claude.
local function claude_ttys()
  local out = sh({ "ps", "-eo", "tty=,comm=" }) or ""
  local ttys = {}
  for line in out:gmatch("[^\n]+") do
    local tty, comm = line:match("^(%S+)%s+(.*)$")
    if tty and comm and vim.fs.basename(vim.trim(comm)) == "claude" then
      ttys["/dev/" .. tty] = true
    end
  end
  return ttys
end

--- @return { id: string, path: string, title: string }[]
function M.panes(root)
  local out = sh({ "tmux", "list-panes", "-a", "-F", "#{pane_id}|#{pane_tty}|#{pane_current_path}|#{pane_title}" })
  if not out then
    return {}
  end
  local ttys = claude_ttys()
  local all, in_repo = {}, {}
  for line in out:gmatch("[^\n]+") do
    local id, tty, path, title = line:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if id and ttys[tty] then
      local pane = { id = id, path = path, title = title }
      all[#all + 1] = pane
      if root and (path == root or vim.startswith(path, root .. "/") or vim.startswith(root, path .. "/")) then
        in_repo[#in_repo + 1] = pane
      end
    end
  end
  return #in_repo > 0 and in_repo or all
end

local function send(pane, text)
  vim.system({ "tmux", "send-keys", "-t", pane, "-l", text }):wait()
  -- claude's prompt swallows a CR that arrives in the same burst as the text
  vim.defer_fn(function()
    vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
  end, 300)
end

--- @param text string prompt to type into the claude pane
--- @param root string repo root, used to prefer panes sitting in the same tree
function M.prompt(text, root, on_done)
  local function deliver(pane)
    remembered = pane
    send(pane, text)
    on_done(pane)
  end

  if remembered then
    for _, p in ipairs(M.panes(root)) do
      if p.id == remembered then
        return deliver(remembered)
      end
    end
    remembered = nil
  end

  local panes = M.panes(root)
  if #panes == 0 then
    vim.fn.setreg("+", text)
    return on_done(nil)
  end
  if #panes == 1 then
    return deliver(panes[1].id)
  end

  vim.ui.select(panes, {
    prompt = "hunkr: which claude session?",
    format_item = function(p)
      return ("%s  %s"):format(p.id, p.title ~= "" and p.title or p.path)
    end,
  }, function(choice)
    if choice then
      deliver(choice.id)
    end
  end)
end

function M.forget()
  remembered = nil
end

return M
