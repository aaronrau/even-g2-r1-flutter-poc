package dev.opensourceglasses.even_g2_r1_poc

import android.app.Application
import android.util.Log
import io.reactivex.exceptions.UndeliverableException
import io.reactivex.plugins.RxJavaPlugins

/**
 * Prevents expected, late RxAndroidBle disconnect errors from terminating the
 * process when Android turns its Bluetooth adapter off.
 *
 * The BLE subscription has already delivered the disconnect to Dart by the
 * time these errors arrive, so RxJava cannot route them to a subscriber. Only
 * known transport-cancellation exceptions are consumed; programming errors
 * still reach the thread's uncaught-exception handler.
 */
class WorkBenchApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        RxJavaPlugins.setErrorHandler { incoming ->
            val error =
                if (incoming is UndeliverableException && incoming.cause != null) {
                    incoming.cause!!
                } else {
                    incoming
                }
            if (isExpectedBleCancellation(error)) {
                Log.i(TAG, "Ignored late BLE cancellation: ${error.javaClass.simpleName}")
                return@setErrorHandler
            }
            Thread.currentThread().uncaughtExceptionHandler
                ?.uncaughtException(Thread.currentThread(), error)
        }
    }

    private fun isExpectedBleCancellation(error: Throwable): Boolean {
        val className = error.javaClass.name
        return className.startsWith("com.polidea.rxandroidble2.exceptions.") &&
            (
                className.endsWith(".BleDisconnectedException") ||
                    className.endsWith(".BleAdapterDisabledException") ||
                    className.endsWith(".BleGattException")
            )
    }

    private companion object {
        const val TAG = "WorkBenchBle"
    }
}
