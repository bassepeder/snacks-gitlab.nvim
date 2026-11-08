# snacks-gitlab.nvim

Browse, review and merge GitLab merge requests and issues from Neovim, using [Snacks](https://github.com/folke/snacks.nvim) pickers.

It works like Snacks' built-in GitHub (`gh`) integration, but for GitLab, both gitlab.com and self-hosted instances. Every request goes through the [`glab`](https://gitlab.com/gitlab-org/cli) CLI using your existing `glab` login. There are no tokens to configure.

## Features

- **Merge request and issue pickers** with server-side search, a markdown preview, pipeline status, coloured labels and update time.
- **MR and issue buffers** (`gitlab://…`) with the description, branches, pipeline, approvals, reviewers, and every comment grouped into threads.
- **Diff view** for merge requests:
  - one entry per changed file, with a syntax-highlighted preview
  - review comments shown inline under the line they belong to, including comments made on an earlier version of the MR whose line has only moved
  - comments whose code has changed since are collected under **Outdated comments**, with the original code they were left on
  - comment on a line or a selection of lines, suggest a change, reply to a thread, and resolve or unresolve it
- **Thread actions** in MR buffers: put the cursor on a comment to reply to it, or resolve/unresolve it.
- **Actions menu** (`<cr>`) everywhere:

| Action | MR | Issue |
| --- | :-: | :-: |
| Open in buffer / browser, copy URL | ✓ | ✓ |
| Comment, reply to a thread, edit title and description, edit labels | ✓ | ✓ |
| Close / reopen | ✓ | ✓ |
| View diff, comment on diff lines, suggest changes | ✓ | |
| Resolve / unresolve threads | ✓ | |
| Check out the source branch | ✓ | |
| Approve / revoke approval | ✓ | |
| Merge, or merge when the pipeline succeeds | ✓ | |
| Mark as draft / ready | ✓ | |

Comments open in a small markdown window: write your text, then press `<c-s>` (Ctrl+S) to send it, or `q` (in normal mode) to cancel.

## Requirements

- Neovim ≥ 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) with the picker enabled (LazyVim has it by default)
- [`glab`](https://gitlab.com/gitlab-org/cli), logged in. Check with `glab auth status`. For a self-hosted GitLab, log in with `glab auth login --hostname <your GitLab host>`.

Run Neovim inside a git repository whose remote is on GitLab. The plugin picks up the project from there, just like `glab` does.

## Installation

### lazy.nvim / LazyVim

Save this as `lua/plugins/gitlab.lua` in your Neovim config:

```lua
return {
  {
    "bassepeder/snacks-gitlab.nvim",
    dependencies = { "folke/snacks.nvim" },
    cmd = "GitLab",
    keys = {
      { "<leader>gp", function() require("snacks-gitlab").mr() end, desc = "GitLab MRs (open)" },
      { "<leader>gP", function() require("snacks-gitlab").mr({ state = "all" }) end, desc = "GitLab MRs (all)" },
      { "<leader>gi", function() require("snacks-gitlab").issue() end, desc = "GitLab Issues (open)" },
      { "<leader>gI", function() require("snacks-gitlab").issue({ state = "all" }) end, desc = "GitLab Issues (all)" },
      { "<leader>ga", function() require("snacks-gitlab").current() end, desc = "GitLab: actions for this branch's MR" },
    },
    opts = {},
  },
}
```

LazyVim binds `<leader>gi/gI/gp/gP` to its GitHub pickers. If you only use GitLab, switch those off by adding this to your snacks spec:

```lua
{
  "folke/snacks.nvim",
  keys = {
    { "<leader>gi", false },
    { "<leader>gI", false },
    { "<leader>gp", false },
    { "<leader>gP", false },
  },
}
```

Otherwise, pick other keys for the GitLab pickers.

### Without a plugin manager

Clone the repo anywhere, then:

```lua
vim.opt.rtp:append("/path/to/snacks-gitlab.nvim")
require("snacks-gitlab").setup()
```

## Usage

1. Press `<leader>gp` (or run `:GitLab mr`) to list open merge requests.
2. Type to search. The search runs on GitLab, so it matches titles and descriptions.
3. Press `<cr>` on an MR for the actions menu. Pick **View diff** to review it, or **Open in buffer** to read the discussion.
4. In the diff preview, move to a line and press `a` to comment on it, or `s` to suggest a change. To comment on several lines, select them first with `V`. Lines with comments show the thread right underneath.

### Commands

```vim
:GitLab mr                                  " open MRs
:GitLab mr state=all scope=created_by_me    " every MR you created
:GitLab mr reviewer=<username> draft=false  " MRs waiting for your review
:GitLab issue labels=bug
:GitLab current                             " actions for the open MR of the current branch
```

### Picker options

These can be passed as `key=value` to `:GitLab`, or as a table to `mr()` / `issue()`, together with any normal Snacks picker option:

| Option | Description |
| --- | --- |
| `state` | `"opened"` (default), `"closed"`, `"merged"`, `"all"` |
| `scope` | `"all"` (default), `"created_by_me"`, `"assigned_to_me"` |
| `author`, `assignee`, `reviewer` | GitLab usernames |
| `labels` | comma-separated label names |
| `milestone`, `target_branch` | |
| `draft` | `true` = drafts only, `false` = no drafts |
| `project`, `host` | browse a project other than the current repo, e.g. `project = "group/project"` |
| `limit` | number of items to fetch, default 50 (max 100) |

## Keys

> **Key notation:** `<cr>` is Enter, `<c-s>` is Ctrl+S, `<a-b>` is Alt+B (Option+B on macOS), and `<leader>` is your leader key (Space in LazyVim). Single letters like `a` are pressed in normal mode.

### In the MR / issue picker

| Key | Action |
| --- | --- |
| `<cr>` | actions menu |
| `<c-s>` / `<c-v>` / `<c-t>` | open the MR in a horizontal split / vertical split / tab |
| `<a-d>` | view diff |
| `<a-b>` | open in browser |
| `<a-c>` | comment |
| `<a-o>` | check out the MR branch |
| `<c-y>` (or `y` in the list) | copy URL |

### In an MR / issue buffer

| Key | Action |
| --- | --- |
| `<cr>` | actions menu (includes reply/resolve when the cursor is on a comment) |
| `d` | view diff |
| `a` | add a comment |
| `r` | reply to the thread under the cursor |
| `x` | resolve / unresolve the thread under the cursor |
| `c` / `o` | close / reopen |
| `gx` | open in browser |
| `R` | refresh |

### In the diff view (preview window)

Move into the preview with your usual Snacks key (`<a-w>` cycles windows by default), then:

| Key | Action |
| --- | --- |
| `a` | comment on the line under the cursor, or on the selected lines (offers reply/resolve if the line already has a thread) |
| `s` | suggest a change to the line or selected lines. The comment window opens with GitLab's suggestion block, pre-filled with the current code |
| `r` | reply to the thread on this line |
| `x` | resolve / unresolve the thread on this line |
| `<cr>` | MR actions menu (approve, merge, …) |

To select several lines, press `V` (visual line mode), move down with `j`, then press `a` or `s`. A selection has to be one continuous block of the diff. Suggestions only cover added or unchanged lines, since removed lines no longer exist in the new version.

In the file list, `<cr>` opens the file from your local checkout. On the **Outdated comments** entry it jumps into the preview, where `r` and `x` work on the comment under the cursor.

## Configuration

Everything is optional. These are the defaults you're most likely to change:

```lua
require("snacks-gitlab").setup({
  limit = 50, -- items per picker
  keys = { -- keys in MR / issue buffers
    close = false, -- disable a key
    approve = { "A", "gl_approve", desc = "Approve" }, -- bind any action
  },
  scratch = { height = 15 }, -- height of the comment window
})
```

Action names you can bind: `gl_actions`, `gl_open`, `gl_diff`, `gl_browse`, `gl_yank`, `gl_checkout`, `gl_comment`, `gl_reply`, `gl_resolve`, `gl_unresolve`, `gl_toggle_resolve`, `gl_edit`, `gl_approve`, `gl_unapprove`, `gl_merge`, `gl_auto_merge`, `gl_ready`, `gl_draft`, `gl_labels`, `gl_close`, `gl_reopen`.

To add your own, extend `require("snacks-gitlab.actions").actions`.
