import { git, Nvim } from "./support.ts";
import {
  assert,
  equal,
  join,
  mkdir,
  remove,
  resolve,
  temporary as makeTemp,
  write,
} from "../scripts/lib.ts";

import { fixture, unchanged_state } from "./pr_support.ts";
export async function scenario() {
  let before, env, frame, metadata, next_head, nvim, old, root, source;
  const out = ".wadackel/qa/2026-09-14-pr-fetch/ui";
  mkdir(out);
  {
    using temp_temporary = makeTemp("diffreel-", out);
    const temporary = temp_temporary.path;
    [root, metadata, env] = await fixture(resolve(temporary));
    before = await unchanged_state(root);
    nvim = await Nvim.create(root, { env: env });
    try {
      await nvim.lua(
        "require('diffreel').setup({watch=false}); _G.view=require('diffreel').open({pr=1,root=...})",
        String(root),
      );
      await nvim.wait("return view.ready or view.error");
      assert(
        await nvim.lua("return view.ready and not view.error"),
        String(await nvim.lua("return view.error")),
      );
      assert(
        await nvim.lua(
          "return view.pr.number==1 and view.pr.state=='open' and view.comparison.right==...",
          metadata["head"]["sha"],
        ),
      );
      assert(
        await nvim.lua(
          "return vim.api.nvim_buf_get_lines(view.explorer_buf,1,2,false)[1]:find(' PR #1 · open · ',1,true)~=nil",
        ),
      );
      assert(
        await nvim.lua(
          "return vim.bo[view.right_buf].buftype=='nofile' and not vim.bo[view.right_buf].modifiable",
        ),
      );
      assert(
        equal(
          await nvim.lua(
            "return vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)",
          ),
          ["after", "same"],
        ),
      );
      await nvim.lua("require('diffreel').select(view,'new.txt')");
      await nvim.wait("return view.ready and view.selected_path=='new.txt'");
      old = await nvim.lua(
        "return {view.comparison.comparison_id,view.selected_path,view.pr.head,vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)}",
      );
      write(join(temporary, "fail"), "");
      await nvim.lua("require('diffreel').refresh(view)");
      await nvim.wait("return view.error ~= nil");
      assert(
        equal(
          await nvim.lua(
            "return {view.comparison.comparison_id,view.selected_path,view.pr.head,vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)}",
          ),
          old,
        ),
      );
      remove(join(temporary, "fail"));
      source = join(resolve(temporary), "source");
      write(join(source, "new.txt"), "updated PR\n");
      await git(source, "add", ".");
      await git(source, "commit", "-qm", "update");
      next_head = await git(source, "rev-parse", "HEAD");
      await git(
        source,
        "push",
        "-q",
        String(join(resolve(temporary), "remote.git")),
        "HEAD:refs/pull/1/head",
      );
      metadata["head"]["sha"] = next_head;
      write(join(temporary, "metadata.json"), JSON.stringify(metadata));
      await nvim.lua("require('diffreel').refresh(view)");
      await nvim.wait(
        "return view.ready and not view.updating and not view.error and view.pr.head==..."
          .replace("...", JSON.stringify(next_head)),
      );
      assert(
        await nvim.lua(
          "return view.selected_path=='new.txt' and vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]=='updated PR'",
        ),
      );
      for (const method of ["comparison/open", "blob/read", "view/update"]) {
        old = await nvim.lua(
          "return {view.comparison.comparison_id,view.selected_path,view.pr.head,vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)}",
        );
        await nvim.lua(
          `
                  local method=...
                  _G.real_request=view.manager.backend.request
                  view.manager.backend.request=function(self,name,params,done)
                    if name==method then done('Injected candidate failure') else real_request(self,name,params,done) end
                  end
                  require('diffreel').refresh(view)
                `,
          method,
        );
        await nvim.wait("return view.error ~= nil");
        assert(
          equal(
            await nvim.lua(
              "return {view.comparison.comparison_id,view.selected_path,view.pr.head,vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)}",
            ),
            old,
          ),
        );
        await nvim.lua("view.manager.backend.request=real_request");
      }
      await nvim.lua("view.manager.backend:close()");
      write(join(temporary, "fail"), "");
      await nvim.lua("require('diffreel').refresh(view)");
      await nvim.wait("return view.error ~= nil and not view.updating");
      remove(join(temporary, "fail"));
      await nvim.lua(
        `
              local request=view.manager.backend.request
              _G.updated=false
              view.manager.backend.request=function(self,method,params,done)
                request(self,method,params,function(err,value)
                  done(err,value)
                  if method=='view/update' then _G.updated=true; _G.update_error=err end
                end)
              end
              require('diffreel').select(view,'file.txt')
            `,
      );
      await nvim.wait("return updated and not view.selection_pending");
      assert(
        await nvim.lua("return update_error == nil"),
        String(await nvim.lua("return update_error")),
      );
      assert(
        await nvim.lua(
          "return not view.error and view.selected_path=='file.txt'",
        ),
        String(await nvim.lua("return view.error")),
      );
      frame = nvim.frames;
      await nvim.request("nvim_command", "redraw!");
      await nvim.waitFrame(frame);
      assert(nvim.frames > frame);
      nvim.capture(out, "updated-pr");
      await nvim.lua("require('diffreel').close(view)");
      assert(equal(await unchanged_state(root), before));
      await nvim.lua(
        "_G.cleared=nil; vim.notify=function(message,level) _G.cleared={message,level} end",
      );
      await nvim.request("nvim_command", "DiffreelPRCacheClear");
      await nvim.wait("return cleared ~= nil");
      assert(
        await nvim.lua("return cleared[1]:find('removed',1,true) ~= nil"),
        String(await nvim.lua("return cleared")),
      );
      assert(
        !(await git(
          root,
          "for-each-ref",
          "--format=%(refname)",
          "refs/diffreel/pr",
        )),
      );
    } finally {
      await nvim.close();
    }
  }
  console.log(JSON.stringify({ ["passed"]: true }));
}

export async function cancel_during_activation() {
  let before, env, folder, metadata, nvim, old, root, source;
  const out = ".wadackel/qa/pr-cancel-activation";
  mkdir(out);
  {
    using temp_temporary = makeTemp("diffreel-", out);
    const temporary = temp_temporary.path;
    folder = resolve(temporary);
    [root, metadata, env] = await fixture(folder);
    before = await unchanged_state(root);
    nvim = await Nvim.create(root, { env: env });
    try {
      await nvim.lua(
        "require('diffreel').setup({watch=false}); _G.view=require('diffreel').open({pr=1})",
      );
      await nvim.wait("return view.ready or view.error");
      assert(
        await nvim.lua("return not view.error"),
        String(await nvim.lua("return view.error")),
      );
      old = await nvim.lua(
        "return {view.comparison.comparison_id, view.pr.head}",
      );
      source = join(folder, "source");
      write(join(source, "file.txt"), "updated PR\nsame\n");
      await git(source, "add", ".");
      await git(source, "commit", "-qm", "update");
      metadata["head"]["sha"] = await git(source, "rev-parse", "HEAD");
      await git(
        source,
        "push",
        "-q",
        String(join(folder, "remote.git")),
        "HEAD:refs/pull/1/head",
      );
      write(join(folder, "metadata.json"), JSON.stringify(metadata));
      await nvim.lua("_G.extra={}");
      // A single-view deadline cannot bound the aggregate startup cost of eight fixture views.
      for (let index = 1; index <= 8; index++) {
        await nvim.lua(
          "local i=...;extra[i]=require('diffreel').open({root=view.root,file='unique-'..i})",
          index,
        );
        await nvim.wait("local v=extra[#extra];return v.ready or v.error");
        assert(
          await nvim.lua("return not extra[#extra].error"),
          String(await nvim.lua("return extra[#extra].error")),
        );
      }
      await nvim.lua(
        `
              vim.api.nvim_set_current_tabpage(view.tab)
              local request=view.manager.backend.request
              _G.selected=false
              view.manager.backend.request=function(self,method,params,done)
                local activating=method=='view/update' and view.pr_request and params.view_id==view.id
                  and params.comparison_id~=view.comparison.comparison_id
                request(self,method,params,done)
                if activating then
                  vim.schedule(function()
                    selected=true
                    require('diffreel').select(view,'new.txt')
                  end)
                end
              end
              require('diffreel').refresh(view)
            `,
      );
      await nvim.wait("return selected and not view.selection_pending");
      assert(
        await nvim.lua("return not view.error"),
        String(await nvim.lua("return view.error")),
      );
      assert(
        equal(
          await nvim.lua("return {view.comparison.comparison_id,view.pr.head}"),
          old,
        ),
      );
      assert(
        await nvim.lua("return view.ready and view.selected_path=='new.txt'"),
      );
      await nvim.lua(
        "view.manager.backend:request('debug/metrics',{},function(e,r) _G.metrics=r end)",
      );
      await nvim.wait("return metrics~=nil");
      assert(equal(await nvim.lua("return metrics.views"), 9));
    } finally {
      await nvim.close();
    }
    assert(equal(await unchanged_state(root), before));
  }
  console.log(
    JSON.stringify({ ["passed"]: true, ["case"]: "cancel-during-activation" }),
  );
}
if (import.meta.main) {
  await scenario();
  await cancel_during_activation();
}
