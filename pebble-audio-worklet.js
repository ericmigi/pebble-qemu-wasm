// Consume the QEMU PCM ring on WebAudio's sample clock. The read cursor is
// published only after samples have actually contributed to the output.
class PebbleAudioProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const {memory, control} = options.processorOptions;
    this.u32 = new Uint32Array(memory);
    this.i16 = new Int16Array(memory);
    this.base = control >>> 2;
    this.phase = 0;
    this.blocks = 0;
    this.nonzero = 0;
    this.emptyFrames = 0;
    this.peak = 0;
    this.maxQueued = 0;
  }

  process(inputs, outputs) {
    const output = outputs[0][0];
    if (!output) return true;
    const u32 = this.u32, base = this.base;
    const ptr = Atomics.load(u32, base) >>> 1;
    const size = Atomics.load(u32, base + 1);
    const rate = Atomics.load(u32, base + 4) || 16000;
    const volume = Math.min(100, Atomics.load(u32, base + 5)) / 100;
    const head = Atomics.load(u32, base + 2);
    let tail = Atomics.load(u32, base + 3);
    let available = (head - tail) >>> 0;
    if (!size || available > size) {
      output.fill(0);
      return true;
    }
    this.maxQueued = Math.max(this.maxQueued, available);
    const step = rate / sampleRate;
    for (let i = 0; i < output.length; i++) {
      if (!available) {
        output[i] = 0;
        this.phase = 0;
        this.emptyFrames++;
        continue;
      }
      const a = this.i16[ptr + tail % size];
      const b = available > 1 ? this.i16[ptr + ((tail + 1) >>> 0) % size] : a;
      const value = (a + (b - a) * this.phase) / 32768 * volume;
      output[i] = value;
      if (value !== 0) this.nonzero++;
      this.peak = Math.max(this.peak, Math.abs(value));
      this.phase += step;
      const consumed = Math.min(available, Math.floor(this.phase));
      tail = (tail + consumed) >>> 0;
      available -= consumed;
      this.phase -= consumed;
    }
    Atomics.store(u32, base + 3, tail);
    if (++this.blocks % 128 === 0) {
      this.port.postMessage({nonzero: this.nonzero, emptyFrames: this.emptyFrames,
        peak: this.peak, queued: available, maxQueued: this.maxQueued, rate, sampleRate});
    }
    return true;
  }
}

registerProcessor('pebble-audio', PebbleAudioProcessor);
