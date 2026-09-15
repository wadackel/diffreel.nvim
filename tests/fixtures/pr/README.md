# Historical PR fixtures

These public GitHub observations were captured on 2026-09-14. Each JSON links
its PR and REST API sources and records the saved base/head SHA, merge result,
changed paths, endpoint blob OIDs, and hashes of API patch strings. PR bodies
and authentication data are omitted.

The cases distinguish a two-parent merge, a two-commit squash, three individually
verified rewritten rebase commits, a closed unmerged PR, and an indirect rollup.
The saved-base-to-head comparison matched the PR file observations in each case,
after the target branch had advanced. These are sampled histories, not proof of
all possible GitHub histories or historical object availability.

`tests/pr_live.ts` fetches the real recorded commits into isolated Git repositories
and verifies the backend's paths and endpoint blobs against these fixtures. It is
an opt-in network test requiring an authenticated `gh`; ordinary CI uses local
remotes and a deterministic `gh` fixture. Example from the repository root:

```sh
DIFFREEL_DAEMON="$PWD/daemon/target/debug/diffreel-daemon" \
  deno run --frozen -A tests/pr_live.ts --case merge --case squash --case rebase \
  --case closed-unmerged --output .wadackel/qa/pr-live
```

The indirect-rollup fixture belongs to the large Rust repository; select it
explicitly when validating that network/object-volume scenario.
