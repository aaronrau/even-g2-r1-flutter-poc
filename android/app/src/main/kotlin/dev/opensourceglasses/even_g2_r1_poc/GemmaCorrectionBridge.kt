package dev.opensourceglasses.even_g2_r1_poc

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicLong

/** Bridges Flutter requests to the cross-process Gemma service with Messenger. */
internal class GemmaCorrectionBridge(private val context: Context) :
    ServiceConnection {
    private data class PendingRequest(
        val message: Message,
        val result: MethodChannel.Result,
    )

    private val nextRequestId = AtomicLong(1)
    private val pendingById = mutableMapOf<Long, MethodChannel.Result>()
    private val waitingForService = mutableListOf<PendingRequest>()
    private var service: Messenger? = null
    private var binding = false
    private val replies =
        Messenger(
            Handler(Looper.getMainLooper()) { message ->
                if (message.what != GemmaCorrectionProtocol.RESPONSE_CORRECTION &&
                    message.what != GemmaCorrectionProtocol.RESPONSE_ENGINE_READY
                ) {
                    return@Handler false
                }
                val data = message.data
                val requestId =
                    data.getLong(GemmaCorrectionProtocol.KEY_REQUEST_ID, -1)
                val result = pendingById.remove(requestId) ?: return@Handler true
                val errorCode =
                    data.getString(GemmaCorrectionProtocol.KEY_ERROR_CODE)
                if (errorCode != null) {
                    result.error(
                        errorCode,
                        data.getString(
                            GemmaCorrectionProtocol.KEY_ERROR_MESSAGE,
                        ),
                        null,
                    )
                } else if (
                    message.what == GemmaCorrectionProtocol.RESPONSE_ENGINE_READY
                ) {
                    result.success(null)
                } else {
                    result.success(
                        mapOf(
                            "correctedText" to
                                data.getString(
                                    GemmaCorrectionProtocol.KEY_CORRECTED_TEXT,
                                ),
                            "provider" to
                                data.getString(
                                    GemmaCorrectionProtocol.KEY_PROVIDER,
                                ),
                            "engineLoadMs" to
                                data.getLong(
                                    GemmaCorrectionProtocol.KEY_ENGINE_LOAD_MS,
                                ),
                            "inferenceMs" to
                                data.getLong(
                                    GemmaCorrectionProtocol.KEY_INFERENCE_MS,
                                ),
                            "totalMs" to
                                data.getLong(
                                    GemmaCorrectionProtocol.KEY_TOTAL_MS,
                                ),
                            "timeToFirstTokenMs" to
                                data.getLong(
                                    GemmaCorrectionProtocol.KEY_TIME_TO_FIRST_TOKEN_MS,
                                ),
                            "prefillTokensPerSecond" to
                                data.getDouble(
                                    GemmaCorrectionProtocol.KEY_PREFILL_TOKENS_PER_SECOND,
                                ),
                            "decodeTokensPerSecond" to
                                data.getDouble(
                                    GemmaCorrectionProtocol.KEY_DECODE_TOKENS_PER_SECOND,
                                ),
                        ),
                    )
                }
                true
            },
        )

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "correct" -> requestCorrection(call, result)
            "prepareEngine" -> requestEnginePreparation(call, result)
            "releaseEngine" -> {
                service?.runCatching {
                    send(
                        Message.obtain(
                            null,
                            GemmaCorrectionProtocol.REQUEST_RELEASE_ENGINE,
                        ),
                    )
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestEnginePreparation(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val modelPath = call.argument<String>("modelPath")
        val modelId = call.argument<String>("modelId")
        if (modelPath == null || modelId == null) {
            result.error(
                "invalid_request",
                "The engine preparation request was incomplete.",
                null,
            )
            return
        }
        val requestId = nextRequestId.getAndIncrement()
        val data =
            Bundle().apply {
                putLong(GemmaCorrectionProtocol.KEY_REQUEST_ID, requestId)
                putString(GemmaCorrectionProtocol.KEY_MODEL_PATH, modelPath)
                putString(GemmaCorrectionProtocol.KEY_MODEL_ID, modelId)
            }
        val message =
            Message.obtain(
                null,
                GemmaCorrectionProtocol.REQUEST_PREPARE_ENGINE,
            ).apply {
                this.data = data
                replyTo = replies
            }
        queueOrSend(requestId, message, result)
    }

    private fun requestCorrection(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val modelPath = call.argument<String>("modelPath")
        val modelId = call.argument<String>("modelId")
        val instructions = call.argument<String>("instructions")
        val transcript = call.argument<String>("transcript")
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong()
        val task =
            call.argument<String>("task") ?: "transcript_correction"
        if (modelPath == null ||
            modelId == null ||
            instructions == null ||
            transcript == null ||
            timeoutMs == null
        ) {
            result.error(
                "invalid_request",
                "The correction request was incomplete.",
                null,
            )
            return
        }
        val requestId = nextRequestId.getAndIncrement()
        val data =
            Bundle().apply {
                putLong(GemmaCorrectionProtocol.KEY_REQUEST_ID, requestId)
                putString(GemmaCorrectionProtocol.KEY_MODEL_PATH, modelPath)
                putString(GemmaCorrectionProtocol.KEY_MODEL_ID, modelId)
                putString(
                    GemmaCorrectionProtocol.KEY_INSTRUCTIONS,
                    instructions,
                )
                putString(GemmaCorrectionProtocol.KEY_TRANSCRIPT, transcript)
                putLong(GemmaCorrectionProtocol.KEY_TIMEOUT_MS, timeoutMs)
                putString(GemmaCorrectionProtocol.KEY_TASK, task)
            }
        val message =
            Message.obtain(
                null,
                GemmaCorrectionProtocol.REQUEST_CORRECTION,
            ).apply {
                this.data = data
                replyTo = replies
            }
        queueOrSend(requestId, message, result)
    }

    private fun queueOrSend(
        requestId: Long,
        message: Message,
        result: MethodChannel.Result,
    ) {
        pendingById[requestId] = result
        val target = service
        if (target != null) {
            send(target, requestId, message)
            return
        }
        waitingForService.add(PendingRequest(message, result))
        bind()
    }

    private fun bind() {
        if (binding || service != null) {
            return
        }
        binding = true
        val accepted =
            context.bindService(
                Intent(context, GemmaCorrectionService::class.java),
                this,
                Context.BIND_AUTO_CREATE,
            )
        if (!accepted) {
            binding = false
            failAll("service_unavailable", "The Gemma service could not start.")
        }
    }

    override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
        binding = false
        service = Messenger(binder)
        val queued = waitingForService.toList()
        waitingForService.clear()
        for (pending in queued) {
            val requestId =
                pending.message.data.getLong(
                    GemmaCorrectionProtocol.KEY_REQUEST_ID,
                    -1,
                )
            send(checkNotNull(service), requestId, pending.message)
        }
    }

    override fun onServiceDisconnected(name: ComponentName?) {
        service = null
        binding = false
        failAll(
            "service_disconnected",
            "The Gemma process stopped. The transcript remains safely queued.",
        )
    }

    override fun onBindingDied(name: ComponentName?) {
        onServiceDisconnected(name)
    }

    private fun send(target: Messenger, requestId: Long, message: Message) {
        try {
            target.send(message)
        } catch (_: Exception) {
            pendingById.remove(requestId)?.error(
                "service_send_failed",
                "The Gemma process could not receive the request.",
                null,
            )
            service = null
        }
    }

    private fun failAll(code: String, message: String) {
        waitingForService.clear()
        val outstanding = pendingById.values.toList()
        pendingById.clear()
        for (result in outstanding) {
            result.error(code, message, null)
        }
    }

    fun dispose() {
        if (service != null || binding) {
            context.runCatching {
                unbindService(this@GemmaCorrectionBridge)
            }
        }
        service = null
        binding = false
        failAll("activity_closed", "The app closed before correction completed.")
    }
}
