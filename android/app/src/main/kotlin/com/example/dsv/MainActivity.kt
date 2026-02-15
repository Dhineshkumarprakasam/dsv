package com.example.dsv

import android.content.pm.PackageManager
import android.content.pm.PackageInfo
import android.net.Uri
import android.os.Build
import android.view.WindowManager
import android.database.Cursor
import android.provider.OpenableColumns
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

class MainActivity: FlutterActivity() {

    private val CHANNEL = "signature.channel"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSignature" -> {
                        val signature = getAppSignature()
                        if (signature != null) {
                            result.success(signature)
                        } else {
                            result.error("UNAVAILABLE", "Could not get app signature", null)
                        }
                    }
                    "getPathFromUri" -> {
                        try {
                            val uriString = call.argument<String>("uri")
                            if (uriString == null) {
                                result.error("INVALID_ARGUMENT", "URI is null", null)
                                return@setMethodCallHandler
                            }
                            
                            val uri = Uri.parse(uriString)
                            val filePath = copyUriToCache(uri)
                            result.success(filePath)
                        } catch (e: Exception) {
                            result.error("FILE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getAppSignature(): String? {
        return try {
            // 1. Handle different Android versions for PackageInfo
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageManager.getPackageInfo(
                    packageName, 
                    PackageManager.GET_SIGNING_CERTIFICATES
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(
                    packageName, 
                    PackageManager.GET_SIGNATURES
                )
            }

            // 2. Safely get the signature array
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                packageInfo.signatures
            }

            // 3. Process the first signature into a HEX string
            if (signatures != null && signatures.isNotEmpty()) {
                val cert = signatures[0].toByteArray()
                val md = MessageDigest.getInstance("SHA-256")
                val digest = md.digest(cert)
                
                // Returns HEX string: matches Python's hashlib.sha256().hexdigest()
                return digest.joinToString("") { "%02x".format(it) }
            }
            null
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun copyUriToCache(uri: Uri): String {
        val inputStream = contentResolver.openInputStream(uri)
            ?: throw Exception("Cannot open input stream for URI: $uri")

        // Get original filename if possible
        var fileName = "shared_file_${System.currentTimeMillis()}"
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex != -1 && cursor.moveToFirst()) {
                fileName = cursor.getString(nameIndex) ?: fileName
            }
        }

        val cacheFile = File(cacheDir, fileName)
        
        inputStream.use { input ->
            FileOutputStream(cacheFile).use { output ->
                input.copyTo(output)
            }
        }
        
        return cacheFile.absolutePath
    }
}