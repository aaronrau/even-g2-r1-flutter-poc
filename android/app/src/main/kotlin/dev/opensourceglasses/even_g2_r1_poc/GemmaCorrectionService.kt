package dev.opensourceglasses.even_g2_r1_poc

import android.app.ActivityManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.LogSeverity
import com.google.ai.edge.litertlm.SamplerConfig
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns the native LiteRT-LM engine in a process separate from Flutter, BLE,
 * capture, VAD, and STT. Requests are serialized to keep one engine and at
 * most one live conversation. A native failure can therefore restart this
 * process without interrupting durable audio capture.
 */
class GemmaCorrectionService : Service() {
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "workbench-gemma-worker")
    }
    private val watchdog = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "workbench-gemma-watchdog")
    }
    private val incoming =
        Messenger(
            Handler(Looper.getMainLooper()) { message ->
                when (message.what) {
                    GemmaCorrectionProtocol.REQUEST_CORRECTION -> {
                        val replyTo = message.replyTo
                        val data = Bundle(message.data)
                        worker.execute { correct(data, replyTo) }
                        true
                    }
                    GemmaCorrectionProtocol.REQUEST_RELEASE_ENGINE -> {
                        activeConversation?.runCatching { cancelProcess() }
                        worker.execute { releaseEngine("requested") }
                        true
                    }
                    else -> false
                }
            },
        )

    private var engine: Engine? = null
    private var loadedModelPath: String? = null
    private var engineGeneration = 0L
    private var idleEngineRelease: ScheduledFuture<*>? = null
    @Volatile
    private var activeConversation: Conversation? = null

    override fun onCreate() {
        super.onCreate()
        Engine.setNativeMinLogSeverity(LogSeverity.ERROR)
        Log.i(
            "WorkBench",
            "[WorkBench][Correction] state=service_ready process=isolated " +
                "runtime=litertlm-0.14.0 provider=gpu",
        )
    }

    override fun onBind(intent: Intent?): IBinder = incoming.binder

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= RUNNING_LOW_MEMORY_LEVEL) {
            if (level >= RUNNING_CRITICAL_MEMORY_LEVEL) {
                activeConversation?.runCatching { cancelProcess() }
            }
            worker.execute {
                if (activeConversation == null) {
                    releaseEngine("memory_pressure_$level")
                }
            }
        }
    }

    override fun onLowMemory() {
        activeConversation?.runCatching { cancelProcess() }
        worker.execute { releaseEngine("low_memory") }
        super.onLowMemory()
    }

    override fun onDestroy() {
        activeConversation?.runCatching { cancelProcess() }
        worker.submit { releaseEngine("service_destroyed") }.runCatching {
            get(10, TimeUnit.SECONDS)
        }
        worker.shutdownNow()
        watchdog.shutdownNow()
        super.onDestroy()
    }

    @OptIn(ExperimentalApi::class)
    private fun correct(data: Bundle, replyTo: Messenger?) {
        val requestId = data.getLong(GemmaCorrectionProtocol.KEY_REQUEST_ID, -1)
        val modelPath = data.getString(GemmaCorrectionProtocol.KEY_MODEL_PATH).orEmpty()
        val modelId = data.getString(GemmaCorrectionProtocol.KEY_MODEL_ID).orEmpty()
        val instructions =
            data.getString(GemmaCorrectionProtocol.KEY_INSTRUCTIONS).orEmpty()
        val transcript = data.getString(GemmaCorrectionProtocol.KEY_TRANSCRIPT).orEmpty()
        val timeoutMs =
            data.getLong(GemmaCorrectionProtocol.KEY_TIMEOUT_MS, DEFAULT_TIMEOUT_MS)
                .coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val totalTimer = android.os.SystemClock.elapsedRealtime()

        if (replyTo == null ||
            requestId < 0 ||
            instructions.isBlank() ||
            instructions.length > MAX_INSTRUCTION_CHARACTERS ||
            transcript.isBlank() ||
            transcript.length > MAX_TRANSCRIPT_CHARACTERS
        ) {
            replyError(
                replyTo,
                requestId,
                "invalid_request",
                "The correction request was incomplete.",
            )
            return
        }

        try {
            ensureMemoryAvailable()
            engineGeneration++
            idleEngineRelease?.cancel(false)
            idleEngineRelease = null
            val canonicalModel = validateModelPath(modelPath)
            val engineLoadMs = ensureEngine(canonicalModel)
            val conversation =
                checkNotNull(engine).createConversation(
                    ConversationConfig(
                        systemInstruction = Contents.of(instructions),
                        samplerConfig =
                            SamplerConfig(
                                topK = 1,
                                topP = 1.0,
                                temperature = 0.0,
                                seed = 0,
                            ),
                        automaticToolCalling = false,
                        extraContext = mapOf("enable_thinking" to false),
                    ),
                )
            activeConversation = conversation
            val completed = AtomicBoolean(false)
            var timeoutTask: ScheduledFuture<*>? = null
            try {
                timeoutTask =
                    watchdog.schedule(
                        {
                            if (completed.compareAndSet(false, true)) {
                                conversation.runCatching { cancelProcess() }
                            }
                        },
                        timeoutMs,
                        TimeUnit.MILLISECONDS,
                    )
                val inferenceStart = android.os.SystemClock.elapsedRealtime()
                val response =
                    conversation.sendMessage(
                        "Correct the ASR transcript below. Return only the corrected " +
                            "transcript text.\n\n<transcript>\n$transcript\n</transcript>",
                    )
                val inferenceMs =
                    android.os.SystemClock.elapsedRealtime() - inferenceStart
                if (completed.get()) {
                    throw CorrectionTimeoutException(timeoutMs)
                }
                completed.set(true)
                val corrected = response.toString().trim()
                if (corrected.isEmpty()) {
                    throw IllegalStateException("The model returned empty text.")
                }
                // LiteRT-LM 0.14.0 exposes getBenchmarkInfo(), but its public
                // EngineConfig cannot enable BenchmarkParams. Some packaged
                // models therefore complete inference and then throw from
                // this optional diagnostic call. Wall-clock engine, inference,
                // and pipeline timings remain authoritative in that case.
                val benchmark =
                    conversation.runCatching { getBenchmarkInfo() }.getOrNull()
                val responseData =
                    Bundle().apply {
                        putLong(GemmaCorrectionProtocol.KEY_REQUEST_ID, requestId)
                        putString(
                            GemmaCorrectionProtocol.KEY_CORRECTED_TEXT,
                            corrected,
                        )
                        putString(
                            GemmaCorrectionProtocol.KEY_PROVIDER,
                            "gpu",
                        )
                        putLong(
                            GemmaCorrectionProtocol.KEY_ENGINE_LOAD_MS,
                            engineLoadMs,
                        )
                        putLong(
                            GemmaCorrectionProtocol.KEY_INFERENCE_MS,
                            inferenceMs,
                        )
                        putLong(
                            GemmaCorrectionProtocol.KEY_TOTAL_MS,
                            android.os.SystemClock.elapsedRealtime() - totalTimer,
                        )
                        putLong(
                            GemmaCorrectionProtocol.KEY_TIME_TO_FIRST_TOKEN_MS,
                            benchmark
                                ?.timeToFirstTokenInSecond
                                ?.times(1000)
                                ?.toLong() ?: 0,
                        )
                        putDouble(
                            GemmaCorrectionProtocol.KEY_PREFILL_TOKENS_PER_SECOND,
                            benchmark?.lastPrefillTokensPerSecond ?: 0.0,
                        )
                        putDouble(
                            GemmaCorrectionProtocol.KEY_DECODE_TOKENS_PER_SECOND,
                            benchmark?.lastDecodeTokensPerSecond ?: 0.0,
                        )
                    }
                replyTo.send(
                    Message.obtain(
                        null,
                        GemmaCorrectionProtocol.RESPONSE_CORRECTION,
                    ).apply { this.data = responseData },
                )
                Log.i(
                    "WorkBench",
                    "[WorkBench][CorrectionNative] state=completed model=$modelId " +
                        "provider=gpu engine_load_ms=$engineLoadMs " +
                        "inference_ms=$inferenceMs total_ms=" +
                        (android.os.SystemClock.elapsedRealtime() - totalTimer) +
                        " ttft_ms=" +
                        (
                            benchmark
                                ?.timeToFirstTokenInSecond
                                ?.times(1000)
                                ?.toLong() ?: 0
                        ) +
                        " benchmark=${if (benchmark == null) "unavailable" else "available"}",
                )
            } finally {
                completed.set(true)
                timeoutTask?.cancel(false)
                activeConversation = null
                conversation.close()
                scheduleIdleEngineRelease()
            }
        } catch (error: Throwable) {
            val code =
                when (error) {
                    is CorrectionTimeoutException -> "timeout"
                    is CorrectionMemoryPressureException -> "memory_pressure"
                    is SecurityException -> "model_path"
                    else -> "inference_failed"
                }
            Log.e(
                "WorkBench",
                "[WorkBench][CorrectionNative] state=failed model=$modelId " +
                    "provider=gpu code=$code error=${oneLine(error)}",
            )
            replyError(replyTo, requestId, code, oneLine(error))
        }
    }

    private fun validateModelPath(modelPath: String): String {
        val model = File(modelPath).canonicalFile
        val root = File(filesDir, "workbench/models").canonicalFile
        if (!model.isFile ||
            !model.path.startsWith("${root.path}${File.separator}") ||
            model.extension.lowercase() != "litertlm"
        ) {
            throw SecurityException("The verified Gemma model is unavailable.")
        }
        return model.path
    }

    private fun ensureEngine(modelPath: String): Long {
        if (engine?.isInitialized() == true && loadedModelPath == modelPath) {
            return 0
        }
        releaseEngine("model_reload")
        val cache = File(cacheDir, "gemma-litertlm").apply { mkdirs() }
        val timer = android.os.SystemClock.elapsedRealtime()
        val candidate =
            Engine(
                EngineConfig(
                    modelPath = modelPath,
                    backend = Backend.GPU(),
                    maxNumTokens = MAX_NUM_TOKENS,
                    cacheDir = cache.path,
                ),
            )
        try {
            candidate.initialize()
        } catch (error: Throwable) {
            candidate.close()
            throw error
        }
        engine = candidate
        loadedModelPath = modelPath
        val elapsed = android.os.SystemClock.elapsedRealtime() - timer
        Log.i(
            "WorkBench",
            "[WorkBench][CorrectionNative] state=ready runtime=litertlm-0.14.0 " +
                "provider=gpu engine_load_ms=$elapsed",
        )
        return elapsed
    }

    private fun ensureMemoryAvailable() {
        val manager =
            getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(memory)
        if (memory.lowMemory) {
            throw CorrectionMemoryPressureException()
        }
    }

    private fun scheduleIdleEngineRelease() {
        idleEngineRelease?.cancel(false)
        val scheduledGeneration = engineGeneration
        idleEngineRelease =
            watchdog.schedule(
                {
                    worker.execute {
                        if (engineGeneration == scheduledGeneration &&
                            activeConversation == null
                        ) {
                            releaseEngine("idle_timeout")
                        }
                    }
                },
                ENGINE_IDLE_TIMEOUT_SECONDS,
                TimeUnit.SECONDS,
            )
    }

    private fun releaseEngine(reason: String) {
        engineGeneration++
        idleEngineRelease?.cancel(false)
        idleEngineRelease = null
        activeConversation?.runCatching { cancelProcess() }
        activeConversation = null
        engine?.runCatching { close() }
        engine = null
        loadedModelPath = null
        Log.i(
            "WorkBench",
            "[WorkBench][CorrectionNative] state=released reason=$reason",
        )
    }

    private fun replyError(
        target: Messenger?,
        requestId: Long,
        code: String,
        message: String,
    ) {
        if (target == null) {
            return
        }
        val data =
            Bundle().apply {
                putLong(GemmaCorrectionProtocol.KEY_REQUEST_ID, requestId)
                putString(GemmaCorrectionProtocol.KEY_ERROR_CODE, code)
                putString(GemmaCorrectionProtocol.KEY_ERROR_MESSAGE, message)
            }
        target.runCatching {
            send(
                Message.obtain(
                    null,
                    GemmaCorrectionProtocol.RESPONSE_CORRECTION,
                ).apply { this.data = data },
            )
        }
    }

    private fun oneLine(value: Any?): String =
        value.toString().replace(Regex("\\s+"), " ").trim().take(500)

    private class CorrectionTimeoutException(timeoutMs: Long) :
        RuntimeException("Correction timed out after ${timeoutMs}ms.")

    private class CorrectionMemoryPressureException :
        RuntimeException("Correction deferred because Android reported low memory.")

    companion object {
        private const val MAX_NUM_TOKENS = 2048
        // The editable base prompt is capped at 10,000 characters. Flutter
        // appends bounded agent names and acoustic aliases per live segment.
        private const val MAX_INSTRUCTION_CHARACTERS = 16_000
        private const val MAX_TRANSCRIPT_CHARACTERS = 6_000
        private const val RUNNING_LOW_MEMORY_LEVEL = 10
        private const val RUNNING_CRITICAL_MEMORY_LEVEL = 15
        private const val ENGINE_IDLE_TIMEOUT_SECONDS = 30L
        private const val DEFAULT_TIMEOUT_MS = 30_000L
        private const val MIN_TIMEOUT_MS = 5_000L
        private const val MAX_TIMEOUT_MS = 120_000L
    }
}
