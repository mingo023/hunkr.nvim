local M = {}

local function git(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  end
  return res.stdout or ""
end

local function split_nul(s)
  local out = {}
  for piece in (s or ""):gmatch("([^%z]*)%z") do
    out[#out + 1] = piece
  end
  return out
end

local function is_binary(abs)
  local fd = io.open(abs, "rb")
  if not fd then
    return false
  end
  local head = fd:read(1024) or ""
  fd:close()
  return head:find("%z") ~= nil
end

--- @return string|nil root  absolute path of the repo containing cwd
function M.root()
  local out = git({ "rev-parse", "--show-toplevel" })
  return out and vim.trim(out) or nil
end

--- @class hunkr.File
--- @field path string        repo-relative
--- @field status "A"|"M"|"D"
--- @field added integer|nil  nil means binary
--- @field deleted integer|nil

--- What a review is measured against. For a branch that means where it forked from
--- HEAD, so commits landed on the base since then stay out of the diff.
--- @return string|nil rev, string|nil err
function M.base_rev(root, base)
  if base == "HEAD" then
    return "HEAD"
  end
  local out, err = git({ "merge-base", base, "HEAD" }, root)
  return out and vim.trim(out) or nil, err
end

--- Every change between `rev` and the working tree, untracked files included.
--- @param rev string  a commit-ish, "HEAD" for the plain working tree review
--- @return hunkr.File[] files, string|nil err
function M.changed_files(root, rev)
  -- --no-renames keeps every record a uniform <field><NUL><path><NUL> pair
  local name_status, err = git({ "diff", rev, "--name-status", "--no-renames", "-z" }, root)
  if not name_status then
    return {}, err
  end

  local counts = {}
  local numstat = git({ "diff", rev, "--numstat", "--no-renames", "-z" }, root) or ""
  for _, rec in ipairs(split_nul(numstat)) do
    local add, del, path = rec:match("^(%S+)\t(%S+)\t(.*)$")
    if path then
      counts[path] = { added = tonumber(add), deleted = tonumber(del) }
    end
  end

  local files = {}
  local fields = split_nul(name_status)
  for i = 1, #fields - 1, 2 do
    local status, path = fields[i]:sub(1, 1), fields[i + 1]
    local c = counts[path] or {}
    files[#files + 1] = { path = path, status = status, added = c.added, deleted = c.deleted }
  end

  local untracked = git({ "ls-files", "--others", "--exclude-standard", "-z" }, root) or ""
  for _, path in ipairs(split_nul(untracked)) do
    local abs = root .. "/" .. path
    local added = nil
    if not is_binary(abs) then
      added = #vim.fn.readfile(abs)
    end
    files[#files + 1] = { path = path, status = "A", added = added, deleted = added and 0 or nil }
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files, nil
end

--- @param rev string|nil  nil reads the working tree copy
--- @return string[] lines
function M.file_lines(root, path, rev)
  if rev then
    local out = git({ "show", rev .. ":" .. path }, root)
    return out and vim.split(out:gsub("\n$", ""), "\n", { plain = true }) or {}
  end
  local abs = root .. "/" .. path
  return vim.fn.filereadable(abs) == 1 and vim.fn.readfile(abs) or {}
end

return M
