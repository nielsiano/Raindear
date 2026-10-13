// Runs RainSynth (Embedded Swift, compiled to rain.wasm) on the audio thread.
// The main thread compiles the module and passes it in processorOptions, since
// fetch is not available in AudioWorkletGlobalScope.
class RainProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();
        const { module, seedLow, seedHigh, settings } = options.processorOptions;
        this.wasm = new WebAssembly.Instance(module, {}).exports;
        this.wasm._initialize();
        this.wasm.rain_set_settings(...settings);
        this.wasm.rain_create(sampleRate, seedLow, seedHigh);
        this.port.onmessage = ({ data }) => {
            if (data.type === 'settings') this.wasm.rain_set_settings(...data.values);
            if (data.type === 'playing') this.wasm.rain_set_playing(data.playing ? 1 : 0);
        };
    }

    process(inputs, outputs) {
        const [left, right] = outputs[0];
        const frames = left.length;
        this.wasm.rain_render(frames);
        // Views are rebuilt each block because memory.grow detaches the old buffer.
        const memory = this.wasm.memory.buffer;
        left.set(new Float32Array(memory, this.wasm.rain_left(), frames));
        right.set(new Float32Array(memory, this.wasm.rain_right(), frames));
        return true;
    }
}

registerProcessor('rain', RainProcessor);
