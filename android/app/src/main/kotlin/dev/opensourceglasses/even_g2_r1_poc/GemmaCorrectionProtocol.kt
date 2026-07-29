package dev.opensourceglasses.even_g2_r1_poc

internal object GemmaCorrectionProtocol {
    const val REQUEST_CORRECTION = 1
    const val RESPONSE_CORRECTION = 2
    const val REQUEST_RELEASE_ENGINE = 3

    const val KEY_REQUEST_ID = "requestId"
    const val KEY_MODEL_PATH = "modelPath"
    const val KEY_MODEL_ID = "modelId"
    const val KEY_INSTRUCTIONS = "instructions"
    const val KEY_TRANSCRIPT = "transcript"
    const val KEY_TIMEOUT_MS = "timeoutMs"
    const val KEY_TASK = "task"
    const val KEY_CORRECTED_TEXT = "correctedText"
    const val KEY_PROVIDER = "provider"
    const val KEY_ENGINE_LOAD_MS = "engineLoadMs"
    const val KEY_INFERENCE_MS = "inferenceMs"
    const val KEY_TOTAL_MS = "totalMs"
    const val KEY_TIME_TO_FIRST_TOKEN_MS = "timeToFirstTokenMs"
    const val KEY_PREFILL_TOKENS_PER_SECOND = "prefillTokensPerSecond"
    const val KEY_DECODE_TOKENS_PER_SECOND = "decodeTokensPerSecond"
    const val KEY_ERROR_CODE = "errorCode"
    const val KEY_ERROR_MESSAGE = "errorMessage"
}
