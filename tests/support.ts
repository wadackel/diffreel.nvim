import { Process, within } from "../scripts/process.ts";
import {
  decode,
  decodeMultiStream,
  encode,
  ExtensionCodec,
} from "@msgpack/msgpack";
import {
  assert,
  decoder,
  join,
  mkdir,
  now,
  ROOT,
  sleep,
  write,
} from "../scripts/lib.ts";
export { git } from "../scripts/lib.ts";
export const PLUGIN = ROOT;
type Cell = [string, number];
interface Highlight {
  foreground?: number;
  background?: number;
  reverse?: boolean;
}
interface Pending {
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer: ReturnType<typeof setTimeout>;
}
export interface NvimOptions {
  normal?: boolean;
  columns?: number;
  rows?: number;
  env?: Record<string, string>;
  source?: boolean | string;
  daemon?: boolean;
}

export class Nvim {
  readonly process: Process;
  private writer: WritableStreamDefaultWriter<Uint8Array>;
  private writes = Promise.resolve();
  private pending = new Map<number, Pending>();
  private sequence = 0;
  private ended?: Error;
  private reading: Promise<void>;
  private errors: Promise<void>;
  private closing?: Promise<void>;
  stderr = "";
  grids = new Map<number, Cell[][]>();
  highlights: Record<number, Highlight> = {};
  defaultFg = 0xd4d4d4;
  defaultBg = 0x171717;
  frames = 0;
  lastFrame = 0;
  frameTimes: number[] = [];
  events: [number, string, unknown[]][] = [];
  channel = 0;
  normal = false;
  caseLabel = "";
  requestTimeout = 20;

  private constructor(process: Process) {
    this.process = process;
    this.writer = this.process.stdin.getWriter();
    const stderr = this.process.stderr;
    this.errors = (async () => {
      for await (const bytes of stderr) {
        this.stderr += decoder.decode(bytes, { stream: true });
      }
    })();
    this.reading = this.read();
  }

  static async create(cwd: string, options: NvimOptions = {}) {
    const args = ["--embed", "--headless", "-n", "-i", "NONE"];
    if (!options.normal) args.push("-u", "NONE");
    const nvim = new Nvim(
      await Process.spawn("nvim", { args, cwd, env: options.env }),
    );
    nvim.normal = options.normal ?? false;
    try {
      const info = await nvim.request("nvim_get_api_info") as [number, unknown];
      nvim.channel = info[0];
      await nvim.request(
        "nvim_ui_attach",
        options.columns ?? 140,
        options.rows ?? 40,
        { rgb: true, ext_linegrid: true },
      );
      if (options.source !== false) {
        await nvim.lua(
          "vim.opt.rtp:prepend(...)",
          typeof options.source === "string" ? options.source : PLUGIN,
        );
      }
      await nvim.lua("vim.cmd('filetype on')");
      const daemon = (options.env ?? Deno.env.toObject()).DIFFREEL_DAEMON;
      if (daemon && options.daemon !== false) {
        await nvim.lua("vim.g.diffreel_daemon = ...", daemon);
      }
      return nvim;
    } catch (error) {
      await nvim.close();
      throw error;
    }
  }

  private stop(error: Error) {
    this.ended = error;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
  }

  private async read() {
    const extensionCodec = new ExtensionCodec();
    for (const type of [0, 1, 2]) {
      extensionCodec.register({
        type,
        encode: () => null,
        decode: (data) => decode(data),
      });
    }
    try {
      for await (
        const message of decodeMultiStream(this.process.stdout, {
          extensionCodec,
        })
      ) {
        assert(Array.isArray(message), "Invalid Neovim RPC message");
        if (message[0] === 1) {
          const request = this.pending.get(message[1]);
          if (request) {
            this.pending.delete(message[1]);
            clearTimeout(request.timer);
            if (message[2] !== null) {
              request.reject(new Error(JSON.stringify(message[2])));
            } else request.resolve(message[3]);
          }
        } else if (message[0] === 2) {
          if (message[1] === "redraw") this.redraw(message[2]);
          else this.events.push([now(), message[1], message[2]]);
        }
      }
      this.stop(new Error("Neovim exited: " + this.stderr));
    } catch (error) {
      this.stop(
        new Error("Neovim exited: " + String(error) + "\n" + this.stderr),
      );
    }
  }

  private redraw(batches: unknown) {
    assert(Array.isArray(batches));
    for (const batch of batches) {
      assert(Array.isArray(batch));
      const [event, ...values] = batch;
      for (const args of values) {
        assert(Array.isArray(args));
        if (event === "grid_resize") {
          this.grids.set(
            args[0],
            Array.from(
              { length: args[2] },
              () => Array.from({ length: args[1] }, (): Cell => [" ", 0]),
            ),
          );
        } else if (event === "grid_clear") {
          const grid = this.grids.get(args[0]);
          if (grid) { for (const row of grid) row.fill([" ", 0]); }
        } else if (event === "grid_line") {
          const [id, row, start, cells] = args, grid = this.grids.get(id);
          assert(grid, "Unknown UI grid");
          let column = start, highlight = 0;
          for (const cell of cells) {
            if (cell.length > 1) highlight = cell[1];
            for (let i = 0; i < (cell[2] ?? 1); i++) {
              if (grid[row] && column < grid[row].length) {
                grid[row][column] = [cell[0], highlight];
              }
              column++;
            }
          }
        } else if (event === "grid_scroll") {
          const [id, top, bottom, left, right, dy, dx] = args,
            grid = this.grids.get(id);
          assert(grid);
          const previous = grid.map((row) => [...row]);
          for (let row = top; row < bottom; row++) {
            for (let col = left; col < right; col++) {
              grid[row][col] =
                row + dy >= top && row + dy < bottom && col + dx >= left &&
                  col + dx < right
                  ? previous[row + dy][col + dx]
                  : [" ", 0];
            }
          }
        } else if (event === "hl_attr_define") {
          this.highlights[args[0]] = args[1];
        } else if (event === "default_colors_set") {
          if (args[0] >= 0) this.defaultFg = args[0];
          if (args[1] >= 0) this.defaultBg = args[1];
        } else if (event === "flush") {
          this.frames++;
          this.lastFrame = now();
          this.frameTimes.push(this.lastFrame);
        }
      }
    }
  }

  request(method: string, ...args: unknown[]) {
    return this.requestWithTimeout(method, args, this.requestTimeout);
  }
  requestWithTimeout(
    method: string,
    args: unknown[],
    timeout: number,
  ): Promise<unknown> {
    if (this.ended) return Promise.reject(this.ended);
    const sequence = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(sequence);
        reject(
          new Error(`Timed out: ${method}\n${this.text()}\n${this.stderr}`),
        );
      }, timeout * 1000);
      this.pending.set(sequence, { resolve, reject, timer });
      this.writes = this.writes.then(() =>
        this.writer.write(encode([0, sequence, method, args]))
      ).catch((error) =>
        this.stop(new Error("Neovim exited: " + String(error)))
      );
    });
  }
  // A single result schema cannot describe caller-supplied Lua expressions.
  // deno-lint-ignore no-explicit-any
  async lua<T = any>(code: string, ...args: unknown[]): Promise<T> {
    return await this.request("nvim_exec_lua", code, args) as T;
  }
  async wait(expression: string, timeout = 10) {
    const deadline = now() + timeout;
    while (now() < deadline) {
      const value = await this.lua(expression);
      if (value) return value;
      await sleep(0.005);
    }
    throw new Error(`Timed out: ${expression}\n${this.text()}\n${this.stderr}`);
  }
  async waitFrame(previous: number, timeout = 3) {
    const deadline = now() + timeout;
    while (this.frames <= previous) {
      if (this.ended) throw this.ended;
      assert(now() < deadline, "Missing UI flush");
      await sleep(0.005);
    }
  }
  text() {
    return (this.grids.get(1) ?? []).map((row) =>
      row.map(([text]) => text).join("").trimEnd()
    ).join("\n");
  }
  async readyFrame(token: string, started: number, timeout = 20) {
    const deadline = now() + timeout;
    while (now() < deadline) {
      const ready = this.events.find(([at, name, args]) =>
        name === "diffreel_bench_ready" && args[0] === token && at >= started
      )?.[0];
      const frame = ready === undefined
        ? undefined
        : this.frameTimes.find((at) => at >= ready);
      if (frame !== undefined) return (frame - started) * 1000;
      if (this.ended) throw this.ended;
      await sleep(0.005);
    }
    throw new Error(`Missing ready frame for ${token}\n${this.text()}`);
  }
  capture(directory: string, name: string) {
    if (this.caseLabel) name = this.caseLabel + "-" + name;
    mkdir(directory);
    const grid = this.grids.get(1) ?? [];
    write(join(directory, name + ".txt"), this.text());
    const color = (value: number) => "#" + value.toString(16).padStart(6, "0");
    const escape = (value: string) =>
      value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(
        ">",
        "&gt;",
      ).replaceAll('"', "&quot;").replaceAll("'", "&#x27;");
    const pieces = [
      `<svg xmlns="http://www.w3.org/2000/svg" width="${
        (grid[0]?.length ?? 1) * 9
      }" height="${grid.length * 19}">`,
      `<rect width="100%" height="100%" fill="${color(this.defaultBg)}"/>`,
      '<g font-family="monospace" font-size="14">',
    ];
    grid.forEach((row, y) =>
      row.forEach(([char, highlight], x) => {
        const style = this.highlights[highlight] ?? {};
        let fg = style.foreground ?? this.defaultFg,
          bg = style.background ?? this.defaultBg;
        if (style.reverse) [fg, bg] = [bg, fg];
        if (bg !== this.defaultBg) {
          pieces.push(
            `<rect x="${x * 9}" y="${y * 19}" width="9" height="19" fill="${
              color(bg)
            }"/>`,
          );
        }
        if (char && char !== " ") {
          pieces.push(
            `<text x="${x * 9}" y="${y * 19 + 15}" fill="${color(fg)}">${
              escape(char)
            }</text>`,
          );
        }
      })
    );
    pieces.push("</g>", "</svg>");
    write(join(directory, name + ".svg"), pieces.join("\n"));
    write(
      join(directory, name + ".json"),
      JSON.stringify({
        frames: this.frames,
        grid,
        highlights: this.highlights,
      }),
    );
  }
  close() {
    return this.closing ??= (async () => {
      if (!this.ended) {
        try {
          await this.requestWithTimeout("nvim_exec_lua", [
            "if package.loaded.diffreel then require('diffreel').shutdown() end",
            [],
          ], 5);
          await this.requestWithTimeout("nvim_command", ["qa!"], 5);
        } catch { /* Closing Neovim can end the transport before its reply. */ }
      }
      const timer = setTimeout(() => {
        try {
          this.process.terminate();
        } catch { /* The exit notification can race the deadline. */ }
      }, 5000);
      try {
        await this.process.status;
        await within(
          Promise.all([this.reading, this.errors]),
          1,
          "Neovim pipes remained open",
        );
        try {
          await this.writer.close();
        } catch { /* A closed child no longer accepts EOF. */ }
      } finally {
        clearTimeout(timer);
        this.process.terminate();
        this.process.destroyPipes();
        await Promise.allSettled([this.reading, this.errors]);
      }
    })();
  }
}
