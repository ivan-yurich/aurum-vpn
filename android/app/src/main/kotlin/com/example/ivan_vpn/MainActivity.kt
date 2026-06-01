package online.dnsai.ivanvpn

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "online.dnsai.ivanvpn/updater",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "installApk" -> installApk(call.argument<String>("path"), result)
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_PATH", "APK path is empty", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            openInstallSettings()
            result.error("INSTALL_PERMISSION", "Allow APK installation from Aurum VPN", null)
            return
        }

        val apkFile = File(path)
        if (!apkFile.exists()) {
            result.error("APK_NOT_FOUND", "APK file not found", null)
            return
        }

        try {
            val installFile = prepareInstallFile(apkFile)
            val uri = FileProvider.getUriForFile(this, "$packageName.cache", installFile)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME_TYPE)
                clipData = ClipData.newUri(contentResolver, "Aurum VPN update", uri)
                putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val installers = packageManager.queryIntentActivities(intent, 0)
            if (installers.isEmpty()) {
                result.error("INSTALL_FAILED", "Android package installer was not found", null)
                return
            }
            installers.forEach { resolveInfo ->
                grantUriPermission(
                    resolveInfo.activityInfo.packageName,
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }

            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("INSTALL_FAILED", error.message, null)
        }
    }

    private fun prepareInstallFile(source: File): File {
        val safeName = source.name
            .ifBlank { "AurumVPN-update.apk" }
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .let { if (it.endsWith(".apk", ignoreCase = true)) it else "$it.apk" }
        val updatesDir = File(cacheDir, "updates").apply { mkdirs() }
        val target = File(updatesDir, safeName)
        if (source.canonicalPath != target.canonicalPath) {
            source.copyTo(target, overwrite = true)
        }
        return target
    }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
