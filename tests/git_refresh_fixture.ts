const [git, gate, entered, ...args] = Deno.args;
const result = await new Deno.Command(git, {
  args,
  stdout: "piped",
  stderr: "piped",
}).output();
const exists = () => {
  try {
    Deno.statSync(gate);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
};
if (args.includes("status") && exists()) {
  Deno.writeTextFileSync(entered, "");
  const deadline = performance.now() + 10000;
  while (exists() && performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
const stdout = Deno.stdout.writable.getWriter(),
  stderr = Deno.stderr.writable.getWriter();
await stdout.write(result.stdout);
await stderr.write(result.stderr);
stdout.releaseLock();
stderr.releaseLock();
Deno.exitCode = result.code;
