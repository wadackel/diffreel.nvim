import { Nvim, PLUGIN } from "./support.ts";
import {
  assert,
  assertEquals,
  dirname,
  executable,
  git,
  join,
  json,
  mkdir,
  now,
  ROOT,
  run,
  temporary,
  write,
} from "../scripts/lib.ts";

const LAZY_COMMIT = "85c7ff3711b730b4030d03144f6db6375044ae82",
  REPOSITORY = "https://github.com/wadackel/diffreel.nvim";
async function main() {
  if (Deno.args.includes("--help")) {
    console.log(
      "consumer.ts: requires DIFFREEL_COMMIT and DIFFREEL_EXPECTED_ID for the published release",
    );
    return;
  }
  const commit = Deno.env.get("DIFFREEL_COMMIT"),
    expected = Deno.env.get("DIFFREEL_EXPECTED_ID");
  assert(commit && expected);
  const evidence = join(ROOT, ".wadackel/qa/consumer");
  mkdir(evidence);
  const results: Record<string, unknown>[] = [];
  using temp = temporary("diffreel-consumer-");
  const root = temp.path, lazy = join(root, "lazy.nvim");
  await run([
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim",
    lazy,
  ]);
  await run(["git", "checkout", LAZY_COMMIT], { cwd: lazy });
  const bin = join(root, "bin");
  mkdir(bin);
  for (
    const name of [
      "nvim",
      "git",
      "curl",
      "sh",
      "uname",
      "basename",
      "sed",
    ]
  ) {
    const source = executable(name);
    assert(source);
    Deno.symlinkSync(source, join(bin, name));
  }
  const execPath = (await run(["git", "--exec-path"])).stdout.trim();
  for (const manager of ["lazy", "pack"]) {
    const state = join(root, manager), worktree = join(state, "repo");
    mkdir(worktree);
    await git(worktree, "init", "-q");
    write(join(worktree, "file.txt"), "baseline\n");
    await git(worktree, "add", ".");
    await git(worktree, "commit", "-qm", "baseline");
    write(join(worktree, "file.txt"), "changed\n");
    const env: Record<string, string> = {
      HOME: state,
      LANG: "en_US.UTF-8",
      PATH: bin,
      GIT_EXEC_PATH: execPath,
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_TERMINAL_PROMPT: "0",
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "credential.helper",
      GIT_CONFIG_VALUE_0: "",
      XDG_DATA_HOME: join(state, "data"),
      XDG_CONFIG_HOME: join(state, "config"),
      XDG_STATE_HOME: join(state, "state"),
      XDG_CACHE_HOME: join(state, "cache"),
    };
    for (const phase of ["cold", "cache"]) {
      const nvim = await Nvim.create(worktree, {
          env,
          source: false,
          daemon: false,
        }),
        started = now();
      try {
        await nvim.lua(
          "vim.o.loadplugins=true;assert(vim.fn.executable('gh')+vim.fn.executable('deno')+vim.fn.executable('python3')+vim.fn.executable('cargo')+vim.fn.executable('rustc')+vim.fn.executable('nix')==0)",
        );
        if (manager === "lazy") {
          await nvim.lua(
            `
          local lazy,repo,commit=...
          vim.opt.rtp:prepend(lazy)
          require('lazy').setup({{
            url=repo,name='diffreel.nvim',main='diffreel',commit=commit,
            cmd={'Diffreel','DiffreelInstall'},opts={},
          }},{install={missing=true,colorscheme={}},checker={enabled=false},change_detection={enabled=false}})
        `,
            lazy,
            REPOSITORY,
            commit,
          );
        } else {await nvim.lua(
            "vim.pack.add({{src=select(1,...),name='diffreel.nvim',version=select(2,...)}},{confirm=false})",
            REPOSITORY,
            commit,
          );}
        if (phase === "cache") {
          await nvim.lua(
            "local system=vim.system;vim.system=function(cmd,...)assert(cmd[1]~='curl' and cmd[1]~='gh','Cache hit attempted a download');return system(cmd,...)end",
          );
        }
        await nvim.requestWithTimeout("nvim_command", ["Diffreel"], 120);
        await nvim.wait(
          "return require('diffreel').get_current() and require('diffreel').get_current().ready",
          130,
        );
        const identity = await nvim.lua(
          "_G.view=require('diffreel').get_current();local source=debug.getinfo(require('diffreel').open,'S').source;local spec=require('diffreel.distribution').current();return {source=source,build_id=spec.id,custom=require('diffreel').config.daemon}",
        );
        const loadedSource = Deno.realPathSync(identity.source.slice(1));
        const checkoutSource = Deno.realPathSync(
          join(PLUGIN, "lua/diffreel/init.lua"),
        );
        const installedData = Deno.realPathSync(env.XDG_DATA_HOME);
        assert(
          identity.build_id === expected && loadedSource !== checkoutSource &&
            loadedSource.startsWith(installedData + "/") && !identity.custom,
          JSON.stringify(identity),
        );
        assertEquals(
          await git(
            dirname(dirname(dirname(loadedSource))),
            "rev-parse",
            "HEAD",
          ),
          commit,
        );
        await nvim.lua(
          "vim.api.nvim_buf_set_lines(view.right_buf,0,-1,false,{'draft'})",
        );
        write(join(worktree, "file.txt"), "external\n");
        await nvim.lua("require('diffreel').refresh(view)");
        await nvim.wait(
          "return view.ready and not view.updating and view.disk_conflict",
        );
        assertEquals(
          await nvim.lua(
            "return vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)",
          ),
          ["draft"],
        );
        await nvim.lua(
          "_G.buffer=view.right_buf;require('diffreel').close(view)",
        );
        assert(
          await nvim.lua(
            "return vim.bo[buffer].modified and vim.api.nvim_buf_get_lines(buffer,0,1,false)[1]=='draft'",
          ),
        );
        nvim.capture(evidence, manager + "-" + phase);
        const result = {
          manager,
          phase,
          commit,
          passed: true,
          seconds: Number((now() - started).toFixed(3)),
          ...identity,
        };
        results.push(result);
        console.log(JSON.stringify(result));
      } catch (error) {
        nvim.capture(evidence, `${manager}-${phase}-failure`);
        throw error;
      } finally {
        await nvim.close();
        json(join(evidence, "results.json"), results);
      }
    }
  }
}
if (import.meta.main) await main();
