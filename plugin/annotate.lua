-- `:Annotate [file]` — arm review mode without touching the command line.
--
-- The plugin never activates by itself: opening a Markdown file is ordinary
-- editing. Review mode starts only when a caller names the file — here, via
-- `require('annotate').setup({ path = ... })`, or via `$ANNOTATE_FILE` (which
-- Pi's /annotate command sets).

vim.api.nvim_create_user_command("Annotate", function(args)
  local target
  if args.args ~= "" then
    target = vim.fn.fnamemodify(args.args, ":p")
  else
    target = vim.api.nvim_buf_get_name(0)
  end
  if target == "" then
    vim.notify("annotate: name a Markdown file: :Annotate notes.md", vim.log.levels.WARN)
    return
  end
  if not require("annotate").setup({ path = target }) then
    vim.notify("annotate: cannot review " .. target .. " (it must be a .md file)",
      vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  complete = "file",
  desc = "Annotate: review a Markdown file beside its comments sidecar",
})
