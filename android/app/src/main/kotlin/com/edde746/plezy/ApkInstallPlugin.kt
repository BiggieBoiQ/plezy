package com.edde746.plezy

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands a downloaded APK to the system package installer.
 *
 * This is the fork's self-update path. Android has no Sparkle equivalent, and a
 * silent install needs device-owner privileges the app will never hold, so the
 * most that is possible is to skip the browser: the app downloads the APK
 * itself and the installer opens straight onto the confirmation screen.
 */
class ApkInstallPlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler {

  companion object {
    private const val TAG = "ApkInstallPlugin"
    private const val METHOD_CHANNEL = "com.plezy/apk_install"
    private const val APK_MIME = "application/vnd.android.package-archive"
  }

  private var channel: MethodChannel? = null
  private var context: Context? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val ctx = context
    if (ctx == null) {
      result.error("no_context", "Plugin is detached from the engine", null)
      return
    }

    when (call.method) {
      // Below O the install permission is granted at install time, so there is
      // nothing to ask for and nothing that can be revoked.
      "canRequestInstalls" -> result.success(
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || ctx.packageManager.canRequestPackageInstalls()
      )

      "openInstallPermissionSettings" -> result.success(openInstallPermissionSettings(ctx))

      "installApk" -> {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
          result.error("bad_args", "installApk requires a path", null)
          return
        }
        installApk(ctx, path, result)
      }

      else -> result.notImplemented()
    }
  }

  private fun openInstallPermissionSettings(ctx: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    return try {
      val intent = Intent(
        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${ctx.packageName}"),
      ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      ctx.startActivity(intent)
      true
    } catch (error: Exception) {
      // Android TV builds routinely omit this settings screen; the caller falls
      // back to telling the viewer where to look rather than failing the update.
      Log.w(TAG, "No unknown-app-sources settings screen on this device", error)
      false
    }
  }

  private fun installApk(ctx: Context, path: String, result: MethodChannel.Result) {
    val apk = File(path)
    if (!apk.isFile) {
      result.error("missing_file", "No APK at $path", null)
      return
    }

    try {
      // The authority is declared in AndroidManifest.xml and already covers the
      // cache and files directories the downloader writes to.
      val uri: Uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", apk)
      val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, APK_MIME)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      ctx.startActivity(intent)
      result.success(true)
    } catch (error: Exception) {
      Log.e(TAG, "Failed to launch the package installer", error)
      result.error("install_failed", error.message, null)
    }
  }
}
