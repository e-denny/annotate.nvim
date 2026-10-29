-- annotate.nvim
--
-- Review-annotation mode for Markdown files, driven by Pi's `/annotate` command.
--
-- Layout: the reviewed file on the left, its `<name>.comments.md` on the right.
-- Visual selections in the reviewed file are recorded as blocks in the comments
-- file (which stays plain, human- and LLM-readable Markdown on disk) and are
-- rendered in Neovim:
--   * commented spans get a yellow background
--   * deleted spans get strikethrough
--   * every comment block is drawn as a rounded box, aligned with its span
--
-- Keymaps (visual mode in the reviewed file):
--   <leader>C  comment the selection; cursor moves into the new box
--   <leader>D  mark the selection for deletion (strikethrough)
-- <leader>C in the comments pane jumps back to the annotated text, and
-- <leader>C on an annotated span in the reviewed file jumps to its box.
-- <leader>Q finishes the review; <leader>X aborts it.

local M = {}

local api = vim.api
local fn = vim.fn

local NS_MARKS = api.nvim_create_namespace("annotate.marks")
local NS_BOX = api.nvim_create_namespace("annotate.box")

-- The box outline is drawn on top of anything else on its rows, so another
-- plugin decorating the sidecar (completion ghost text, markdown renderers)
-- cannot displace or hide it.
local PRIO_BORDER = 65535

local MARKER_PAT = "^<!%-%-%s*annotate:#(%d+)%s+(%d+):(%d+)%-(%d+):(%d+)%s+([%a_]+)%s*%-%->$"
local END_MARKER = "<!-- /annotate -->"

local S = {
  ready = false,
  main_buf = nil,
  comments_buf = nil,
  main_win = nil,
  comments_win = nil,
  main_path = nil,
  comments_path = nil,
  blocks = {},
  marks = {},     -- annotation id -> extmark id in the reviewed buffer
  anchors = {},   -- annotation id -> { srow, scol, erow, ecol }
  next_id = 1,
  active_id = nil,
  last_id = nil,
  render_pending = false,
  layout_pending = false,
}

M.config = {
  width_ratio = 0.42,
  min_width = 34,
  max_width = 90,
  map_comment = "<leader>C",
  map_delete = "<leader>D",
  map_finish = "<leader>Q",
  map_abort = "<leader>X",
  scroll_sync = true,
  autosave = true,
  autoformat = true,
  -- Annotate buffers are for writing prose, not code: keep completion popups
  -- out of them. Buffer-local, so the rest of Neovim is untouched.
  disable_completion = true,
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function disp(s)
  return fn.strdisplaywidth(s or "")
end

local function rep(s, n)
  return n > 0 and string.rep(s, n) or ""
end

local function notify(msg, level)
  vim.notify("annotate: " .. msg, level or vim.log.levels.INFO)
end

local function pretty_key(lhs)
  local leader = vim.g.mapleader
  if leader == nil or leader == "" then
    leader = "\\"
  elseif leader == " " then
    leader = "<Space>"
  end
  return (lhs:gsub("<leader>", leader))
end

local function define_highlights()
  local dark = vim.o.background ~= "light"
  local groups
  if dark then
    groups = {
      AnnotateComment = { bg = "#4c4400", fg = "#ffe58a" },
      AnnotateCommentActive = { bg = "#5f5600", fg = "#fff3b8", bold = true },
      AnnotateDelete = { fg = "#8c8c8c", strikethrough = true },
      AnnotateDeleteActive = { fg = "#c0c0c0", strikethrough = true, bold = true },
      AnnotateBox = { fg = "#7aa2f7" },
      AnnotateBoxComment = { fg = "#7aa2f7", bold = true },
      AnnotateBoxDelete = { fg = "#f7768e", bold = true },
      AnnotateBoxActive = { fg = "#ffd75f", bold = true },
    }
  else
    groups = {
      AnnotateComment = { bg = "#fff2a8", fg = "#4b3d00" },
      AnnotateCommentActive = { bg = "#ffe066", fg = "#3d3100", bold = true },
      AnnotateDelete = { fg = "#a0a0a0", strikethrough = true },
      AnnotateDeleteActive = { fg = "#6c6c6c", strikethrough = true, bold = true },
      AnnotateBox = { fg = "#1e66f5" },
      AnnotateBoxComment = { fg = "#1e66f5", bold = true },
      AnnotateBoxDelete = { fg = "#d20f39", bold = true },
      AnnotateBoxActive = { fg = "#b8860b", bold = true },
    }
  end
  for name, spec in pairs(groups) do
    api.nvim_set_hl(0, name, spec)
  end
end

--------------------------------------------------------------------------------
-- comments file format
--------------------------------------------------------------------------------

local function marker_line(b, a)
  return string.format("<!-- annotate:#%d %d:%d-%d:%d %s -->", b.id, a.srow, a.scol, a.erow, a.ecol, b.kind)
end

local function header_line(main_path)
  return string.format("<!-- annotate:source %s -->", fn.fnamemodify(main_path, ":t"))
end

local function parse_blocks()
  local lines = api.nvim_buf_get_lines(S.comments_buf, 0, -1, false)
  local blocks = {}
  local max_id = 0
  local i = 1
  while i <= #lines do
    local id, sr, sc, er, ec, kind = lines[i]:match(MARKER_PAT)
    if id then
      local end_row = nil
      local j = i + 1
      while j <= #lines do
        if lines[j] == END_MARKER then
          end_row = j
          break
        end
        j = j + 1
      end
      blocks[#blocks + 1] = {
        id = tonumber(id),
        kind = kind,
        srow = tonumber(sr),
        scol = tonumber(sc),
        erow = tonumber(er),
        ecol = tonumber(ec),
        marker_row = i,
        end_row = end_row,
        text_first = i + 1,
        text_last = end_row and (end_row - 1) or #lines,
      }
      max_id = math.max(max_id, tonumber(id))
      i = end_row and (end_row + 1) or (#lines + 1)
    else
      i = i + 1
    end
  end
  S.blocks = blocks
  S.next_id = max_id + 1
  return blocks
end

local function comment_box_width()
  local win_w = S.comments_win and api.nvim_win_is_valid(S.comments_win) and api.nvim_win_get_width(S.comments_win) or 60
  return math.max(24, win_w - 1)
end

local function text_box_width()
  return math.max(8, comment_box_width() - 4)
end

--- Keep the sidecar's own wrapping in step with the box. The border is drawn at
--- a fixed column, so its text must break before that column: 'textwidth' plus
--- the 't' flag in 'formatoptions' breaks a note line as it is typed, and
--- reflow_all() (below) re-wraps lines that arrive already too long.
local function apply_textwidth()
  if not (S.comments_buf and api.nvim_buf_is_valid(S.comments_buf)) then
    return
  end
  api.nvim_set_option_value("textwidth", text_box_width(), { buf = S.comments_buf })
  local fo = api.nvim_get_option_value("formatoptions", { buf = S.comments_buf })
  if not fo:find("t", 1, true) then
    api.nvim_set_option_value("formatoptions", fo .. "t", { buf = S.comments_buf })
  end
end

local function top_border(box_w, label, hl)
  local pad = box_w - 5 - disp(label)
  local width = box_w
  if pad < 0 then
    pad = 0
    width = 5 + disp(label)
  end
  return "╭─ " .. label .. " " .. rep("─", pad) .. "╮", width
end

local function bottom_border(box_w)
  return "╰" .. rep("─", math.max(0, box_w - 2)) .. "╯"
end

local function label_for(b)
  local kind = b.kind == "delete" and "delete" or "comment"
  return string.format("%d:%d → %d:%d  %s", b.srow, b.scol, b.erow, b.ecol, kind)
end

local function conceal_row(row, text)
  if not text or #text == 0 then
    return
  end
  api.nvim_buf_set_extmark(S.comments_buf, NS_BOX, row, 0, { end_col = #text, conceal = "" })
end

--- Draw every comment block as a rounded box in the comments pane.
function M.render_boxes()
  if not (S.comments_buf and api.nvim_buf_is_valid(S.comments_buf)) then
    return
  end
  api.nvim_buf_clear_namespace(S.comments_buf, NS_BOX, 0, -1)

  local box_w = comment_box_width()
  local lines = api.nvim_buf_get_lines(S.comments_buf, 0, -1, false)

  for _, b in ipairs(S.blocks) do
    local is_active = S.active_id == b.id
    local border_hl = is_active and "AnnotateBoxActive"
      or (b.kind == "delete" and "AnnotateBoxDelete" or "AnnotateBoxComment")

    local row = b.marker_row - 1
    local top, width = top_border(box_w, label_for(b), border_hl)
    conceal_row(row, lines[b.marker_row])
    -- Draw the border as overlay text anchored to the window column: 'inline'
    -- text would be counted towards the line width, and because the concealed
    -- marker still contributes to that width the border would wrap onto a
    -- second screen line and push the whole box out of alignment.
    api.nvim_buf_set_extmark(S.comments_buf, NS_BOX, row, 0, {
      virt_text = { { top, border_hl } },
      virt_text_pos = "overlay",
      virt_text_win_col = 0,
      priority = PRIO_BORDER,
    })

    for r = b.text_first, b.text_last do
      local idx = r - 1
      -- Left border: an inline spacer keeps the buffer text two cells inside
      -- the box, and the border itself is an overlay pinned to window column
      -- 0. These are the rows where other plugins add inline virtual text of
      -- their own; chunks at the same column are ordered by priority first,
      -- and the *lowest* priority is drawn leftmost, with ties going to the
      -- chunk that was inserted first. An inline border therefore slips to
      -- the right as soon as such a chunk predates the last redraw. An
      -- overlay cannot be displaced; it covers only the spacer's own cells.
      api.nvim_buf_set_extmark(S.comments_buf, NS_BOX, idx, 0, {
        virt_text = { { "  " } },
        virt_text_pos = "inline",
      })
      api.nvim_buf_set_extmark(S.comments_buf, NS_BOX, idx, 0, {
        virt_text = { { "│", border_hl } },
        virt_text_pos = "overlay",
        virt_text_win_col = 0,
        priority = PRIO_BORDER,
      })
      -- Right border: also pinned to a fixed window column. Anchoring it to
      -- the end of the line ('eol') cannot stay aligned, because 'eol'
      -- virtual text is placed after every virtual text chunk on the line --
      -- the same ghost text pushes it out of the box, and off the window
      -- entirely once the text is wide enough.
      api.nvim_buf_set_extmark(S.comments_buf, NS_BOX, idx, 0, {
        virt_text = { { "│", border_hl } },
        virt_text_pos = "overlay",
        virt_text_win_col = width - 1,
        priority = PRIO_BORDER,
      })
    end

    if b.end_row then
      local orow = b.end_row - 1
      conceal_row(orow, lines[b.end_row])
      api.nvim_buf_set_extmark(S.comments_buf, NS_BOX, orow, 0, {
        virt_text = { { bottom_border(width), border_hl } },
        virt_text_pos = "overlay",
        virt_text_win_col = 0,
        priority = PRIO_BORDER,
      })
    end
  end

  -- hide metadata comment lines: the panel should show boxes only
  for idx, text in ipairs(lines) do
    if text:match("^<!%-%-") and text:match("%-%->$") then
      conceal_row(idx - 1, text)
    end
  end
end

--- Read the live (edit-tracked) extmark positions back into S.anchors.
local function sync_anchors_from_marks()
  if not (S.main_buf and api.nvim_buf_is_valid(S.main_buf)) then
    return
  end
  local ok, marks = pcall(api.nvim_buf_get_extmarks, S.main_buf, NS_MARKS, 0, -1, { details = true })
  if not ok then
    return
  end
  -- extmark ids are Neovim's own numbering, so map them back to annotation ids
  local by_mark = {}
  for ann_id, mark_id in pairs(S.marks) do
    by_mark[mark_id] = ann_id
  end
  for _, m in ipairs(marks) do
    local ann_id = by_mark[m[1]]
    if ann_id then
      local row, col = m[2], m[3]
      local details = m[4] or {}
      local end_row = details.end_row or row
      local end_col = details.end_col or col
      S.anchors[ann_id] = { srow = row + 1, scol = col + 1, erow = end_row + 1, ecol = end_col }
    end
  end
end

--- Highlight the annotated spans in the reviewed file.
function M.render_marks()
  if not (S.main_buf and api.nvim_buf_is_valid(S.main_buf)) then
    return
  end
  sync_anchors_from_marks()
  local live = {}
  for _, b in ipairs(S.blocks) do
    live[b.id] = true
    local a = S.anchors[b.id]
    if not a then
      a = { srow = b.srow, scol = b.scol, erow = b.erow, ecol = b.ecol }
      S.anchors[b.id] = a
    end
    local hl
    if b.kind == "delete" then
      hl = S.active_id == b.id and "AnnotateDeleteActive" or "AnnotateDelete"
    else
      hl = S.active_id == b.id and "AnnotateCommentActive" or "AnnotateComment"
    end
    local mark = S.marks[b.id]
    local ok, new_id = pcall(api.nvim_buf_set_extmark, S.main_buf, NS_MARKS, a.srow - 1, a.scol - 1, {
      id = mark,
      end_row = a.erow - 1,
      end_col = a.ecol,
      hl_group = hl,
      priority = 210,
      right_gravity = false,
      end_right_gravity = true,
      strict = false,
    })
    if ok then
      S.marks[b.id] = new_id
    else
      S.marks[b.id] = nil
    end
  end
  for id, mark in pairs(S.marks) do
    if not live[id] then
      pcall(api.nvim_buf_del_extmark, S.main_buf, NS_MARKS, mark)
      S.marks[id] = nil
      S.anchors[id] = nil
    end
  end
end

--- Re-parse the comments buffer and redraw both sides.
---
--- `reflow_all` is defined further down, next to the wrapping helpers; the
--- forward declaration is what lets `refresh` call it.
local reflow_all
function M.refresh()
  if not S.ready then
    return
  end
  parse_blocks()
  apply_textwidth()
  if M.config.autoformat and reflow_all() then
    parse_blocks()
  end
  M.render_marks()
  M.relayout()
  M.render_boxes()
end

local function schedule_refresh()
  if S.render_pending then
    return
  end
  S.render_pending = true
  vim.schedule(function()
    S.render_pending = false
    M.refresh()
  end)
end

--- Write live anchor positions back into the markers of the comments file.
function M.rewrite_markers()
  if not (S.comments_buf and api.nvim_buf_is_valid(S.comments_buf)) then
    return
  end
  sync_anchors_from_marks()
  local changed = false
  for _, b in ipairs(S.blocks) do
    local a = S.anchors[b.id]
    if a then
      local want = marker_line(b, a)
      local have = api.nvim_buf_get_lines(S.comments_buf, b.marker_row - 1, b.marker_row, false)[1]
      if have ~= want then
        api.nvim_buf_set_lines(S.comments_buf, b.marker_row - 1, b.marker_row, false, { want })
        changed = true
      end
    end
  end
  if changed then
    parse_blocks()
    M.render_boxes()
  end
  return changed
end

--- Blocks are laid out so that each marker sits on the line number it points
--- at in the reviewed file, padded with blank lines when needed. That way the
--- comments file lines up with the document line by line and both windows can
--- share a single 'scrollbind'.
local function desired_layout()
  sync_anchors_from_marks()
  local blocks = {}
  for _, b in ipairs(S.blocks) do
    blocks[#blocks + 1] = b
  end
  table.sort(blocks, function(x, y)
    local ax = S.anchors[x.id] or x
    local ay = S.anchors[y.id] or y
    if ax.srow ~= ay.srow then
      return ax.srow < ay.srow
    end
    return ax.scol < ay.scol
  end)

  local out, row = {}, 1
  local function push(line)
    out[#out + 1] = line
    row = row + 1
  end

  push(header_line(S.main_path))
  for _, b in ipairs(blocks) do
    local a = S.anchors[b.id] or b
    while row < a.srow do
      push("")
    end
    push(marker_line(b, a))
    for _, l in ipairs(api.nvim_buf_get_lines(S.comments_buf, b.text_first - 1, b.text_last, false)) do
      push(l)
    end
    push(END_MARKER)
    push("")
  end
  return out
end

--- Apply the layout, touching only the span that actually differs.
function M.relayout()
  if not S.ready or not (S.comments_buf and api.nvim_buf_is_valid(S.comments_buf)) then
    return false
  end
  if not api.nvim_get_option_value("modifiable", { buf = S.comments_buf }) then
    return false
  end
  if fn.mode(1):match("^[iR]") then
    S.layout_pending = true
    return false
  end
  local desired = desired_layout()
  local current = api.nvim_buf_get_lines(S.comments_buf, 0, -1, false)

  local first = 1
  while first <= #current and first <= #desired and current[first] == desired[first] do
    first = first + 1
  end
  local last_c, last_d = #current, #desired
  while last_c >= first and last_d >= first and current[last_c] == desired[last_d] do
    last_c = last_c - 1
    last_d = last_d - 1
  end
  if first > last_c and first > last_d then
    return false
  end

  local replacement = {}
  for i = first, last_d do
    replacement[#replacement + 1] = desired[i]
  end
  api.nvim_buf_set_lines(S.comments_buf, first - 1, last_c, false, replacement)
  parse_blocks()
  M.render_boxes()
  return true
end

function M.save_comments()
  if not (S.comments_buf and api.nvim_buf_is_valid(S.comments_buf)) then
    return
  end
  if not api.nvim_get_option_value("modifiable", { buf = S.comments_buf }) then
    return
  end
  if not api.nvim_get_option_value("modified", { buf = S.comments_buf }) then
    return
  end
  local ok, err = pcall(function()
    api.nvim_buf_call(S.comments_buf, function()
      vim.cmd("silent noautocmd write")
    end)
  end)
  if not ok then
    notify("could not save " .. S.comments_path .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

--------------------------------------------------------------------------------
-- annotations
--------------------------------------------------------------------------------

local function find_block_at_cursor()
  local win = api.nvim_get_current_win()
  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1], pos[2]
  if api.nvim_win_get_buf(win) == S.main_buf then
    for _, b in ipairs(S.blocks) do
      local a = S.anchors[b.id] or b
      if row >= a.srow and row <= a.erow then
        if (row > a.srow or col >= a.scol - 1) and (row < a.erow or col < a.ecol) then
          return b
        end
      end
    end
  else
    for _, b in ipairs(S.blocks) do
      local last = b.end_row or b.text_last
      if row >= b.marker_row and row <= last then
        return b
      end
    end
  end
end

local function update_active()
  local b = find_block_at_cursor()
  local id = b and b.id or nil
  if id ~= S.active_id then
    S.active_id = id
    schedule_refresh()
  end
end

local function col_exclusive(line, col1)
  local ci = fn.charidx(line, col1 - 1)
  if ci < 0 then
    return #line
  end
  local bi = fn.byteidx(line, ci + 1)
  return bi >= 0 and bi or #line
end

--- Range of the current visual selection, as anchor fields.
--- Leave visual mode from inside a visual-mode mapping. This also writes the
--- '< / '> marks, which are only valid once visual mode has ended.
local function exit_visual()
  if fn.mode(1):match("^[vV\22]") then
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
end

--- Range of the current visual selection, as anchor fields.
local function visual_range()
  -- mode(1) is the live mode inside a mapping; visualmode() and the '< / '>
  -- marks are both stale there, so read the mode first, then leave visual mode
  -- (which updates the marks) and read the marks.
  local mode = fn.mode(1)
  exit_visual()
  local lt = fn.getpos("'<")
  local gt = fn.getpos("'>")
  if lt[2] == 0 or gt[2] == 0 then
    return nil
  end
  local srow, scol = lt[2], lt[3]
  local erow, ecol = gt[2], gt[3]
  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow = erow, srow
    scol, ecol = ecol, scol
  end
  local lines = api.nvim_buf_get_lines(S.main_buf, srow - 1, erow, false)
  local last = lines[#lines] or ""
  if mode == "V" then
    scol = 1
    ecol = #last
  else
    if mode == "\22" and scol > ecol then
      scol, ecol = ecol, scol
    end
    ecol = col_exclusive(last, ecol)
    if ecol == 0 and erow > srow then
      -- selection stops at the very start of a line: record it as ending at the
      -- end of the previous line, which keeps quotes free of a trailing empty line
      erow = erow - 1
      ecol = #(api.nvim_buf_get_lines(S.main_buf, erow - 1, erow, false)[1] or "")
    end
    if scol < 1 then
      scol = 1
    end
  end
  return { srow = srow, scol = scol, erow = erow, ecol = math.max(ecol, scol - 1) }
end

local function same_range(a, b)
  return a.srow == b.srow and a.scol == b.scol and a.erow == b.erow and a.ecol == b.ecol
end

local function find_block_for_range(r)
  for _, b in ipairs(S.blocks) do
    if same_range(b, r) then
      return b
    end
  end
end

--- Insert a new block, keeping the file ordered by anchor position.
local function insert_block(kind, r)
  local id = S.next_id
  S.next_id = id + 1
  local kind_name = kind == "delete" and "delete" or "comment"
  local block = {
    string.format("<!-- annotate:#%d %d:%d-%d:%d %s -->", id, r.srow, r.scol, r.erow, r.ecol, kind_name),
  }
  if kind == "delete" then
    local text = api.nvim_buf_get_text(S.main_buf, r.srow - 1, r.scol - 1, r.erow - 1, r.ecol, {})
    for _, l in ipairs(text) do
      block[#block + 1] = l == "" and ">" or ("> " .. l)
    end
  else
    block[#block + 1] = ""
  end
  block[#block + 1] = END_MARKER

  local at = #api.nvim_buf_get_lines(S.comments_buf, 0, -1, false) -- append at EOF by default
  for _, b in ipairs(S.blocks) do
    if b.srow > r.srow or (b.srow == r.srow and b.scol > r.scol) then
      at = b.marker_row - 1
      while at > 0 do
        local prev = api.nvim_buf_get_lines(S.comments_buf, at - 1, at, false)[1]
        if prev:match("^%s*$") or prev:match("^<!%-%-%s*annotate:source") then
          at = at - 1
        else
          break
        end
      end
      break
    end
  end

  local before = api.nvim_buf_get_lines(S.comments_buf, math.max(0, at - 1), at, false)[1]
  local payload = {}
  if before and not before:match("^%s*$") then
    payload[#payload + 1] = ""
  end
  vim.list_extend(payload, block)
  api.nvim_buf_set_lines(S.comments_buf, at, at, false, payload)

  parse_blocks()
  return id
end

local function goto_comments(id)
  local b
  for _, blk in ipairs(S.blocks) do
    if blk.id == id then
      b = blk
      break
    end
  end
  if not b then
    return
  end
  S.last_id = id
  api.nvim_set_current_win(S.comments_win)
  local target = api.nvim_buf_get_lines(S.comments_buf, b.text_first - 1, b.text_first, false)[1]
  api.nvim_win_set_cursor(S.comments_win, { b.text_first, #(target or "") })
  vim.cmd("normal! zz")
  vim.cmd("startinsert!")
end

local function goto_main(id)
  local b
  for _, blk in ipairs(S.blocks) do
    if blk.id == id then
      b = blk
      break
    end
  end
  if not b then
    return
  end
  local a = S.anchors[b.id] or b
  S.active_id = id
  api.nvim_set_current_win(S.main_win)
  local line = api.nvim_buf_get_lines(S.main_buf, a.srow - 1, a.srow, false)[1] or ""
  local col = math.min(a.scol - 1, #line)
  api.nvim_win_set_cursor(S.main_win, { a.srow, col })
  vim.cmd("normal! zz")
  schedule_refresh()
end

function M.jump_back()
  local b = find_block_at_cursor()
  local id = (b and b.id) or S.last_id
  if id then
    goto_main(id)
  end
end

--- Write the sidecar and every other modified file, then leave Neovim.
local function leave_editor()
  M.rewrite_markers()
  M.relayout()
  M.save_comments()
  local dirty = false
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf ~= S.comments_buf
      and api.nvim_buf_is_loaded(buf)
      and api.nvim_get_option_value("modified", { buf = buf }) then
      dirty = true
    end
  end
  if dirty then
    pcall(vim.cmd, "silent! wall")
  end
  local ok = pcall(vim.cmd, "qa")
  if not ok then
    vim.cmd("qa!")
  end
end

--- Save everything and leave Neovim, ending the review session.
function M.finish()
  leave_editor()
end

--- Abandon the review and leave Neovim without handing the sidecar to Pi.
---
--- The sidecar stays on disk, so reopening the review resumes the notes, and
--- unsaved edits to the reviewed file are still written out. An aborting
--- consumer (Pi's /annotate) sets $ANNOTATE_ABORT_FILE; the marker file it
--- names is how an aborted review is told apart from a finished one. Without
--- that variable, abort just closes the review.
function M.abort()
  local marker = vim.env.ANNOTATE_ABORT_FILE
  if type(marker) == "string" and marker ~= "" then
    local ok, err = pcall(fn.writefile, { "annotation aborted" }, marker)
    if not ok then
      notify("could not write abort marker: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  leave_editor()
end

function M.jump_to_comment()
  local b = find_block_at_cursor()
  if not b then
    notify("no annotation at the cursor", vim.log.levels.WARN)
    return
  end
  goto_comments(b.id)
end

--- <leader>C on a visual selection.
function M.comment_selection()
  local r = visual_range()
  if not r then
    notify("select some text first", vim.log.levels.WARN)
    return
  end
  local existing = find_block_for_range(r)
  if existing then
    goto_comments(existing.id)
    return
  end
  local id = insert_block("comment", r)
  M.refresh()
  M.save_comments()
  goto_comments(id)
end

--- <leader>D on a visual selection: mark for deletion (toggles off if present).
function M.delete_selection()
  local r = visual_range()
  if not r then
    notify("select some text first", vim.log.levels.WARN)
    return
  end
  local existing = find_block_for_range(r)
  if existing and existing.kind == "delete" then
    api.nvim_buf_set_lines(S.comments_buf, existing.marker_row - 1,
      (existing.end_row or existing.text_last) , false, {})
    pcall(api.nvim_buf_del_extmark, S.main_buf, NS_MARKS, S.marks[existing.id])
    S.marks[existing.id] = nil
    S.anchors[existing.id] = nil
    if S.active_id == existing.id then
      S.active_id = nil
    end
    M.refresh()
    M.save_comments()
    notify(string.format("removed deletion mark at %d:%d → %d:%d", r.srow, r.scol, r.erow, r.ecol))
    return
  end
  local id = insert_block("delete", r)
  M.refresh()
  M.save_comments()
  notify(string.format("marked for deletion: %d:%d → %d:%d", r.srow, r.scol, r.erow, r.ecol))
  goto_main(id)
end

--- Greedy wrap of one line of text to `width` display columns.
local function wrap_line(text, width, first_prefix, next_prefix)
  first_prefix = first_prefix or ""
  next_prefix = next_prefix or first_prefix
  local wrapped, cur, prefix = {}, "", first_prefix
  for word in text:gmatch("%S+") do
    if cur == "" then
      cur = word
    elseif disp(prefix .. cur) + 1 + disp(word) <= width then
      cur = cur .. " " .. word
    else
      wrapped[#wrapped + 1] = prefix .. cur
      prefix = next_prefix
      cur = word
    end
  end
  if cur ~= "" or #wrapped == 0 then
    wrapped[#wrapped + 1] = prefix .. cur
  end
  return wrapped
end

--- Re-wrap a block so no line is wider than the box. Returns true when the
--- buffer text changed.
---
--- A comment note is treated as one paragraph and re-flowed only when a line
--- actually overflows, so notes that already fit keep the breaks their author
--- chose. A delete block quotes one source line per buffer line, so each quote
--- is wrapped on its own and re-prefixed, which preserves the quoting.
local function reflow_block(b)
  if not b or not b.text_first or not b.text_last or b.text_last < b.text_first then
    return false
  end
  local width = text_box_width()
  local lines = api.nvim_buf_get_lines(S.comments_buf, b.text_first - 1, b.text_last, false)

  if b.kind == "delete" then
    local wrapped = {}
    for _, l in ipairs(lines) do
      local prefix, body = l:match("^(>%s?)(.*)$")
      if not prefix then
        wrapped[#wrapped + 1] = l
      else
        vim.list_extend(wrapped, wrap_line(body, width, prefix, prefix))
      end
    end
    if not vim.deep_equal(wrapped, lines) then
      api.nvim_buf_set_lines(S.comments_buf, b.text_first - 1, b.text_last, false, wrapped)
      return true
    end
    return false
  end

  local fits = true
  for _, l in ipairs(lines) do
    if disp(l) > width then
      fits = false
      break
    end
  end
  if fits then
    return false
  end
  for _, l in ipairs(lines) do
    if l:match("^%s*>") or l:match("^%s*#") or l:match("^%s*[-*+]%s") or l:match("^%s*%d+[.)]%s") or l:match("^%s*|") then
      return false
    end
  end

  local joined = vim.trim(table.concat(lines, " "):gsub("%s+", " "))
  if joined == "" then
    return false
  end
  local wrapped = wrap_line(joined, width)
  if not vim.deep_equal(wrapped, lines) then
    api.nvim_buf_set_lines(S.comments_buf, b.text_first - 1, b.text_last, false, wrapped)
    return true
  end
  return false
end

--- Re-wrap every block whose text is wider than the box. Later blocks are done
--- first so editing one does not invalidate the line numbers of the blocks
--- before it; the caller reparses once afterwards.
function reflow_all()
  if fn.mode(1):match("^[iR]") then
    return false
  end
  if not api.nvim_get_option_value("modifiable", { buf = S.comments_buf }) then
    return false
  end
  local changed = false
  for i = #S.blocks, 1, -1 do
    if reflow_block(S.blocks[i]) then
      changed = true
    end
  end
  return changed
end

local function reflow_current_block()
  local b = find_block_at_cursor()
  if not b then
    return
  end
  if reflow_block(b) then
    -- line counts changed: refresh S.blocks before the caller relayouts
    parse_blocks()
  end
  schedule_refresh()
end

--------------------------------------------------------------------------------
-- scrolling: both windows are 'scrollbind'-ed, and because the comments file is
-- laid out on the same line numbers as the reviewed file, they stay aligned.
--------------------------------------------------------------------------------

local function bind_scroll()
  for _, win in ipairs({ S.main_win, S.comments_win }) do
    if win and api.nvim_win_is_valid(win) then
      vim.wo[win].scrollbind = M.config.scroll_sync
    end
  end
  if M.config.scroll_sync then
    vim.opt.scrollopt = "ver,jump"
  end
end

--------------------------------------------------------------------------------
-- completion
--------------------------------------------------------------------------------

-- Ask the common completion plugins to stay quiet in the two buffers annotate
-- owns. These are per-buffer switches read live (on every keystroke), so they
-- take effect no matter when the filetype plugins and the plugin's own setup
-- run, and they leave every other buffer alone.
local function disable_completion(buf)
  if not M.config.disable_completion then
    return
  end
  vim.b[buf].completion = false            -- blink.cmp, nvim-cmp
  vim.b[buf].minicompletion_disable = true -- mini.completion
end

--------------------------------------------------------------------------------
-- setup
--------------------------------------------------------------------------------

local function comments_path_for(path)
  if path:match("%.comments%.md$") then
    return path
  end
  return (path:gsub("%.md$", "")) .. ".comments.md"
end

local function main_path_for(path)
  if path:match("%.comments%.md$") then
    return (path:gsub("%.comments%.md$", "")) .. ".md"
  end
  return path
end

local function setup_keymaps()
  local cfg = M.config
  vim.keymap.set("x", cfg.map_comment, function()
    M.comment_selection()
  end, { buffer = S.main_buf, silent = true, desc = "Annotate: comment selection" })
  vim.keymap.set("x", cfg.map_delete, function()
    M.delete_selection()
  end, { buffer = S.main_buf, silent = true, desc = "Annotate: mark selection for deletion" })
  vim.keymap.set("n", cfg.map_comment, function()
    M.jump_to_comment()
  end, { buffer = S.main_buf, silent = true, desc = "Annotate: jump to comment" })
  vim.keymap.set("n", cfg.map_comment, function()
    M.jump_back()
  end, { buffer = S.comments_buf, silent = true, desc = "Annotate: jump back to text" })
  vim.keymap.set("i", cfg.map_comment, "<Esc><Cmd>lua require('annotate').jump_back()<CR>",
    { buffer = S.comments_buf, silent = true, desc = "Annotate: jump back to text" })
  for _, buf in ipairs({ S.main_buf, S.comments_buf }) do
    vim.keymap.set("n", cfg.map_finish, function()
      M.finish()
    end, { buffer = buf, silent = true, desc = "Annotate: finish review" })
    vim.keymap.set("n", cfg.map_abort, function()
      M.abort()
    end, { buffer = buf, silent = true, desc = "Annotate: abort review" })
  end
  vim.keymap.set("i", cfg.map_finish, "<Esc><Cmd>lua require('annotate').finish()<CR>",
    { buffer = S.comments_buf, silent = true, desc = "Annotate: finish review" })
  vim.keymap.set("i", cfg.map_abort, "<Esc><Cmd>lua require('annotate').abort()<CR>",
    { buffer = S.comments_buf, silent = true, desc = "Annotate: abort review" })
end

local function setup_window()
  local cfg = M.config
  local cols = vim.o.columns
  local width = math.max(cfg.min_width, math.min(cfg.max_width, math.floor(cols * cfg.width_ratio)))

  api.nvim_set_current_win(S.main_win)
  vim.cmd("silent! vsplit " .. fn.fnameescape(S.comments_path))
  S.comments_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.comments_win, S.comments_buf)
  vim.cmd("silent! vertical resize " .. width)

  vim.wo[S.comments_win].number = false
  vim.wo[S.comments_win].relativenumber = false
  vim.wo[S.comments_win].signcolumn = "no"
  vim.wo[S.comments_win].foldcolumn = "0"
  vim.wo[S.comments_win].wrap = true
  vim.wo[S.comments_win].linebreak = false
  vim.wo[S.comments_win].breakindent = false
  vim.wo[S.comments_win].conceallevel = 2
  vim.wo[S.comments_win].concealcursor = "n"
  vim.wo[S.comments_win].winfixwidth = true
  vim.wo[S.comments_win].spell = false
  vim.wo[S.comments_win].list = false
  apply_textwidth()
  bind_scroll()
  api.nvim_set_current_win(S.main_win)
end

local function setup_autocmds()
  local group = api.nvim_create_augroup("Annotate", { clear = true })

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = S.comments_buf,
    callback = schedule_refresh,
  })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = S.comments_buf,
    callback = function()
      if M.config.autoformat then
        reflow_current_block()
      end
      if S.layout_pending then
        S.layout_pending = false
        M.relayout()
      end
      schedule_refresh()
    end,
  })
  -- anchors move with edits in the reviewed file: keep markers and layout true
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = S.main_buf,
    callback = function()
      if M.rewrite_markers() then
        M.relayout()
      end
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = S.main_buf,
    callback = function()
      M.rewrite_markers()
      M.relayout()
      M.save_comments()
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = S.main_buf,
    callback = update_active,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = S.comments_buf,
    callback = update_active,
  })

  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = schedule_refresh,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.rewrite_markers()
      M.relayout()
      M.save_comments()
    end,
  })

  api.nvim_create_user_command("AnnotateDone", function()
    M.finish()
  end, { desc = "Save the annotations and close Neovim" })

  api.nvim_create_user_command("AnnotateAbort", function()
    M.abort()
  end, { desc = "Close Neovim without handing the annotations on" })

  api.nvim_create_user_command("AnnotateRefresh", function()
    S.anchors = {}
    S.marks = {}
    M.refresh()
  end, { desc = "Re-read annotation anchors from the comments file" })

  api.nvim_create_user_command("AnnotateClear", function()
    local b = find_block_at_cursor()
    if not b then
      notify("no annotation at the cursor", vim.log.levels.WARN)
      return
    end
    api.nvim_buf_set_lines(S.comments_buf, b.marker_row - 1, (b.end_row or b.text_last), false, {})
    pcall(api.nvim_buf_del_extmark, S.main_buf, NS_MARKS, S.marks[b.id])
    S.marks[b.id] = nil
    S.anchors[b.id] = nil
    if S.active_id == b.id then
      S.active_id = nil
    end
    M.refresh()
    M.save_comments()
  end, { desc = "Remove the annotation at the cursor" })
end

--- Activate annotate mode for the current Neovim instance, if it applies.
-- Activation is explicit: the caller names the file to review. The command
-- line is never inspected, so `nvim notes.md` starts plain editing like any
-- other file. Review mode is armed only by `setup({ path = ... })`,
-- `$ANNOTATE_FILE`, `:Annotate notes.md`, or Pi's /annotate command.
local function requested_target(opts)
  local candidate = (opts and (opts.path or opts.file))
  if type(candidate) ~= "string" or candidate == "" then
    candidate = vim.env.ANNOTATE_FILE
  end
  if type(candidate) ~= "string" or candidate == "" then
    candidate = vim.g.annotate_file
  end
  if type(candidate) ~= "string" or candidate == "" then
    return nil
  end
  if not candidate:match("%.[mM][dD]$") then
    return nil
  end
  return candidate
end

function M.setup(opts)
  if S.ready then
    return true
  end
  local overrides = vim.deepcopy(opts or {})
  overrides.path = nil
  overrides.file = nil
  M.config = vim.tbl_deep_extend("force", M.config, vim.g.annotate or {}, overrides)

  local target = requested_target(opts)
  if not target then
    return false
  end

  S.main_path = fn.fnamemodify(main_path_for(target), ":p")
  S.comments_path = fn.fnamemodify(comments_path_for(target), ":p")
  if S.main_path == S.comments_path then
    return false
  end

  define_highlights()

  S.main_buf = fn.bufadd(S.main_path)
  fn.bufload(S.main_buf)
  S.main_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.main_win, S.main_buf)

  if fn.filereadable(S.comments_path) == 0 then
    fn.writefile({ header_line(S.main_path), "" }, S.comments_path)
  end
  S.comments_buf = fn.bufadd(S.comments_path)
  -- the sidecar is regenerable, so never trip over a leftover swap file for it
  api.nvim_set_option_value("swapfile", false, { buf = S.comments_buf })
  fn.bufload(S.comments_buf)

  disable_completion(S.main_buf)
  disable_completion(S.comments_buf)

  setup_window()
  S.ready = true
  setup_keymaps()
  setup_autocmds()
  M.refresh()
  notify(string.format("reviewing %s — %s comment · %s delete · %s finish · %s abort",
    fn.fnamemodify(S.main_path, ":t"), pretty_key(M.config.map_comment),
    pretty_key(M.config.map_delete), pretty_key(M.config.map_finish),
    pretty_key(M.config.map_abort)))
  return true
end

--- Debug helper: current annotation state (used by development scripts).
function M.state()
  return {
    blocks = S.blocks,
    anchors = S.anchors,
    main_buf = S.main_buf,
    comments_buf = S.comments_buf,
    main_win = S.main_win,
    comments_win = S.comments_win,
  }
end

return M
