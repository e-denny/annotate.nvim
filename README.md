# annotate.nvim

Review a Markdown file in Neovim and leave the feedback as a plain-Markdown
sidecar that you — or a tool — can apply afterwards.

`annotate.nvim` opens the file under review on the left and its sidecar
`<name>.comments.md` on the right. Comment on or delete spans of the reviewed
file; each annotation is written to the sidecar as a plain Markdown block and
drawn as a rounded box aligned with the text it refers to.

It is the Neovim half of Pi's `/annotate` command, but it works on its own.

```
┌ notes.md ───────────────┬ notes.comments.md ────────────┐
│ # Design notes          │                               │
│                         │                               │
│ The quick brown fox …   │ ╭─ 3:1 → 4:69  comment ──────╮ │
│ have something to …     │ │ tighten this opening       │ │
│                         │ ╰────────────────────────────╯ │
│ ## Second section       │                               │
│                         │ ╭─ 9:1 → 9:59  delete ───────╮ │
│ ~~want to remove …~~    │ │ > want to remove entirely… │ │
│                         │ ╰────────────────────────────╯ │
└─────────────────────────┴───────────────────────────────┘
```

## Requirements

- Neovim `>= 0.9.0`
- A way to arm review mode: `:Annotate notes.md` or
  `require('annotate').setup({ path = 'notes.md' })`; `setup()` also falls back
  to `$ANNOTATE_FILE` and `vim.g.annotate_file` when it gets no path. The
  plugin never activates by itself — `nvim notes.md` is ordinary editing, and
  no sidecar is created until review mode starts.

## Installation

### lazy.nvim

```lua
{
    'e-denny/annotate.nvim',
    cmd = 'Annotate',
    module = 'annotate',
}
```

No `ft` trigger and no `opts`: the plugin loads only when `:Annotate` runs or
something requires the module (Pi's `/annotate` command does). Loading it on
every Markdown buffer would not start a review, but there is no reason to.

### Manual

```lua
require('annotate').setup({
    path = 'notes.md',   -- the file to review; required
    -- optional overrides, see Configuration
})
```

## Usage

| Step | Keys |
| --- | --- |
| Start a review | `:Annotate notes.md` (or no argument for the current file) |
| Comment a selection | select text in the reviewed file, `<Space>C` |
| Write the note | the cursor jumps into the new box — type, then `<Space>C` jumps back |
| Mark a selection for deletion | select text, `<Space>D` (press it again on the same range to undo) |
| Jump to the box for the annotation under the cursor | `<Space>C` on already-annotated text |
| Jump back from a box to the text | `<Space>C` in the sidecar |
| Remove the annotation under the cursor | `:AnnotateClear` |
| Finish the review | `<Space>Q` (or `:AnnotateDone`, or just quit Neovim) |

`<leader>` is your Neovim leader (space in LazyVim). The maps are buffer-local
to the reviewed file and sidecar, so they do not leak into other buffers.

Leaving Neovim with `:qa`, `:wq`, `<Space>Q`, or `:AnnotateDone` all end the
review. Unsaved edits to the reviewed file are written out before quitting.

### Commands

| Command | Description |
| --- | --- |
| `:AnnotateDone` | Save the annotations and close Neovim |
| `:AnnotateRefresh` | Re-read annotation anchors from the comments file |
| `:AnnotateClear` | Remove the annotation under the cursor |

## What you see

- **Commented spans** get a yellow background in the reviewed file.
- **Deleted spans** get strikethrough.
- **Each annotation is its own rounded box** in the sidecar, labelled with the
  start and end location of the span it refers to (`12:3 → 14:20  comment`).
- **Boxes line up with their text.** The sidecar is laid out on the same line
  numbers as the reviewed file (blank lines do the padding), and both windows
  share `scrollbind`, so they scroll together.
- The sidecar stays a plain Markdown file on disk: the boxes, borders and
  highlights are decorations drawn by the plugin, not text in the file.

## The sidecar format

`notes.comments.md` is plain Markdown. One block per annotation, padded so each
marker sits on the line it points at:

```markdown
<!-- annotate:source notes.md -->



<!-- annotate:#1 3:1-4:69 comment -->
tighten this opening
<!-- /annotate -->

<!-- annotate:#3 9:1-9:59 delete -->
> want to remove entirely, and one we may want to comment on.
<!-- /annotate -->
```

- the marker holds an id, the 1-based `start_line:col-end_line:col` span
  (`col` end is inclusive) and the kind (`comment` or `delete`);
- `comment` blocks hold your note;
- `delete` blocks quote the removed text;
- anchors follow your edits in the reviewed file, so the markers stay true and
  the boxes move with the text.

A consumer can strip the blank padding before handing the sidecar to a model.

## Configuration

Set `vim.g.annotate` before `require('annotate').setup()` runs, or pass a table
to `setup()`:

```lua
vim.g.annotate = {
    map_comment = '<leader>C',
    map_delete = '<leader>D',
    map_finish = '<leader>Q',
    width_ratio = 0.42,        -- sidecar width as a share of the window
    min_width = 34,
    max_width = 90,
    scroll_sync = true,
    autosave = true,           -- write the sidecar as you annotate
    autoformat = true,         -- wrap notes to the box width as you type;
                               -- re-wrap any overlong line when the sidecar
                               -- is opened or resized
    disable_completion = true, -- suppress completion popups (blink.cmp,
                               -- nvim-cmp, mini.completion) in both buffers
}
```

## Pi integration

The Pi extension in [`e-denny/pi-config`](https://github.com/e-denny/pi-config)
registers `/annotate notes.md`. It opens a Herdr tab running Neovim with this
plugin on the `runtimepath`, waits for Neovim to exit, and then hands the
sidecar back to the agent as a message. The extension loads the plugin from its
lazy.nvim checkout (it does not bundle a copy):

```
nvim -c 'set rtp^=~/.local/share/nvim/lazy/annotate.nvim' \
     -c 'lua require("annotate").setup()'
```

The extension sets `ANNOTATE_FILE` to the absolute path it wants reviewed;
`setup()` reads that when it gets no explicit `path`, so the command line only
has to open the file normally.

The data directory follows `$XDG_DATA_HOME` (default `~/.local/share`). Install
the plugin with lazy.nvim first (see above).

## Troubleshooting

- **Nothing happens on `<Space>C`** — the mapping is buffer-local to the
  reviewed file and only active in visual mode for comments. Check
  `:verbose xmap <Space>C`.
- **The plugin does not start** — review mode is explicit. Use
  `:Annotate notes.md`, call `setup({ path = 'notes.md' })`, or set
  `ANNOTATE_FILE`. `nvim notes.md` alone stays in plain editing mode.
- **A sidecar from an earlier review is still there** — it is reopened with its
  annotations, so unfinished notes are not lost.
- **Boxes look ragged** — notes wrap to the box as you type, and a line that is
  already too long when the sidecar is opened or the pane is resized is
  re-wrapped on the next redraw (`autoformat = false` disables the re-wrapping;
  a single unbreakable token longer than the panel can still cross the border).
- **Neovim asks about a swap file for the sidecar** — it should not: the
  sidecar buffer is opened with `swapfile=off`. A stale swap for the *reviewed*
  file behaves as normal Neovim.

## License

MIT — see [LICENSE](LICENSE).
