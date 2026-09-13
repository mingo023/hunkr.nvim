local M = {}

--- @class hunkr.Row
--- @field kind "ctx"|"add"|"del"|"gap"
--- @field text string
--- @field old integer|nil  line number in the HEAD version
--- @field new integer|nil  line number in the working tree version
--- @field from integer|nil   gap rows: first line it hides, and the key that expands it
--- @field count integer|nil  gap rows: how many lines it hides
--- @field gap integer|nil    context rows: the gap they were revealed from

local function as_text(lines)
  return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

--- Flatten a diff into display rows: context, deletions then additions per hunk,
--- with a `gap` row wherever unchanged lines were skipped.
--- @param expanded table<integer, boolean>|nil  gaps to show in full, keyed by `from`
--- @return hunkr.Row[]
function M.rows(old, new, ctx, expanded)
  expanded = expanded or {}
  local hunks = vim.text.diff(as_text(old), as_text(new), {
    result_type = "indices",
    algorithm = "histogram",
    linematch = 60,
  })
  if #hunks == 0 then
    return {}
  end

  local rows = {}
  local ai, bi = 1, 1

  --- Unchanged lines advance both versions in lockstep, so `bi - ai` stays constant.
  local function emit_context(upto, gap)
    local offset = bi - ai
    for k = ai, upto do
      rows[#rows + 1] = { kind = "ctx", text = old[k], old = k, new = k + offset, gap = gap }
    end
    if upto >= ai then
      ai, bi = upto + 1, bi + (upto - ai + 1)
    end
  end

  --- Unchanged lines nobody asked for: one collapsed row, or the lines themselves once expanded.
  local function emit_gap(upto)
    if upto < ai then
      return
    end
    if expanded[ai] then
      return emit_context(upto, ai)
    end
    rows[#rows + 1] = { kind = "gap", text = "", from = ai, count = upto - ai + 1 }
    ai, bi = upto + 1, bi + (upto - ai + 1)
  end

  for i, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    -- a zero count anchors *after* the reported line, so the change starts one line later
    local a_from = a_count > 0 and a_start or a_start + 1
    local b_from = b_count > 0 and b_start or b_start + 1

    emit_gap(a_from - ctx - 1)
    emit_context(a_from - 1)

    for k = a_start, a_start + a_count - 1 do
      rows[#rows + 1] = { kind = "del", text = old[k], old = k }
    end
    for k = b_start, b_start + b_count - 1 do
      rows[#rows + 1] = { kind = "add", text = new[k], new = k }
    end
    ai, bi = a_from + a_count, b_from + b_count

    local next_hunk = hunks[i + 1]
    local limit = #old
    if next_hunk then
      limit = (next_hunk[2] > 0 and next_hunk[1] or next_hunk[1] + 1) - 1
    end
    emit_context(math.min(ai + ctx - 1, limit))
  end

  emit_gap(#old)

  return rows
end

--- Which file version a row belongs to, for anchoring comments.
--- @return "old"|"new"|nil side, integer|nil lnum
function M.anchor(row)
  if not row then
    return nil
  end
  if row.kind == "del" then
    return "old", row.old
  end
  if row.kind == "add" or row.kind == "ctx" then
    return "new", row.new
  end
end

--- @return integer|nil row index of the first added/deleted row
function M.first_change(rows)
  for i, row in ipairs(rows) do
    if row.kind == "add" or row.kind == "del" then
      return i
    end
  end
end

local function starts_hunk(rows, i)
  local cur = rows[i]
  if not cur or (cur.kind ~= "add" and cur.kind ~= "del") then
    return false
  end
  local prev = rows[i - 1]
  return not (prev and (prev.kind == "add" or prev.kind == "del"))
end

--- Next row that opens a hunk, searching from `row` in `dir`.
--- @return integer|nil
function M.next_change(rows, row, dir)
  local i = row + dir
  while rows[i] do
    if starts_hunk(rows, i) then
      return i
    end
    i = i + dir
  end
end

return M
