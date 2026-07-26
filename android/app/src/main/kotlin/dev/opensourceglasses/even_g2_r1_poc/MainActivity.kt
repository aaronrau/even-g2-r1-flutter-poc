package dev.opensourceglasses.even_g2_r1_poc

import android.bluetooth.BluetoothManager
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val BACKGROUND_CHANNEL =
            "dev.opensourceglasses/background_connection"
        private const val BLUETOOTH_BOND_CHANNEL =
            "dev.opensourceglasses/r1_bond"
        private const val LC3_CHANNEL =
            "dev.opensourceglasses/workbench_lc3"
        private const val RUNTIME_CHANNEL =
            "dev.opensourceglasses/workbench_runtime"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "start" -> {
                    if (!BleConnectionService.isRunning) {
                        ContextCompat.startForegroundService(
                            applicationContext,
                            Intent(applicationContext, BleConnectionService::class.java),
                        )
                    }
                    result.success(null)
                }
                "stop" -> {
                    applicationContext.stopService(
                        Intent(applicationContext, BleConnectionService::class.java),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BLUETOOTH_BOND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bondState" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("missing_address", "R1 address is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val manager = getSystemService(BluetoothManager::class.java)
                        val adapter = manager.adapter
                        result.success(adapter?.getRemoteDevice(address)?.bondState)
                    } catch (error: Exception) {
                        result.error("bond_state", error.message, null)
                    }
                }
                "createBond" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("missing_address", "Bluetooth address is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val manager = getSystemService(BluetoothManager::class.java)
                        val device = manager.adapter?.getRemoteDevice(address)
                        result.success(
                            device != null &&
                                (device.bondState == android.bluetooth.BluetoothDevice.BOND_BONDED ||
                                    device.createBond()),
                        )
                    } catch (error: Exception) {
                        result.error("create_bond", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LC3_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    try {
                        result.success(WorkBenchLc3.initialize())
                    } catch (error: Throwable) {
                        result.error("lc3_initialize", error.message, null)
                    }
                }
                "decode" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val frameSize = call.argument<Int>("frameSize") ?: 40
                    if (bytes == null) {
                        result.error("lc3_input", "LC3 bytes are required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(WorkBenchLc3.decode(bytes, frameSize))
                    } catch (error: Throwable) {
                        result.error("lc3_decode", error.message, null)
                    }
                }
                "dispose" -> {
                    WorkBenchLc3.dispose()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RUNTIME_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "inferenceCapabilities" -> {
                    val activityManager =
                        getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val glesVersion =
                        activityManager.deviceConfigurationInfo.reqGlEsVersion
                    val hasNeuralNetworks =
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
                    result.success(
                        mapOf(
                            "glesVersion" to glesVersion,
                            "hasGpu" to (glesVersion >= 0x00030000),
                            "hasNeuralNetworks" to hasNeuralNetworks,
                            "sdkInt" to Build.VERSION.SDK_INT,
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        WorkBenchLc3.dispose()
        super.onDestroy()
    }
}
