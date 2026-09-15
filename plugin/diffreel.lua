if vim.g.loaded_diffreel then
  return
end
vim.g.loaded_diffreel = true
require("diffreel").setup()
