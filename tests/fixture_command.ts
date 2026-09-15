const [kind, ...args] = Deno.args;
const root = Deno.env.get("DIFFREEL_PR_FIXTURE")!;
const exists = (name: string) => {
  try {
    Deno.statSync(`${root}/${name}`);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
};
function write(name: string, text: string) {
  const pending = `${root}/${name}.${Deno.pid}.tmp`;
  Deno.writeTextFileSync(pending, text);
  Deno.renameSync(pending, `${root}/${name}`);
}
if (kind === "git-log") {
  const [pid, ...command] = args;
  Deno.writeTextFileSync(
    `${root}/git-commands.jsonl`,
    JSON.stringify(command) + "\n",
    { append: true },
  );
  if (command.includes("fetch") && exists("hold-fetch")) {
    const parent = new Deno.Command("ps", {
      args: ["-o", "ppid=", "-p", pid],
      stdout: "piped",
    }).outputSync();
    if (!parent.success) throw new Error("Cannot determine fixture parent");
    write("worker.pid", new TextDecoder().decode(parent.stdout).trim());
    write("fetch.pid", pid);
  }
} else if (kind === "gh") {
  Deno.writeTextFileSync(
    `${root}/gh-commands.jsonl`,
    JSON.stringify(args) + "\n",
    { append: true },
  );
  if (exists("slow")) {
    write("gh.pid", String(Deno.pid));
    while (exists("slow")) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  if (exists("fail")) Deno.exit(1);
  if (args.some((arg) => arg.includes("/pulls/"))) {
    console.log(Deno.readTextFileSync(`${root}/metadata.json`));
  } else if (args.some((arg) => arg.includes("repos/contributor/project"))) {
    console.log(
      JSON.stringify({
        html_url: "https://github.com/contributor/project",
        parent: { html_url: "https://github.com/example/project" },
      }),
    );
  } else {console.log(
      JSON.stringify({
        url: "https://github.com/example/project",
        html_url: "https://github.com/example/project",
        parent: null,
      }),
    );}
} else throw new Error("Unknown fixture command");
