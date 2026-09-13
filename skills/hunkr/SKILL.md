---
name: hunkr
description: Answer code-review threads coming from the hunkr Neovim plugin. Use when given a path to a hunkr review.json, or when the user says "hunkr", "review threads", or pastes /hunkr <path>.
argument-hint: "[path to the review json]"
---

# hunkr review loop

You are the other half of a review conversation. The reviewer comments on lines in
Neovim; you fix the code and reply on the same thread; they read your reply in the
editor and comment again. Keep the loop tight — this is a conversation, not a report.

## The review file

hunkr always passes an absolute path, under `/tmp/hunkr/`. Shape:

```json
{
  "version": 1,
  "repo": "/Users/me/project",
  "base": "HEAD",
  "nvim": {
    "servername": "/var/folders/.../nvim.15994.0",
    "notify": "nvim --server <servername> --remote-expr \"v:lua.require('hunkr').reload()\""
  },
  "threads": [
    {
      "id": "t1",
      "path": "lua/hunkr/ui.lua",
      "side": "new",
      "line": 112,
      "anchor": "  if vim.v.virtnum ~= 0 then",
      "status": "open",
      "messages": [{ "author": "me", "text": "this breaks on wrapped lines" }]
    }
  ]
}
```

- `side: "new"` → `line` is in the working tree file. `side: "old"` → `line` is in
  `git show <base>:<path>`; the reviewer is pointing at deleted code.
- `base` is what the review is diffed against — `"HEAD"` for uncommitted work, or a
  branch like `"main"`, in which case the old side is `git merge-base main HEAD`.
- `anchor` is the exact text of that line when the comment was written. Use it to
  confirm you are looking at the right place — if `line` and `anchor` disagree,
  trust `anchor`.
- Optional `end_line` / `end_anchor`: the comment covers the whole range
  `line`..`end_line`, not a single line. Absent means one line.
- `status`: `open` needs your attention, `answered` is waiting on the reviewer,
  `resolved` is done.

## What to do

1. **Read** the review file at the given path.
2. **For every thread with `status: "open"`**, read the code at `path:line` (or the
   range `line`..`end_line` when present), take the
   last message in `messages` as the instruction, and act on it. If the comment is a
   question rather than a change request, answer it without touching the code.
3. **Reply on the thread**: append `{"author": "claude", "text": "..."}` to `messages`
   and set `"status": "answered"`. Keep replies to one or two sentences — say what you
   changed, or why you didn't. Push back if the request is wrong; this is a dialogue.
4. **Re-anchor every thread you disturbed.** You know exactly which lines you added and
   removed, so recompute `line` and refresh `anchor` — plus `end_line` / `end_anchor`
   where present — for every `side: "new"` thread in a file you edited, including
   threads you did not answer. This is the step that
   keeps the reviewer's comments pinned to the right code; skipping it silently
   misplaces them.
5. **Notify Neovim** by running the command in `nvim.notify` verbatim. It repaints the
   review with your replies. Ignore its output.

Write the review file back with the same 2-space-indented JSON shape. Never drop or
reorder threads, never edit a `"me"` message, never delete `resolved` threads.

## Then stop

Do not start a new task, do not summarize the session, do not ask what's next. The
reviewer will comment again in Neovim and send you another `/hunkr`. Reply in the
conversation with one line per thread you touched, nothing more.
