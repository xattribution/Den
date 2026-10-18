package family.den.den_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        /** The engine kept in [FlutterEngineCache] while the hub runs in it. */
        private const val ENGINE = "den"
        private const val NOTIFICATIONS_REQUEST = 47733
    }

    // While the hub runs, the engine (and the hub in it) outlives this window: closing Den from
    // the recent apps leaves the family online, and opening Den again picks the same engine up.
    override fun getCachedEngineId(): String? =
        if (FlutterEngineCache.getInstance().contains(ENGINE)) ENGINE else null

    override fun shouldDestroyEngineWithHost(): Boolean = !HubService.running

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val app = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "den/hub_service").setMethodCallHandler { call, result ->
            val text = call.argument<String>("text") ?: ""
            when (call.method) {
                "start" -> {
                    FlutterEngineCache.getInstance().put(ENGINE, flutterEngine)
                    askToNotify()
                    HubService.start(app, text)
                    result.success(null)
                }
                "update" -> {
                    HubService.update(app, text)
                    result.success(null)
                }
                "stop" -> {
                    HubService.stop(app)
                    // With a window open, the engine goes back to living and dying with it. With
                    // none (the hub was turned off from another device), it stays cached so the
                    // next window picks it up instead of starting a second engine on the same data.
                    if (!isDestroyed) FlutterEngineCache.getInstance().remove(ENGINE)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        val keep = HubService.running
        super.onDestroy()
        if (!keep) FlutterEngineCache.getInstance().remove(ENGINE)
    }

    /** Android 13 and later show the hub's notification only with permission to notify. */
    private fun askToNotify() {
        if (Build.VERSION.SDK_INT < 33 || isFinishing || isDestroyed) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (requestCode == NOTIFICATIONS_REQUEST && granted) HubService.showAgain(applicationContext)
    }
}
