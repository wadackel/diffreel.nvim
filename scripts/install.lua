local source = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(source)))
local done, failure
require("diffreel.install").ensure({ managed = true }, function(err, result)
  done, failure = true, err
  if result then
    print("diffreel: " .. result.path)
  end
end)
if not vim.wait(125000, function()
  return done
end, 10) then
  failure = "diffreel: installer did not complete"
end
require("diffreel.install").shutdown()
if failure then
  io.stderr:write(failure .. "\n")
end
vim.cmd(failure and "cquit 1" or "qa!")
