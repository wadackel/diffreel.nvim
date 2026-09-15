export class Random {
  private state = new Uint32Array(624);
  private index = 624;
  constructor(seed: number) {
    if (!Number.isSafeInteger(seed)) {
      throw new Error("Seed must be a safe integer");
    }
    let value = BigInt(Math.abs(seed));
    const keys: number[] = [];
    do {
      keys.push(Number(value & 0xffffffffn));
      value >>= 32n;
    } while (value);
    this.state[0] = 19650218;
    for (let i = 1; i < 624; i++) {
      this.state[i] =
        Math.imul(1812433253, this.state[i - 1] ^ (this.state[i - 1] >>> 30)) +
        i;
    }
    let i = 1, j = 0;
    for (let k = Math.max(624, keys.length); k > 0; k--) {
      this.state[i] = (this.state[i] ^
        Math.imul(this.state[i - 1] ^ (this.state[i - 1] >>> 30), 1664525)) +
        keys[j] + j;
      if (++i >= 624) {
        this.state[0] = this.state[623];
        i = 1;
      }
      if (++j >= keys.length) j = 0;
    }
    for (let k = 623; k > 0; k--) {
      this.state[i] = (this.state[i] ^
        Math.imul(
          this.state[i - 1] ^ (this.state[i - 1] >>> 30),
          1566083941,
        )) - i;
      if (++i >= 624) {
        this.state[0] = this.state[623];
        i = 1;
      }
    }
    this.state[0] = 0x80000000;
  }
  private word() {
    if (this.index >= 624) {
      for (let i = 0; i < 624; i++) {
        const y = (this.state[i] & 0x80000000) |
          (this.state[(i + 1) % 624] & 0x7fffffff);
        this.state[i] = this.state[(i + 397) % 624] ^ (y >>> 1) ^
          ((y & 1) ? 0x9908b0df : 0);
      }
      this.index = 0;
    }
    let y = this.state[this.index++];
    y ^= y >>> 11;
    y ^= (y << 7) & 0x9d2c5680;
    y ^= (y << 15) & 0xefc60000;
    y ^= y >>> 18;
    return y >>> 0;
  }
  randrange(n: number) {
    if (!Number.isInteger(n) || n < 1 || n > 0xffffffff) {
      throw new Error("Invalid random range");
    }
    const bits = 32 - Math.clz32(n);
    let result: number;
    do {
      result = this.word() >>> (32 - bits);
    } while (result >= n);
    return result;
  }
  choice<T>(values: readonly T[]) {
    return values[this.randrange(values.length)];
  }
  sample<T>(values: readonly T[], count: number): T[] {
    if (count < 0 || count > values.length) {
      throw new Error("Invalid sample size");
    }
    const result: T[] = [], n = values.length;
    let setSize = 21;
    if (count > 5) setSize += 4 ** Math.ceil(Math.log(count * 3) / Math.log(4));
    if (n <= setSize) {
      const pool = [...values];
      for (let i = 0; i < count; i++) {
        const j = this.randrange(n - i);
        result.push(pool[j]);
        pool[j] = pool[n - i - 1];
      }
    } else {
      const selected = new Set<number>();
      for (let i = 0; i < count; i++) {
        let j = this.randrange(n);
        while (selected.has(j)) j = this.randrange(n);
        selected.add(j);
        result.push(values[j]);
      }
    }
    return result;
  }
}
