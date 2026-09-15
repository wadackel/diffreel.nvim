import { Nvim } from "../tests/support.ts";
import {
  argumentsFor,
  assert,
  assertEquals,
  bytes,
  exists,
  invocation,
  join,
  json,
  lines,
  mkdir,
  read,
  resolve,
  run,
  sha256,
  temporary,
  write,
} from "./lib.ts";

const BEFORE = `local M = {}

function M.label(change)
  if change.status == "added" then
    return "+ " .. change.path
  end
  return change.path
end

function M.filter(changes, query)
  local matches = {}
  for _, change in ipairs(changes) do
    if change.path:find(query, 1, true) then
      matches[#matches + 1] = change
    end
  end
  return matches
end

return M
`;
const AFTER = `local M = {}

local markers = {
  added = "+",
  modified = "~",
  deleted = "-",
}

function M.label(change)
  local marker = markers[change.status] or " "
  return marker .. " " .. change.path
end

function M.filter(changes, query)
  query = query:lower()
  local matches = {}
  for _, change in ipairs(changes) do
    local path = change.path:lower()
    if path:find(query, 1, true) then
      matches[#matches + 1] = change
    end
  end
  return matches
end

return M
`;

async function main() {
  const args = argumentsFor({ daemon: "", font: "", output: "" }, [
    "daemon",
    "font",
    "output",
  ]);
  const daemon = resolve(String(args.daemon)),
    font = resolve(String(args.font)),
    output = resolve(String(args.output));
  assert(exists(font), "--font must name a monospaced font file");
  mkdir(output);
  const buildInfo = JSON.parse((await run([daemon, "--build-info"])).stdout),
    renderer = (await run(["magick", "--version"])).stdout.trim();
  let baseline: string, version: string;
  {
    using temp = temporary("fixture-", output);
    const directory = temp.path, repo = join(directory, "diffreel-demo");
    mkdir(join(repo, "src"));
    const env: Record<string, string> = {
      ...Deno.env.toObject(),
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_COUNT: "0",
      GIT_AUTHOR_DATE: "2026-01-01T00:00:00+00:00",
      GIT_COMMITTER_DATE: "2026-01-01T00:00:00+00:00",
      DIFFREEL_DAEMON: daemon,
      NVIM_APPNAME: "nvim",
    };
    for (const key of ["DATA", "CONFIG", "STATE", "CACHE"]) {
      env[`XDG_${key}_HOME`] = join(directory, key.toLowerCase());
    }
    const git = async (...args: string[]) =>
      (await run([
        "git",
        "-c",
        "user.name=Example",
        "-c",
        "user.email=example@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.autocrlf=false",
        ...args,
      ], { cwd: repo, env })).stdout.trim();
    await git("init", "-q", "-b", "main", "--object-format=sha1");
    write(join(repo, "src/review.lua"), BEFORE);
    write(join(repo, "src/config.lua"), "return { width = 28 }\n");
    write(
      join(repo, "README.md"),
      "# Review helpers\n\nFormat and filter changing files.\n",
    );
    await git("add", ".");
    await git("commit", "-qm", "Add review helpers");
    baseline = await git("rev-parse", "HEAD");
    write(join(repo, "src/review.lua"), AFTER);
    write(
      join(repo, "src/config.lua"),
      "return { width = 35, show_deleted = true }\n",
    );
    write(
      join(repo, "README.md"),
      "# Review helpers\n\nFilter file paths without case sensitivity.\n",
    );
    const nvim = await Nvim.create(repo, { columns: 156, rows: 34, env });
    try {
      await nvim.lua(`
        vim.o.background="dark"
        vim.cmd("colorscheme default")
        vim.cmd("syntax on")
        vim.o.showtabline=0
        vim.o.laststatus=0
        vim.o.cmdheight=0
        vim.o.showmode=false
        vim.o.ruler=false
        require("diffreel").setup({watch=false,width=35,auto_install=false})
        _G.view=require("diffreel").open()
      `);
      await nvim.wait("return view.ready and not view.updating");
      await nvim.lua("require('diffreel').select(view,'src/review.lua')");
      await nvim.wait(
        "return view.ready and view.selected_path=='src/review.lua' and not view.updating",
      );
      const draft = AFTER.replace(
        "query = query:lower()",
        "query = vim.trim(query):lower()",
      );
      await nvim.lua(
        "vim.api.nvim_buf_set_lines(view.right_buf,0,-1,false,...);vim.api.nvim_set_current_win(view.right_win);vim.cmd('normal! gg')",
        lines(draft),
      );
      await nvim.wait(
        "return view.disk_conflict and vim.bo[view.right_buf].modified",
      );
      assertEquals(
        await nvim.lua(
          "return vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)",
        ),
        lines(draft),
      );
      assertEquals(
        await nvim.lua(
          "return vim.api.nvim_buf_get_lines(view.left_buf,0,-1,false)",
        ),
        lines(BEFORE),
      );
      assert(await nvim.lua("return #view.entries") === 3);
      assert(read(join(repo, "src/review.lua")) === AFTER);
      const frame = nvim.frames;
      await nvim.request("nvim_command", "redraw!");
      await nvim.waitFrame(frame, 5);
      nvim.capture(output, "review");
      version = await nvim.lua("return tostring(vim.version())");
    } catch (error) {
      nvim.capture(output, "failure");
      throw error;
    } finally {
      await nvim.close();
    }
  }
  let svg = read(join(output, "review.svg")).replaceAll(
    'font-family="monospace" ',
    "",
  );
  // MSVG strips quotes at text boundaries; zero-width padding preserves the captured glyphs.
  svg = svg.replace(/(<text\b[^>]*>)(.*?)(<\/text>)/g, "$1&#8203;$2&#8203;$3");
  const renderSource = join(output, "review-render.svg");
  write(renderSource, svg);
  const renderCommand = [
    "magick",
    "-density",
    "144",
    "-font",
    font,
    "MSVG:" + renderSource,
    "-strip",
    join(output, "review.png"),
  ];
  await run(renderCommand);
  json(join(output, "capture.json"), {
    command: invocation(),
    cwd: Deno.cwd(),
    passed: true,
    backend: "rust",
    configuration: "minimal",
    neovim: version,
    git: (await run(["git", "--version"])).stdout.trim(),
    platform: `${Deno.build.os}-${Deno.build.arch}`,
    deno: Deno.version,
    daemon,
    daemon_sha256: await sha256(bytes(daemon)),
    build_info: buildInfo,
    baseline_commit: baseline,
    columns: 156,
    rows: 34,
    colorscheme: "default",
    background: "dark",
    watch: false,
    explorer_width: 35,
    font,
    font_sha256: await sha256(bytes(font)),
    renderer,
    render_command: renderCommand,
    limits:
      "Rendered Neovim UI grid, not an OS terminal capture; font/version changes can alter pixels.",
  });
  console.log(
    JSON.stringify({
      passed: true,
      image: join(output, "review.png"),
      baseline_commit: baseline,
    }),
  );
}
if (import.meta.main) await main();
