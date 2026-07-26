package dev.opensourceglasses.even_g2_r1_poc

internal object WorkBenchLc3 {
    init {
        System.loadLibrary("workbench_lc3")
    }

    private var decoder: Long = 0

    @Synchronized
    fun initialize(): Boolean {
        if (decoder == 0L) {
            decoder = nativeInitDecoder()
        }
        return decoder != 0L
    }

    @Synchronized
    fun decode(bytes: ByteArray, frameSize: Int): ByteArray {
        require(frameSize > 0) { "LC3 frame size must be positive" }
        require(bytes.isNotEmpty()) { "LC3 packet is empty" }
        require(bytes.size % frameSize == 0) {
            "LC3 packet length ${bytes.size} is not divisible by $frameSize"
        }
        check(initialize()) { "LC3 decoder initialization failed" }
        return nativeDecode(decoder, bytes, frameSize)
    }

    @Synchronized
    fun dispose() {
        if (decoder != 0L) {
            nativeFreeDecoder(decoder)
            decoder = 0
        }
    }

    private external fun nativeInitDecoder(): Long
    private external fun nativeDecode(
        decoder: Long,
        bytes: ByteArray,
        frameSize: Int,
    ): ByteArray
    private external fun nativeFreeDecoder(decoder: Long)
}
