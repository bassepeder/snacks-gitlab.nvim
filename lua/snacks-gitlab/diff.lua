--- Merge request diff picker with inline review comments.
---
--- * comments on the current version of a line are shown under that line
--- * comments left on an older commit are moved to where that line is now;
---   if the line itself changed, they are listed under "Outdated comments"
--- * `a` comments on a line (or a visual selection), `s` suggests a change,
---   `r` replies and `x` resolves the thread under the cursor
local Api = require("snacks-gitlab.api")
local Item = require("snacks-gitlab.item")
local Render = require("snacks-gitlab.render")
local sha1 = require("snacks-gitlab.sha1")

local M = {}

---@class snacks.gitlab.diff.Row one line of a file's MR diff
---@field old number old-file line counter (GitLab `old_pos`)
---@field new number new-file line counter (GitLab `new_pos`)
---@field type "context"|"add"|"del"

---@class snacks.gitlab.diff.Rows
---@field right table<number, snacks.gitlab.diff.Row> by new line (added + unchanged)
---@field left table<number, snacks.gitlab.diff.Row> by old line (removed + unchanged)
---@field old_path string
---@field new_path string

---@class snacks.gitlab.Discussion
---@field id string
---@field raw table the discussion from the API
---@field notes table[] non-system notes
---@field info snacks.gitlab.Thread id/author/resolved state, shared with buffer actions
---@field pos table the first note's position
---@field side "left"|"right"
---@field file string path the comment was made on
---@field line number line the comment was made on
---@field moved? boolean shown at a different line than it was made on
---@field reason? string why it can't be shown in the diff

--- Diff threads (discussions anchored to a line) from the discussions API
---@param discussions table[]
---@return snacks.gitlab.Discussion[]
function M.threads(discussions)
  local ret = {} ---@type snacks.gitlab.Discussion[]
  for _, d in ipairs(discussions or {}) do
    local first = d.notes and d.notes[1]
    local pos = first and first.position
    if type(pos) == "table" and pos.position_type == "text" and (pos.new_line or pos.old_line) then
      ret[#ret + 1] = {
        id = d.id,
        raw = d,
        notes = vim.tbl_filter(function(n)
          return not n.system
        end, d.notes),
        info = Render.thread(d),
        pos = pos,
        side = pos.new_line and "right" or "left",
        file = pos.new_line and pos.new_path or pos.old_path,
        line = pos.new_line or pos.old_line,
      }
    end
  end
  return ret
end

--- Rows of a single file's diff, indexed by line number on each side
---@param diff string[] hunk lines (starting with "@@")
---@return snacks.gitlab.diff.Rows
function M.rows(diff)
  local right, left = {}, {} ---@type table<number, snacks.gitlab.diff.Row>, table<number, snacks.gitlab.diff.Row>
  local old, new ---@type number?, number?
  for _, l in ipairs(diff) do
    local o, n = l:match("^@@+ %-(%d+)[,%d]* %+(%d+)")
    if o then
      old, new = tonumber(o), tonumber(n)
    elseif old and new then
      local c = l:sub(1, 1)
      if c == "+" then
        right[new] = { old = old, new = new, type = "add" }
        new = new + 1
      elseif c == "-" then
        left[old] = { old = old, new = new, type = "del" }
        old = old + 1
      elseif c == " " or l == "" then
        local row = { old = old, new = new, type = "context" }
        right[new], left[old] = row, row
        old, new = old + 1, new + 1
      end
    end
  end
  return { right = right, left = left, old_path = "", new_path = "" }
end

--- Where does `line` of the old file end up in the new file?
--- `nil` when that line was changed or removed.
---@param diff string unified diff hunks of one file
---@param line number
---@return number?
function M.translate(diff, line)
  local delta = 0
  local lines = vim.split(diff, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local os, oc, ns, nc = lines[i]:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os then
      os, ns = tonumber(os), tonumber(ns) --[[@as number]]
      oc, nc = oc == "" and 1 or tonumber(oc), nc == "" and 1 or tonumber(nc) --[[@as number]]
      if (oc > 0 and line < os) or (oc == 0 and line <= os) then
        return line + delta
      end
      if oc > 0 and line < os + oc then
        -- the line is inside this hunk: it only survives as an unchanged line
        local o, n = os, ns
        i = i + 1
        while i <= #lines and not lines[i]:find("^@@") do
          local c = lines[i]:sub(1, 1)
          if c == " " then
            if o == line then
              return n
            end
            o, n = o + 1, n + 1
          elseif c == "-" then
            if o == line then
              return nil
            end
            o = o + 1
          elseif c == "+" then
            n = n + 1
          end
          i = i + 1
        end
        return nil
      end
      local old_next = oc == 0 and os + 1 or os + oc
      local new_next = nc == 0 and ns + 1 or ns + nc
      delta = new_next - old_next
    end
    i = i + 1
  end
  return line + delta
end

--- Moves threads left on older commits to their line in the current diff.
--- Threads that can't be shown get a `reason`.
---@async
---@param item snacks.gitlab.Item
---@param threads snacks.gitlab.Discussion[]
---@param refs {base_sha:string, head_sha:string}
---@param files table<string, snacks.gitlab.diff.Rows> by diff file key
---@param alias table<string, string> any path -> diff file key
function M.place(item, threads, refs, files, alias)
  local compares = {} ---@type table<string, table|false>
  local function compare(from, to)
    local key = from .. ".." .. to
    if compares[key] == nil then
      compares[key] = Api.await({
        host = item.host,
        endpoint = ("projects/%s/repository/compare"):format(Api.project(item.project)),
        query = { from = from, to = to, straight = true },
        notify = false,
      }) or false
    end
    return compares[key]
  end

  for _, t in ipairs(threads) do
    local from = t.side == "right" and t.pos.head_sha or t.pos.base_sha
    local to = t.side == "right" and refs.head_sha or refs.base_sha
    local file, line = t.file, t.line ---@type string, number?
    if from and to and from ~= to then
      local cmp = compare(from, to)
      if not cmp then
        line = nil
      else
        for _, fd in ipairs(cmp.diffs or {}) do
          if fd.old_path == file then
            if fd.deleted_file then
              line = nil
            else
              line = M.translate(fd.diff or "", line)
              file = fd.new_path or file
            end
            break
          end
        end
      end
    end
    local key = alias[file]
    local rows = key and files[key]
    local row = line and rows and (t.side == "right" and rows.right[line] or rows.left[line])
    if row then
      t.moved = line ~= t.line
      t.file, t.line = key, line --[[@as number]]
    elseif not line then
      t.reason = "The code it was left on has changed since."
    else
      t.reason = "The line is no longer part of this merge request's changes."
    end
  end
end

--- Snacks diff annotations (rendered as boxes under the commented line)
---@param threads snacks.gitlab.Discussion[]
---@return snacks.diff.Annotation[]
function M.annotations(threads)
  local ret = {} ---@type snacks.diff.Annotation[]
  for _, t in ipairs(threads) do
    local text = {} ---@type snacks.picker.Highlight[][]
    for i, note in ipairs(t.notes) do
      if i > 1 then
        text[#text + 1] = { { "" } }
      end
      local header = {
        { (i > 1 and "↳ " or "") .. "@" .. (note.author and note.author.username or "?"), "SnacksPickerGitAuthor" },
        { " · " .. Snacks.picker.util.reltime(Item.ts(note.created_at) or os.time()), "SnacksPickerDimmed" },
      }
      if i == 1 and t.info.resolvable then
        local resolved = t.info.resolved
        header[#header + 1] =
          { resolved and "  resolved" or "  unresolved", resolved and "SnacksPickerDimmed" or "DiagnosticWarn" }
      end
      if i == 1 and t.moved then
        header[#header + 1] = { "  (made on an earlier version)", "SnacksPickerDimmed" }
      end
      text[#text + 1] = header
      for _, l in ipairs(vim.split((note.body or ""):gsub("\r\n", "\n"), "\n", { plain = true })) do
        text[#text + 1] = { { l } }
      end
    end
    ret[#ret + 1] = { file = t.file, side = t.side, line = t.line, text = text }
  end
  return ret
end

--- Picker entry listing the threads that can't be shown in the diff,
--- with the code they were originally left on.
---@async
---@param item snacks.gitlab.Item
---@param threads snacks.gitlab.Discussion[]
function M.outdated_item(item, threads)
  local lines, rows = {}, {} ---@type string[], table<number, snacks.gitlab.Thread>
  local function add(l)
    lines[#lines + 1] = l
  end
  add(("# Outdated comments (%d)"):format(#threads))
  add("")
  add("These comments can't be shown in the diff. `r` replies, `x` resolves.")
  add("")
  for _, t in ipairs(threads) do
    local start = #lines + 1
    local block = Render.discussion(t.raw, t.info)
    -- original code around the commented line
    local path = t.side == "right" and t.pos.new_path or t.pos.old_path
    local sha = t.side == "right" and t.pos.head_sha or t.pos.base_sha
    local code = {} ---@type string[]
    local src = sha
      and Api.await({
        host = item.host,
        endpoint = ("projects/%s/repository/files/%s/raw"):format(Api.project(item.project), Api.urlencode(path)),
        query = { ref = sha },
        raw = true,
        notify = false,
      })
    if type(src) == "string" then
      local file_lines = vim.split(src, "\n", { plain = true })
      local w = #tostring(math.min(t.line + 3, #file_lines))
      for l = math.max(1, t.line - 3), math.min(#file_lines, t.line + 3) do
        local nr = (" "):rep(w - #tostring(l)) .. l
        code[#code + 1] = ("%s %s │ %s"):format(l == t.line and "▶" or " ", nr, file_lines[l])
      end
    end
    -- header line, then the explanation and code, then the comment body
    add(block[1])
    add("")
    add(("_%s Left on `%s` (%s)._"):format(t.reason or "", sha and sha:sub(1, 8) or "?", t.side == "right" and "new" or "old"))
    if #code > 0 then
      add("")
      add("```" .. (path:match("%.(%w+)$") or ""))
      vim.list_extend(lines, code)
      add("```")
    end
    for i = 2, #block do
      add(block[i])
    end
    for l = start, #lines do
      rows[l] = t.info
    end
  end
  return {
    text = "Outdated comments",
    gl_outdated = true,
    gl_item = item,
    gl_rows = rows,
    preview = { text = table.concat(lines, "\n"), ft = "markdown", loc = false },
  }
end

--- diff_refs are only returned by the single-MR endpoint
---@param item snacks.gitlab.Item
---@param cb fun(refs?: {base_sha:string, start_sha:string, head_sha:string})
local function diff_refs(item, cb)
  if item.raw.diff_refs then
    return cb(item.raw.diff_refs)
  end
  Api.request({ host = item.host, endpoint = Item.endpoint(item) }, function(data)
    vim.schedule(function()
      if data and data.diff_refs then
        item.raw.diff_refs = data.diff_refs
      end
      cb(data and data.diff_refs)
    end)
  end)
end

--- Preview window and the row under its cursor
---@param picker snacks.Picker
local function preview_cursor(picker)
  local win = picker.preview and picker.preview.win
  if not (win and win:valid()) then
    return
  end
  return win, vim.api.nvim_win_get_cursor(win.win)[1]
end

--- Thread under the cursor: on the commented diff line, or in "Outdated comments"
---@param picker snacks.Picker
---@param m? snacks.diff.Meta
---@return snacks.gitlab.Thread?
function M.thread_at(picker, m)
  local pitem = picker.preview and picker.preview.item
  local win, row = preview_cursor(picker)
  if pitem and pitem.gl_outdated then
    return row and pitem.gl_rows[row] or nil
  end
  if not m and win and row then
    local meta = Snacks.picker.highlight.meta(win.buf)
    m = meta and meta[row] and meta[row].diff
  end
  if not m then
    return nil
  end
  for _, t in ipairs(picker.gl_threads or {}) do
    if t.file == m.file and t.side == m.side and t.line == m.line then
      return t.info
    end
  end
end

--- Diff lines selected in the preview: the visual selection, or the cursor line
---@param picker snacks.Picker
---@return snacks.diff.Meta[]
local function selected_lines(picker)
  local win, row = preview_cursor(picker)
  if not (win and row) then
    return {}
  end
  local from, to = row, row
  local visual = Snacks.picker.util.visual() -- also leaves visual mode
  if visual and visual.buf == win.buf then
    from, to = math.min(visual.pos[1], visual.end_pos[1]), math.max(visual.pos[1], visual.end_pos[1])
  end
  local meta = Snacks.picker.highlight.meta(win.buf) or {}
  local ret = {} ---@type snacks.diff.Meta[]
  for r = from, to do
    local m = meta[r] and meta[r].diff
    if m then
      ret[#ret + 1] = m
    end
  end
  return ret
end

---@param row snacks.gitlab.diff.Row
local function row_lines(row)
  return row.type ~= "add" and row.old or nil, row.type ~= "del" and row.new or nil
end

---@param rows snacks.gitlab.diff.Rows
---@param row snacks.gitlab.diff.Row
local function range_point(rows, row)
  local old_line, new_line = row_lines(row)
  return {
    line_code = ("%s_%d_%d"):format(sha1(rows.new_path), row.old, row.new),
    type = row.type == "add" and "new" or row.type == "del" and "old" or nil,
    old_line = old_line,
    new_line = new_line,
  }
end

---@param picker snacks.Picker
local function refresh(picker)
  vim.schedule(function()
    if not picker.closed then
      picker:find({ refresh = true })
    end
  end)
end

--- Reply to / resolve a thread, from a small menu
---@param picker snacks.Picker
---@param item snacks.gitlab.Item
---@param info snacks.gitlab.Thread
---@param new_thread? fun() offered as "Start a new thread"
local function thread_menu(picker, item, info, new_thread)
  local Actions = require("snacks-gitlab.actions")
  local choices = { ("Reply to @%s's thread"):format(info.author) }
  if info.resolvable then
    choices[#choices + 1] = info.resolved and "Unresolve thread" or "Resolve thread"
  end
  if new_thread then
    choices[#choices + 1] = "Start a new thread"
  end
  vim.ui.select(choices, { prompt = "Comment" }, function(choice, idx)
    if not choice then
      return
    elseif idx == 1 then
      Actions.reply(item, info, function()
        refresh(picker)
      end)
    elseif choice == "Start a new thread" then
      new_thread()
    else
      Actions.resolve(item, info, not info.resolved, function()
        refresh(picker)
      end)
    end
  end)
end

--- Comment on the selected diff line(s), or suggest a change to them
---@param picker snacks.Picker
---@param opts? {suggest?: boolean}
function M.comment(picker, opts)
  opts = opts or {}
  local file_item = picker.preview and picker.preview.item or picker:current()
  local item = file_item and file_item.gl_item ---@type snacks.gitlab.Item?
  if not (item and file_item) then
    return
  end
  if file_item.gl_outdated then
    local info = M.thread_at(picker)
    if info then
      return thread_menu(picker, item, info)
    end
    Snacks.notify.warn("Move the cursor onto a comment first", { title = "GitLab" })
    return
  end

  local metas = selected_lines(picker)
  if #metas == 0 then
    Snacks.notify.warn("Move the cursor to a diff line in the preview first", { title = "GitLab" })
    return
  end
  local file = metas[1].file
  local rows = (picker.gl_files or {})[file]
  if not rows then
    return
  end

  -- map the selection to diff rows; suggestions only work on lines of the new file
  local sel = {} ---@type {meta: snacks.diff.Meta, row: snacks.gitlab.diff.Row}[]
  for _, m in ipairs(metas) do
    local row = m.side == "right" and rows.right[m.line] or rows.left[m.line]
    if row and not (opts.suggest and row.type == "del") then
      sel[#sel + 1] = { meta = m, row = row }
    end
  end
  if #sel == 0 then
    Snacks.notify.warn(
      opts.suggest and "Suggestions can only change added or unchanged lines" or "No diff line selected",
      { title = "GitLab" }
    )
    return
  end
  -- the selection must be one continuous block: within a hunk, the line
  -- counters advance by at most one per row (they jump between hunks)
  for i = 2, #sel do
    local a, b = sel[i - 1].row, sel[i].row
    local gap = opts.suggest and (b.new - a.new ~= 1) or (b.old - a.old > 1 or b.new - a.new > 1)
    if gap then
      Snacks.notify.warn("Select lines from one continuous block of the diff", { title = "GitLab" })
      return
    end
  end
  local first, last = sel[1].row, sel[#sel].row

  local function new_thread()
    local template = ""
    if opts.suggest then
      local code = vim.tbl_map(function(s)
        return s.meta.code
      end, sel)
      template = ("```suggestion:-%d+0\n%s\n```\n"):format(#code - 1, table.concat(code, "\n"))
    end
    local name = vim.fn.fnamemodify(file, ":t")
    local function at(row)
      local o, n = row_lines(row)
      return n and ("+" .. n) or ("-" .. o)
    end
    local where = first == last and at(last) or (at(first) .. " to " .. at(last))
    require("snacks-gitlab.actions").input({
      title = ("%s on %s %s"):format(opts.suggest and "Suggest a change" or "Comment", name, where),
      text = template,
      on_submit = function(body)
        if not body:find("%S") then
          return
        end
        diff_refs(item, function(refs)
          if not refs then
            Snacks.notify.error("Could not load diff refs for " .. item.hash, { title = "GitLab" })
            return
          end
          local old_line, new_line = row_lines(last)
          local position = {
            position_type = "text",
            base_sha = refs.base_sha,
            start_sha = refs.start_sha,
            head_sha = refs.head_sha,
            old_path = rows.old_path,
            new_path = rows.new_path,
            old_line = old_line,
            new_line = new_line,
          }
          if first ~= last then
            position.line_range = { start = range_point(rows, first), ["end"] = range_point(rows, last) }
          end
          Api.request({
            host = item.host,
            method = "POST",
            endpoint = Item.endpoint(item, "/discussions"),
            body = { body = body, position = position },
          }, function(_, err)
            if not err then
              vim.schedule(function()
                Snacks.notify.info(("Commented on %s %s"):format(name, where), { title = "GitLab" })
              end)
              refresh(picker)
            end
          end)
        end)
      end,
    })
  end

  -- a single line that already has a thread: reply / resolve / new thread
  if #sel == 1 and not opts.suggest then
    local info = M.thread_at(picker, sel[1].meta)
    if info then
      return thread_menu(picker, item, info, new_thread)
    end
  end
  new_thread()
end

--- Reply to / resolve the thread under the cursor
---@param picker snacks.Picker
---@param what "reply"|"resolve"
function M.thread_action(picker, what)
  local file_item = picker.preview and picker.preview.item or picker:current()
  local item = file_item and file_item.gl_item ---@type snacks.gitlab.Item?
  local info = M.thread_at(picker)
  if not (item and info) then
    Snacks.notify.warn("Move the cursor to a comment in the preview first", { title = "GitLab" })
    return
  end
  local Actions = require("snacks-gitlab.actions")
  local function done()
    refresh(picker)
  end
  if what == "reply" then
    Actions.reply(item, info, done)
  elseif not info.resolvable then
    Snacks.notify.warn("This thread can't be resolved", { title = "GitLab" })
  else
    Actions.resolve(item, info, not info.resolved, done)
  end
end

--- Opens the diff picker for a merge request
---@param item snacks.gitlab.Item
---@param opts? snacks.picker.Config
function M.open(item, opts)
  local config = require("snacks-gitlab").config()
  local SnacksDiff = require("snacks.picker.source.diff")
  local repo_url = item.url:gsub("/%-/merge_requests/.*$", "")

  return Snacks.picker.pick(vim.tbl_deep_extend("force", {
    title = ("%sDiff %s %s"):format(config.icons.logo, item.hash, item.title),
    group = true,
    show_delay = 0,
    format = function(it, picker)
      if it.gl_outdated then
        return {
          { config.icons.issue.closed, "DiagnosticWarn" },
          { " " },
          { it.text, "DiagnosticWarn" },
        }
      end
      return Snacks.picker.format.git_status(it, picker)
    end,
    preview = function(ctx)
      if ctx.item.gl_outdated then
        return Snacks.picker.preview.preview(ctx)
      end
      return Snacks.picker.preview.diff(ctx)
    end,
    previewers = { diff = { style = "fancy" } }, -- annotations need the fancy style
    finder = function(_, ctx)
      ---@async
      return function(cb)
        local refs = item.raw.diff_refs
        if not refs then
          local full = Api.await({ host = item.host, endpoint = Item.endpoint(item) })
          refs = full and full.diff_refs
          item.raw.diff_refs = refs
        end
        local text = Api.glab_await(
          { "mr", "diff", tostring(item.iid), "--raw", "--color", "never", "-R", repo_url },
          { cwd = ctx:git_root() }
        )
        if not text then
          Snacks.notify.error("Could not load the diff of " .. item.hash, { title = "GitLab" })
          return
        end

        -- line positions per file, for comments and for placing threads
        local files, alias = {}, {} ---@type table<string, snacks.gitlab.diff.Rows>, table<string, string>
        for _, block in ipairs(SnacksDiff.parse(vim.split(text, "\n", { plain = true })).blocks) do
          local hunks = {} ---@type string[]
          for _, h in ipairs(block.hunks) do
            vim.list_extend(hunks, h.diff)
          end
          local rows = M.rows(hunks)
          rows.old_path = block.left or block.right or block.file
          rows.new_path = block.right or block.left or block.file
          files[block.file] = rows
          alias[block.file], alias[rows.old_path], alias[rows.new_path] = block.file, block.file, block.file
        end

        local discussions = Api.await({
          host = item.host,
          endpoint = Item.endpoint(item, "/discussions"),
          query = { per_page = 100 },
          paginate = true,
        })
        local threads = M.threads(discussions or {})
        if refs then
          M.place(item, threads, refs, files, alias)
        end
        local placed = vim.tbl_filter(function(t)
          return not t.reason
        end, threads)
        local outdated = vim.tbl_filter(function(t)
          return t.reason ~= nil
        end, threads)
        ctx.picker.gl_threads = placed
        ctx.picker.gl_files = files

        if #outdated > 0 then
          cb(M.outdated_item(item, outdated))
        end
        SnacksDiff.diff(
          ctx:opts({
            diff = text,
            cwd = ctx:git_root(),
            annotations = M.annotations(placed),
            group = true,
          }),
          ctx
        )(function(it)
          it.gl_item = item
          cb(it)
        end)
      end
    end,
    actions = {
      confirm = function(picker, it, action)
        if it and it.gl_outdated then
          return picker:focus("preview")
        end
        return Snacks.picker.actions.jump(picker, it, action)
      end,
      gl_diff_comment = {
        desc = "Comment on line(s)",
        action = function(picker)
          M.comment(picker)
        end,
      },
      gl_diff_suggest = {
        desc = "Suggest a change",
        action = function(picker)
          M.comment(picker, { suggest = true })
        end,
      },
      gl_diff_reply = {
        desc = "Reply to thread",
        action = function(picker)
          M.thread_action(picker, "reply")
        end,
      },
      gl_diff_resolve = {
        desc = "Resolve / unresolve thread",
        action = function(picker)
          M.thread_action(picker, "resolve")
        end,
      },
      gl_diff_actions = {
        desc = "MR actions",
        action = function(picker)
          require("snacks-gitlab.actions").menu(item, { picker = picker })
        end,
      },
    },
    win = {
      input = {
        keys = {
          ["<a-a>"] = { "gl_diff_actions", mode = { "n", "i" } },
        },
      },
      preview = {
        keys = {
          ["a"] = { "gl_diff_comment", mode = { "n", "x" } },
          ["s"] = { "gl_diff_suggest", mode = { "n", "x" } },
          ["r"] = "gl_diff_reply",
          ["x"] = "gl_diff_resolve",
          ["<cr>"] = "gl_diff_actions",
        },
      },
    },
  }, opts or {}))
end

return M
