local ui = require("hunkr.ui")

local M = {
  open = ui.open,
  toggle = ui.toggle,
  close = ui.close,
  export = ui.export,
  send = ui.send,
  list = function(opts)
    require("hunkr.picker").threads(opts)
  end,
  reload = ui.reload,
}

--- @return string[] branches and refs, for :Hunkr <Tab>
function M.complete_base(lead)
  local out = vim.fn.systemlist({ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" })
  return vim.tbl_filter(function(ref)
    return vim.startswith(ref, lead)
  end, out)
end

local LINKS = {
  HunkrAdded = "Added",
  HunkrRemoved = "Removed",
  HunkrChanged = "Changed",
  HunkrComment = "DiagnosticVirtualTextInfo",
  HunkrMe = "DiagnosticVirtualTextHint",
  HunkrClaude = "DiagnosticVirtualTextWarn",
  HunkrStale = "DiagnosticVirtualTextError",
  HunkrAddLine = "DiffAdd",
  HunkrDelLine = "DiffDelete",
  HunkrGutter = "LineNr",
  HunkrGap = "NonText",
  HunkrTitle = "Title",
  HunkrWinbar = "WinBar",
}

local function highlights()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup()
  highlights()
  -- :colorscheme clears default links, so re-declare them after every switch
  vim.api.nvim_create_autocmd("ColorScheme", { callback = highlights })

  vim.api.nvim_create_user_command("Hunkr", function(o)
    ui.open(o.args)
  end, { nargs = "?", complete = "customlist,v:lua.require'hunkr'.complete_base", desc = "Review working tree against a base (default HEAD)" })
  vim.api.nvim_create_user_command("HunkrToggle", function(o)
    ui.toggle(o.args)
  end, { nargs = "?", complete = "customlist,v:lua.require'hunkr'.complete_base", desc = "Toggle the review tab" })
  vim.api.nvim_create_user_command("HunkrExport", ui.export, { desc = "Export review comments as markdown" })
  vim.api.nvim_create_user_command("HunkrList", function()
    require("hunkr.picker").threads()
  end, { desc = "List review comments in telescope" })
  vim.api.nvim_create_user_command("HunkrSend", ui.send, { desc = "Send open review threads to a claude session" })
  vim.api.nvim_create_user_command("HunkrReload", ui.reload, { desc = "Re-read the working tree and repaint the review" })
end

return M
