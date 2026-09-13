local M = {}

local DEBOUNCE = 250

local handle, timer

local function ignored(path)
  return path == nil or path:find("%.git/") ~= nil
end

--- Watch the whole repo for changes made outside the editor (claude, git, another nvim).
--- Recursive fs_event is FSEvents-backed on macOS, so one handle covers the tree.
function M.start(root, on_change)
  M.stop()
  timer = vim.uv.new_timer()
  handle = vim.uv.new_fs_event()
  local ok = pcall(function()
    handle:start(root, { recursive = true }, function(err, path)
      if err or ignored(path) or not timer then
        return
      end
      -- writers truncate before they write; wait for the dust to settle
      timer:start(DEBOUNCE, 0, function()
        vim.schedule(on_change)
      end)
    end)
  end)
  if not ok then
    M.stop()
  end
end

function M.stop()
  if handle then
    handle:stop()
    handle:close()
    handle = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

return M
