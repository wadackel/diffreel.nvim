local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.rtp:prepend(root)
io.stdout:write(require("diffreel.distribution").id(root) .. "\n")
