package online.dnsai.ivanvpn

import android.content.ClipData
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
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
            result.error("INSTALL_PERMISSION", "Allow APK installation from Yurich Connect", null)
            return
        }

        val apkFile = File(path)
        if (!apkFile.exists()) {
            result.error("APK_NOT_FOUND", "APK file not found", null)
            return
        }
        if (!apkFile.canRead() || apkFile.length() <= 0L) {
            result.error("APK_NOT_READABLE", "APK file is empty or not readable", null)
            return
        }

        try {
            val installFile = prepareInstallFile(apkFile)
            val uri = FileProvider.getUriForFile(this, "$packageName.cache", installFile)
            val installIntent = buildInstallIntent(Intent.ACTION_INSTALL_PACKAGE, uri)
            val viewIntent = buildInstallIntent(Intent.ACTION_VIEW, uri)
            val intent = when {
                findInstallers(installIntent).isNotEmpty() -> installIntent
                findInstallers(viewIntent).isNotEmpty() -> viewIntent
                else -> null
            }

            if (intent == null) {
                result.error("INSTALL_FAILED", "Android package installer was not found", null)
                return
            }

            val installers = findInstallers(intent)
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
        } catch (error: ActivityNotFoundException) {
            result.error("INSTALL_FAILED", "Android package installer was not found", null)
        } catch (error: Exception) {
            result.error("INSTALL_FAILED", "${error.javaClass.simpleName}: ${error.message}", null)
        }
    }

    private fun buildInstallIntent(action: String, uri: Uri): Intent =
        Intent(action).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            clipData = ClipData.newUri(contentResolver, "Yurich Connect update", uri)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            putExtra(Intent.EXTRA_RETURN_RESULT, true)
            putExtra(Intent.EXTRA_INSTALLER_PACKAGE_NAME, packageName)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

    private fun findInstallers(intent: Intent) =
        packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)

    private fun prepareInstallFile(source: File): File {
        val safeName = source.name
            .ifBlank { "YurichConnect-update.apk" }
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
                Uri.fromParts("package", packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
