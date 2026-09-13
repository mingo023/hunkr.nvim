local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local entry_display = require("telescope.pickers.entry_display")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local threads = require("hunkr.threads")

local M = {}

local STATUS_HL = { open = "HunkrMe", answered = "HunkrClaude" }

local function span(t)
  return t.end_line and ("%d-%d"):format(t.line, t.end_line) or tostring(t.line)
end

local function location(t)
  return ("%s:%s%s"):format(t.path, span(t), t.side == "old" and " (HEAD)" or "")
end

local function last_line(t)
  local msg = t.messages[#t.messages]
  return msg and vim.split(msg.text, "\n", { plain = true })[1] or ""
end

--- The results pane is narrow, so only give the location the room it actually needs.
local function make_displayer(list)
  local width = 0
  for _, t in ipairs(list) do
    width = math.max(width, vim.fn.strdisplaywidth(location(t)))
  end
  return entry_display.create({
    separator = "  ",
    items = { { width = math.min(width, 50) }, { width = 8 }, { remaining = true } },
  })
end

local function make_entry(displayer, t)
  local texts = {}
  for _, msg in ipairs(t.messages) do
    texts[#texts + 1] = msg.text
  end
  return {
    value = t,
    -- searching by file, by what was said, and by who said it should all work
    ordinal = location(t) .. " " .. table.concat(texts, " "),
    display = function()
      return displayer({
        { location(t), "HunkrTitle" },
        { t.status, STATUS_HL[t.status] or "HunkrGutter" },
        { last_line(t), "HunkrComment" },
      })
    end,
  }
end

local function preview_lines(t)
  local out = {
    ("# %s"):format(location(t)),
    "",
    ("status: %s%s"):format(t.status, t.stale and " · anchor drifted" or ""),
    "",
  }
  if t.anchor then
    out[#out + 1] = "```"
    out[#out + 1] = t.anchor
    if t.end_anchor then
      out[#out + 1] = "…"
      out[#out + 1] = t.end_anchor
    end
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  for _, msg in ipairs(t.messages) do
    out[#out + 1] = ("**%s**"):format(msg.author)
    vim.list_extend(out, vim.split(msg.text, "\n", { plain = true }))
    out[#out + 1] = ""
  end
  return out
end

--- Every comment in the current review, newest message first in the preview.
function M.threads(opts)
  local ui = require("hunkr.ui")
  if not ui.is_open() then
    ui.open()
  end
  local list = threads.list()
  if #list == 0 then
    return vim.notify("hunkr: no comments yet", vim.log.levels.INFO)
  end

  opts = opts or {}
  local displayer = make_displayer(list)
  pickers
    .new(opts, {
      prompt_title = "hunkr comments",
      finder = finders.new_table({
        results = list,
        entry_maker = function(t)
          return make_entry(displayer, t)
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = previewers.new_buffer_previewer({
        title = "thread",
        define_preview = function(self, entry)
          vim.bo[self.state.bufnr].filetype = "markdown"
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines(entry.value))
        end,
      }),
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local selected = action_state.get_selected_entry()
          actions.close(bufnr)
          if selected then
            ui.goto_thread(selected.value)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
