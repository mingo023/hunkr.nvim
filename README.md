# hunkr.nvim

Review your own diff in Neovim, leave comments on the lines, hand them to Claude
Code, read the replies where you wrote the questions.

Inspired by [hunk](https://github.com/modem-dev/hunk).

## What it does

- Inline diff of the working tree against `HEAD` or any branch, in its own tab.
- File tree of exactly what changed (nvim-tree, no extra window plumbing).
- Comments on a line or a visual range, with replies, edits and resolve.
- Comments survive edits: each thread re-anchors itself by line content.
- Telescope picker over every thread in the review.
- `<Leader>s` types `/hunkr <review.json>` into the Claude Code pane running in
  tmux; Claude fixes the code, replies on the thread, and pokes Neovim to repaint.

## Requirements

- Neovim 0.12+ (`vim.text.diff`, `'statuscolumn'`)
- [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) — the file tree
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — the thread picker
- [snacks.nvim](https://github.com/folke/snacks.nvim) — the comment popup
- `git`, and tmux if you want the Claude handoff

## Install

```lua
{
  "mingo023/hunkr.nvim",
  dependencies = {
    "kyazdani42/nvim-tree.lua",
    "nvim-telescope/telescope.nvim",
    "folke/snacks.nvim",
  },
  config = function()
    require("hunkr").setup()
  end,
}
```

`setup()` takes no options. It defines the commands and the highlight links; every
other key is buffer-local to the review.

## Use

```vim
:Hunkr                 " working tree vs HEAD
:Hunkr main            " working tree vs where you forked from main
:HunkrToggle           " same, and closes the review when it is open
:HunkrList             " threads in telescope
:HunkrSend             " hand the open threads to claude
:HunkrExport           " threads as markdown, in a scratch tab
:HunkrReload           " re-read the tree and repaint
```

A base argument completes from your branches. `:Hunkr main` diffs against
`git merge-base main HEAD`, so commits that landed on `main` after you branched
stay out of the review — the same thing a pull request shows. The new side is
always the working tree, so committed and uncommitted work both appear.

### Keys inside the review

| Key | Where | Does |
| --- | --- | --- |
| `c` | diff | comment on the line, or reply / edit an existing thread |
| `c` | diff, visual | comment on the whole selection |
| `R` | diff | resolve the thread |
| `x` | diff | delete the thread |
| `<CR>` / `za` | diff | expand or collapse the unchanged lines |
| `]c` / `[c` | diff | next / previous hunk |
| `<CR>` | tree | open the file under the cursor |
| `<Tab>` | both | jump between tree and diff |
| `<Leader>e` | both | show / hide the tree |
| `<Leader>l` | both | list threads in telescope |
| `<Leader>s` | both | send threads to claude |
| `<Leader>x` | both | export as markdown |
| `<C-r>` | both | reload from disk |
| `q` | both | close the review |

In the comment popup: `<C-s>` (or `<CR>` in normal mode) saves, `<Esc>` cancels,
an empty body deletes the message.

## The Claude loop

Copy `skills/hunkr` into `~/.claude/skills/`. Then, with a Claude Code session
running in any tmux pane:

1. Comment on the lines you want changed, `<Leader>s`.
2. Claude edits the code, replies on each thread, re-anchors the ones it moved,
   and calls back over `--remote-expr` so the review repaints itself.
3. Read the replies in the diff, comment again, repeat.

If no Claude pane is running, the prompt lands in your clipboard instead. When
several are, hunkr asks once and remembers.

The review also watches the repo, so edits from anywhere — Claude, git, another
Neovim — repaint the diff on their own.

## Where comments live

`/tmp/hunkr/<repo-path>@<base>.json`, one file per repo and base. Nothing is
written inside your repository, and nothing survives a reboot — a review is a
conversation, not a record.

## Highlights

Everything links to something sane by default; override any of these to taste.

```
HunkrAdded HunkrRemoved HunkrChanged HunkrAddLine HunkrDelLine
HunkrComment HunkrMe HunkrClaude HunkrStale
HunkrGutter HunkrGap HunkrTitle HunkrWinbar
```
