vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local command = {
    "git",
    "-c",
    "user.name=Example",
    "-c",
    "user.email=example@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
  }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local function file(i)
  return string.format("file-%02d.txt", i)
end
git({ "init", "-q" })
for i = 1, 40 do
  vim.fn.writefile({ "old", "keep" }, root .. "/" .. file(i))
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
for i = 1, 40 do
  vim.fn.writefile({ "new", "keep", "extra" }, root .. "/" .. file(i))
end
local diffreel = require("diffreel")
local function request(view, method)
  local result, done, failure
  view.manager.backend:request(method, {}, function(err, value)
    failure, result, done = err, value, true
  end)
  assert(vim.wait(5000, function()
    return done
  end, 5))
  assert(not failure, vim.inspect(failure))
  return result
end
local function ready(view)
  assert(vim.wait(10000, function()
    return view.ready or view.error
  end, 5))
  assert(not view.error, view.error)
end
local ok, err = xpcall(function()
  diffreel.setup({ watch = false })
  local off = diffreel.open({ root = root })
  ready(off)
  assert(request(off, "debug/metrics").stats_files == 0)
  assert(not off.statistics)
  diffreel.close(off)
  local at_ready
  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffreelReady",
    once = true,
    callback = function(event)
      local view = diffreel.views[event.data.view_id]
      view.manager.backend:request("debug/metrics", {}, function(failure, value)
        assert(not failure, vim.inspect(failure))
        at_ready = value.stats_files
      end)
    end,
  })
  vim.api.nvim_cmd({ cmd = "Diffreel", args = { "--repo", root, "--stat" } }, {})
  local view = diffreel.get_current()
  ready(view)
  diffreel.select(view, file(40))
  assert(vim.wait(10000, function()
    return view.statistics and view.statistics.complete and view.ready
  end, 5))
  assert(at_ready == 0, "Statistics delayed the initial content")
  assert(view.selected_path == file(40), "Statistics reset file selection")
  assert(
    vim.tbl_count(view.statistics.files) == 40 and view.statistics.additions == 80 and view.statistics.deletions == 40
  )
  assert(
    vim.wait(1000, function()
      return table
        .concat(vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false), "\n")
        :find("Saved lines: +80 -40", 1, true)
    end, 5),
    "Statistics were not rendered"
  )
  local before = request(view, "debug/metrics").stats_files
  local draft = view.right_buf
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "draft", "draft", "draft", "draft" })
  diffreel.select(view, file(1))
  ready(view)
  diffreel.select(view, file(40))
  ready(view)
  assert(request(view, "debug/metrics").stats_files == before, "Selection recomputed statistics")
  assert(view.statistics.files[file(40)].additions == 2 and vim.bo[draft].modified)
  local generation = view.comparison.generation
  vim.fn.writefile({ "saved replacement" }, root .. "/" .. file(40))
  diffreel.refresh(view)
  assert(
    vim.wait(10000, function()
      return view.comparison.generation > generation
        and view.statistics
        and view.statistics.generation == view.comparison.generation
        and view.statistics.complete
    end, 5),
    view.error
  )
  assert(view.statistics.files[file(40)].additions == 1 and view.statistics.files[file(40)].deletions == 2)
  assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "draft" and vim.bo[draft].modified)
  diffreel.close(view)
  assert(vim.bo[draft].modified)
end, debug.traceback)
diffreel.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
