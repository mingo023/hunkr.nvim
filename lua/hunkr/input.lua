local M = {}

--- Multi-line comment editor floating at the cursor.
--- @param opts { title: string, text: string|nil, on_submit: fun(text: string) }
function M.open(opts)
  local function submit(self)
    local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    -- <C-s> fires from insert mode; without this the diff buffer inherits it and every key is E21
    vim.cmd("stopinsert")
    self:close()
    opts.on_submit(vim.trim(table.concat(lines, "\n")))
  end

  local win = Snacks.win({
    relative = "cursor",
    row = 1,
    col = 0,
    width = 64,
    height = 6,
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "left",
    footer = " <C-s> save · <Esc><Esc> cancel ",
    footer_pos = "right",
    enter = true,
    backdrop = false,
    ft = "markdown",
    wo = { wrap = true, linebreak = true },
    bo = { modifiable = true },
    text = opts.text and vim.split(opts.text, "\n", { plain = true }) or nil,
    keys = {
      q = false,
      save = { "<cr>", submit, mode = "n" },
      save_insert = { "<c-s>", submit, mode = { "n", "i" } },
      cancel = { "<esc>", "close", mode = "n" },
    },
  })

  vim.api.nvim_win_call(win.win, function()
    vim.cmd("normal! G")
    vim.cmd("startinsert!")
  end)

  return win
end

return M
