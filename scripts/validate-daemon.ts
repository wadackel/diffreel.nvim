function check(
  value: unknown,
  message: unknown = "Invalid daemon",
): asserts value {
  if (!value) {
    throw new Error(
      typeof message === "string" ? message : JSON.stringify(message),
    );
  }
}
function output(command: string, ...args: string[]) {
  const result = new Deno.Command(command, {
    args,
    stdout: "piped",
    stderr: "piped",
  }).outputSync();
  check(
    result.success,
    `${command} failed: ${new TextDecoder().decode(result.stderr)}`,
  );
  return new TextDecoder().decode(result.stdout);
}
export function validate(binary: string, target: string, buildId: string) {
  binary = Deno.realPathSync(binary);
  const info = JSON.parse(output(binary, "--build-info"));
  check(
    info.build_id === buildId && info.target === target && info.protocol === 4,
    info,
  );
  const architecture = target.startsWith("aarch64") ? "arm64" : "x86_64";
  if (target.includes("apple")) {
    check(output("lipo", "-archs", binary).trim() === architecture);
    const minimum = [
      ...output("otool", "-l", binary).matchAll(/\bminos\s+(\S+)/g),
    ].map((match) => match[1]);
    check(minimum.length === 1 && minimum[0] === "14.0", minimum);
    const libraries = output("otool", "-L", binary).trimEnd().split("\n").slice(
      1,
    );
    check(
      libraries.length &&
        libraries.every((line) =>
          /^\s*(\/usr\/lib\/|\/System\/Library\/)/.test(line)
        ),
      libraries,
    );
    output("codesign", "--verify", "--strict", binary);
    const signature = new Deno.Command("codesign", {
      args: ["--display", "--verbose=2", binary],
      stdout: "piped",
      stderr: "piped",
    }).outputSync();
    check(
      signature.success &&
        new TextDecoder().decode(signature.stderr).includes("Signature=adhoc"),
    );
  } else {
    check(
      output("file", binary).includes(
        architecture === "arm64" ? "ARM aarch64" : "x86-64",
      ),
    );
    check(
      !output("readelf", "-l", binary).includes("INTERP") &&
        !output("readelf", "-d", binary).includes("NEEDED"),
    );
  }
  console.log(JSON.stringify(info));
}
if (import.meta.main) {
  if (Deno.args[0] === "--help") {
    console.log("validate-daemon.ts <binary> <target> <build-id>");
  } else {
    check(Deno.args.length === 3, "Expected binary, target and build ID");
    validate(Deno.args[0], Deno.args[1], Deno.args[2]);
  }
}
