package dev.opensourceglasses.even_g2_r1_poc

import android.app.Activity
import android.app.ActivityManager
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

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
        private const val STORAGE_CHANNEL =
            "dev.opensourceglasses/workbench_storage"
        private const val STORAGE_PREFERENCES = "workbench_storage"
        private const val STORAGE_DIRECTORY_URI = "shared_audio_directory_uri"
        private const val CHOOSE_DIRECTORY_REQUEST = 4201
    }

    private var pendingDirectoryResult: MethodChannel.Result? = null
    private val storageExecutor = Executors.newSingleThreadExecutor()

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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "currentDirectory" -> result.success(currentDirectory())
                "chooseDirectory" -> chooseDirectory(result)
                "clearDirectory" -> {
                    clearDirectory()
                    result.success(null)
                }
                "exportFiles" -> {
                    val paths = call.argument<List<String>>("paths")
                    if (paths == null) {
                        result.error(
                            "missing_paths",
                            "Audio or transcript files are required.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    exportFiles(paths, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun chooseDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error(
                "directory_picker_active",
                "The folder picker is already open.",
                null,
            )
            return
        }
        pendingDirectoryResult = result
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            }
        startActivityForResult(intent, CHOOSE_DIRECTORY_REQUEST)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CHOOSE_DIRECTORY_REQUEST) {
            return
        }
        val result = pendingDirectoryResult ?: return
        pendingDirectoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val flags =
                data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            releaseStoredDirectory(except = uri)
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putString(STORAGE_DIRECTORY_URI, uri.toString())
                .apply()
            result.success(directoryMessage(uri))
        } catch (_: Exception) {
            result.error(
                "directory_access",
                "Could not retain access to that folder.",
                null,
            )
        }
    }

    private fun currentDirectory(): Map<String, String>? {
        val uri = storedDirectoryUri() ?: return null
        return try {
            directoryMessage(uri)
        } catch (_: Exception) {
            clearDirectory()
            null
        }
    }

    private fun directoryMessage(uri: Uri): Map<String, String> =
        mapOf("displayName" to directoryDisplayName(uri))

    private fun directoryDisplayName(uri: Uri): String {
        val documentUri =
            DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri),
            )
        contentResolver.query(
            documentUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val displayName = cursor.getString(0)?.trim()
                if (!displayName.isNullOrEmpty()) {
                    return displayName
                }
            }
        }
        return "Selected folder"
    }

    private fun storedDirectoryUri(): Uri? {
        val raw =
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .getString(STORAGE_DIRECTORY_URI, null)
                ?: return null
        val uri = Uri.parse(raw)
        val retained =
            contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isWritePermission
            }
        if (!retained) {
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .remove(STORAGE_DIRECTORY_URI)
                .apply()
            return null
        }
        return uri
    }

    private fun clearDirectory() {
        releaseStoredDirectory()
        getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .remove(STORAGE_DIRECTORY_URI)
            .apply()
    }

    private fun releaseStoredDirectory(except: Uri? = null) {
        val raw =
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .getString(STORAGE_DIRECTORY_URI, null)
                ?: return
        val uri = Uri.parse(raw)
        if (uri == except) {
            return
        }
        try {
            contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // The provider may already have revoked access.
        }
    }

    private fun exportFiles(
        paths: List<String>,
        result: MethodChannel.Result,
    ) {
        val directory = storedDirectoryUri()
        if (directory == null) {
            result.error(
                "directory_unavailable",
                "Choose the shared save folder again.",
                null,
            )
            return
        }
        storageExecutor.execute {
            try {
                var exported = 0
                for (path in paths.distinct()) {
                    exportInternalFile(directory, path)
                    exported++
                }
                runOnUiThread { result.success(exported) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "export_failed",
                        "Could not save files to the selected folder.",
                        null,
                    )
                }
            }
        }
    }

    private fun exportInternalFile(
        directory: Uri,
        sourcePath: String,
    ) {
        val source = File(sourcePath).canonicalFile
        val internalRoot = filesDir.canonicalFile
        if (!source.isFile ||
            !source.path.startsWith("${internalRoot.path}${File.separator}")
        ) {
            throw SecurityException("Source is outside app storage.")
        }
        val mimeType =
            when (source.extension.lowercase()) {
                "wav" -> "audio/wav"
                "txt" -> "text/plain"
                else -> throw IllegalArgumentException("Unsupported export type.")
            }
        val rootDocument =
            DocumentsContract.buildDocumentUriUsingTree(
                directory,
                DocumentsContract.getTreeDocumentId(directory),
            )
        val target =
            findChild(directory, source.name)
                ?: DocumentsContract.createDocument(
                    contentResolver,
                    rootDocument,
                    mimeType,
                    source.name,
                )
                ?: throw IllegalStateException("The document provider rejected the file.")
        source.inputStream().use { input ->
            contentResolver.openOutputStream(target, "wt")?.use { output ->
                input.copyTo(output)
                output.flush()
            } ?: throw IllegalStateException("The document provider is not writable.")
        }
    }

    private fun findChild(
        directory: Uri,
        displayName: String,
    ): Uri? {
        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(
                directory,
                DocumentsContract.getTreeDocumentId(directory),
            )
        val projection =
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
        contentResolver.query(children, projection, null, null, null)?.use { cursor ->
            val idColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
            val nameColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
            while (cursor.moveToNext()) {
                if (cursor.getString(nameColumn) == displayName) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        directory,
                        cursor.getString(idColumn),
                    )
                }
            }
        }
        return null
    }

    override fun onDestroy() {
        pendingDirectoryResult?.error(
            "activity_closed",
            "The folder picker was closed.",
            null,
        )
        pendingDirectoryResult = null
        storageExecutor.shutdown()
        WorkBenchLc3.dispose()
        super.onDestroy()
    }
}
