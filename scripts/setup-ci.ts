import { assert, bytes, join, mkdir, run, sha256 } from "./lib.ts";

const NVIM: Record<string, string> = {
  "linux-arm64":
    "1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725",
  "linux-x86_64":
    "bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875",
  "macos-arm64":
    "65fb000099e47ca1b762584c484cc833f40e30851a0ec450d4174e16317c1f9b",
  "macos-x86_64":
    "81f4518622cb059b450ee2e498c6a1082a222f6bd89589de5bbcf0c6a68aa3fd",
};
async function unpack(url: string, checksum: string, directory: string) {
  const archive = join(directory, new URL(url).pathname.split("/").at(-1)!);
  const response = await fetch(url);
  assert(response.ok, `Download failed: ${url}`);
  Deno.writeFileSync(archive, new Uint8Array(await response.arrayBuffer()));
  assert(await sha256(bytes(archive)) === checksum, archive);
  await run(["tar", "-xf", archive, "-C", directory]);
}
if (import.meta.main) {
  if (Deno.args.includes("--help")) {
    console.log("setup-ci.ts [--editor-only]");
    Deno.exit(0);
  }
  assert(Deno.args.every((arg) => arg === "--editor-only"));
  const directory = join(Deno.env.get("RUNNER_TEMP")!, "diffreel-tools");
  mkdir(directory);
  const target = `${Deno.build.os === "darwin" ? "macos" : "linux"}-${
    Deno.build.arch === "aarch64" ? "arm64" : "x86_64"
  }`;
  await unpack(
    `https://github.com/neovim/neovim/releases/download/v0.12.5/nvim-${target}.tar.gz`,
    NVIM[target],
    directory,
  );
  const paths = [join(directory, `nvim-${target}/bin`)];
  if (
    !Deno.args.includes("--editor-only") &&
    (await run(["git", "--version"])).stdout.trim() !== "git version 2.55.0"
  ) {
    await unpack(
      "https://www.kernel.org/pub/software/scm/git/git-2.55.0.tar.xz",
      "457fdb04dc8728e007d4688695e6912e6f680727920f2a40bf11eacc17505357",
      directory,
    );
    const prefix = join(directory, "git");
    await run([
      "make",
      `-j${navigator.hardwareConcurrency || 2}`,
      `prefix=${prefix}`,
      "NO_GETTEXT=1",
      "NO_TCLTK=1",
      "NO_PERL=1",
      "NO_EXPAT=1",
      "install",
    ], { cwd: join(directory, "git-2.55.0"), timeout: 1200 });
    paths.push(join(prefix, "bin"));
  }
  Deno.writeTextFileSync(
    Deno.env.get("GITHUB_PATH")!,
    paths.join("\n") + "\n",
    { append: true },
  );
}
