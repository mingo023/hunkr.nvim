local diff = require("hunkr.diff")

local M = {}

local REVIEW_DIR = "/tmp/hunkr"
local PREFIX_W = 9 -- width of the author column in a comment block
local AUTHOR_HL = { me = "HunkrMe", claude = "HunkrClaude" }

local ns = vim.api.nvim_create_namespace("hunkr_threads")

--- @class hunkr.Thread
--- @field id string
--- @field path string        repo-relative
--- @field side "old"|"new"
--- @field line integer
--- @field anchor string      snapshot of the line, used to re-locate it after edits
--- @field end_line integer|nil    last line of a multi-line comment
--- @field end_anchor string|nil   snapshot of that last line
--- @field status "open"|"answered"|"resolved"
--- @field stale boolean|nil  anchor no longer found near `line`
--- @field messages { author: string, text: string }[]

local data = { version = 1, threads = {} }
local root, base

--- Claude edits this file by hand, so keep it readable rather than one long line.
local function encode(value, indent)
  indent = indent or ""
  local inner = indent .. "  "
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  if vim.islist(value) then
    if #value == 0 then
      return "[]"
    end
    local parts = {}
    for _, v in ipairs(value) do
      parts[#parts + 1] = inner .. encode(v, inner)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys)
  if #keys == 0 then
    return "{}"
  end
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = inner .. vim.json.encode(k) .. ": " .. encode(value[k], inner)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

--- A review is scratch state, not repo content, so it lives outside the tree —
--- one file per repo and base, named after them.
function M.path()
  return ("%s/%s@%s.json"):format(REVIEW_DIR, (root:gsub("^/", ""):gsub("/", "%%")), (base:gsub("/", "%%")))
end

function M.load(repo_root, review_base)
  root, base = repo_root, review_base
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(M.path()), "\n"))
  end)
  data = (ok and type(decoded) == "table" and decoded) or { version = 1, threads = {} }
  data.version = 1
  data.repo = root
  data.base = base
  data.threads = data.threads or {}
  data.nvim = {
    servername = vim.v.servername,
    notify = ("nvim --server %s --remote-expr \"v:lua.require('hunkr').reload()\""):format(vim.v.servername),
  }
end

function M.save()
  vim.fn.mkdir(vim.fs.dirname(M.path()), "p")
  vim.fn.writefile(vim.split(encode(data), "\n", { plain = true }), M.path())
end

--- @return hunkr.Thread|nil thread whose (possibly multi-line) range covers `line`
function M.at(path, side, line)
  for _, t in ipairs(data.threads) do
    if
      t.path == path
      and t.side == side
      and t.status ~= "resolved"
      and line >= t.line
      and line <= (t.end_line or t.line)
    then
      return t
    end
  end
end

function M.count(path)
  local n = 0
  for _, t in ipairs(data.threads) do
    if t.path == path and t.status ~= "resolved" then
      n = n + 1
    end
  end
  return n
end

--- @return hunkr.Thread[] everything still on the table, in review order
function M.list()
  local out = {}
  for _, t in ipairs(data.threads) do
    if t.status ~= "resolved" then
      out[#out + 1] = t
    end
  end
  table.sort(out, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  return out
end

function M.open_count()
  local n = 0
  for _, t in ipairs(data.threads) do
    if t.status ~= "resolved" then
      n = n + 1
    end
  end
  return n
end

local function next_id()
  local max = 0
  for _, t in ipairs(data.threads) do
    local num = tonumber(tostring(t.id or ""):match("%d+") or "")
    if num and num > max then
      max = num
    end
  end
  return "t" .. (max + 1)
end

--- Append a message from the reviewer, opening a thread if there isn't one yet.
--- @param at { line: integer, anchor: string, end_line: integer|nil, end_anchor: string|nil }
function M.comment(path, side, at, text)
  local t = M.at(path, side, at.line)
  if not t then
    -- a reply keeps the range it was opened with; only a new thread defines one
    t = vim.tbl_extend("error", { id = next_id(), path = path, side = side, messages = {} }, at)
    table.insert(data.threads, t)
  end
  table.insert(t.messages, { author = "me", text = text })
  t.status = "open"
  t.stale = nil
  M.save()
end

--- The message `c` should edit instead of reply to: your own trailing message.
function M.own_tail(t)
  local last = t.messages[#t.messages]
  return last and last.author == "me" and last or nil
end

--- Rewrite your trailing message; empty text drops it, and the thread with it if it was the only one.
function M.replace(t, text)
  if text == "" then
    table.remove(t.messages)
    if #t.messages == 0 then
      return M.remove(t)
    end
  else
    t.messages[#t.messages].text = text
  end
  M.save()
end

function M.resolve(t)
  t.status = "resolved"
  M.save()
end

function M.remove(t)
  for i, other in ipairs(data.threads) do
    if other == t then
      table.remove(data.threads, i)
      break
    end
  end
  M.save()
end

local function locate(lines, line, anchor)
  if lines[line] == anchor then
    return line
  end
  for d = 1, 20 do
    if lines[line - d] == anchor then
      return line - d
    elseif lines[line + d] == anchor then
      return line + d
    end
  end
end

--- Code moved under us (usually our own edits, or a pull). Re-locate anchors by content.
function M.reanchor(path, side, lines)
  local moved = false
  for _, t in ipairs(data.threads) do
    if t.path == path and t.side == side and t.status ~= "resolved" and t.anchor then
      local found = locate(lines, t.line, t.anchor)
      local stale = found == nil and true or nil
      if found and found ~= t.line then
        t.line, moved = found, true
      end
      if t.stale ~= stale then
        t.stale, moved = stale, true
      end
      if t.end_anchor and t.end_line then
        local tail = locate(lines, t.end_line, t.end_anchor)
        if tail and tail ~= t.end_line and tail >= t.line then
          t.end_line, moved = tail, true
        end
      end
    end
  end
  if moved then
    M.save()
  end
end

--- Break on the last space that still fits; a word longer than the line is cut.
local function fold(line, width)
  local out = {}
  while #line > width do
    local cut = line:sub(1, width + 1):match("^.*%s()")
    cut = (cut and cut > 1) and cut or width + 1
    out[#out + 1] = (line:sub(1, cut - 1):gsub("%s+$", ""))
    line = (line:sub(cut):gsub("^%s+", ""))
  end
  out[#out + 1] = line
  return out
end

local function block(buf, row, t, width)
  local virt = {}
  if t.stale then
    virt[#virt + 1] = { { "  ⚠ anchor drifted", "HunkrStale" } }
  end
  for _, msg in ipairs(t.messages) do
    local hl = AUTHOR_HL[msg.author] or "HunkrMe"
    local head = true
    for _, para in ipairs(vim.split(msg.text, "\n", { plain = true })) do
      for _, line in ipairs(fold(para, width)) do
        virt[#virt + 1] = { { head and (" %-7s "):format(msg.author) or "         ", hl }, { line, "HunkrComment" } }
        head = false
      end
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { virt_lines = virt })
end

--- @param area integer  columns available for text, gutter excluded
function M.render(buf, path, rows, area)
  local width = math.max(area - PREFIX_W, 20)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- a thread hangs under the last line of its range; the gutter rail covers the rest
  local tail = {}
  for i, row in ipairs(rows) do
    local side, lnum = diff.anchor(row)
    local t = side and lnum and M.at(path, side, lnum)
    if t then
      tail[t] = i
      if lnum == (t.end_line or t.line) then
        tail[t] = nil
        block(buf, i, t, width)
      end
    end
  end
  -- the last line of the range can be scrolled out of the diff (context window, deletions)
  for t, i in pairs(tail) do
    block(buf, i, t, width)
  end
end

--- @return string markdown, integer count
function M.export()
  local by_path = {}
  for _, t in ipairs(data.threads) do
    if t.status ~= "resolved" then
      by_path[t.path] = by_path[t.path] or {}
      table.insert(by_path[t.path], t)
    end
  end

  local paths = vim.tbl_keys(by_path)
  table.sort(paths)

  local out, total = {}, 0
  for _, path in ipairs(paths) do
    out[#out + 1] = "## " .. path
    out[#out + 1] = ""
    table.sort(by_path[path], function(a, b)
      return a.line < b.line
    end)
    for _, t in ipairs(by_path[path]) do
      total = total + 1
      local span = t.end_line and ("%d-%d"):format(t.line, t.end_line) or tostring(t.line)
      local label = (t.side == "old" and "HEAD L" or "L") .. span
      out[#out + 1] = ("- **%s**"):format(label)
      for _, msg in ipairs(t.messages) do
        for j, line in ipairs(vim.split(msg.text, "\n", { plain = true })) do
          out[#out + 1] = j == 1 and ("  - %s: %s"):format(msg.author, line) or ("    " .. line)
        end
      end
    end
    out[#out + 1] = ""
  end

  table.insert(out, 1, "")
  table.insert(out, 1, ("# Review — %d thread%s"):format(total, total == 1 and "" or "s"))
  return table.concat(out, "\n"), total
end

return M
