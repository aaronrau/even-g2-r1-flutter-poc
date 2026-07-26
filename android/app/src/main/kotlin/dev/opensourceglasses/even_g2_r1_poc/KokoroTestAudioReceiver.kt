package dev.opensourceglasses.even_g2_r1_poc

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.util.Log
import java.io.File

/**
 * ADB-only acoustic-loop test hook. It exists in debug builds so the local
 * Kokoro validation skill can play a deterministic phrase through the phone
 * speaker when a workstation has no audible speaker near the glasses.
 */
class KokoroTestAudioReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION =
            "dev.opensourceglasses.even_g2_r1_poc.PLAY_KOKORO_TEST"
        const val FILE_NAME = "kokoro-test.wav"
        private var activePlayer: MediaPlayer? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) {
            return
        }
        val source = File(context.filesDir, FILE_NAME)
        if (!source.isFile) {
            Log.e("WorkBench", "[KokoroTest] state=failed reason=missing_file")
            return
        }
        try {
            activePlayer?.release()
            activePlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                setDataSource(source.absolutePath)
                setVolume(1.0f, 1.0f)
                setOnCompletionListener { player ->
                    Log.i("WorkBench", "[KokoroTest] state=completed")
                    player.release()
                    if (activePlayer === player) {
                        activePlayer = null
                    }
                }
                prepare()
                start()
            }
            Log.i("WorkBench", "[KokoroTest] state=playing")
        } catch (error: Exception) {
            activePlayer?.release()
            activePlayer = null
            Log.e("WorkBench", "[KokoroTest] state=failed", error)
        }
    }
}
