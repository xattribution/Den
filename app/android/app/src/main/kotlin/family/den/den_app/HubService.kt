package family.den.den_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps Den's process, and the family's hub running inside it, alive while the app is in the
 * background ("Keep the family online"): a foreground service with a notification that stays
 * while the hub does, a partial wake lock so the hub keeps answering with the screen off, and a
 * Wi-Fi lock where the system still honors one. It runs no code of its own; the hub lives in the
 * Flutter engine, which [MainActivity] keeps after its window closes while this service runs.
 */
class HubService : Service() {
    companion object {
        private const val CHANNEL = "hub"
        private const val NOTIFICATION_ID = 47733
        private const val EXTRA_TEXT = "text"
        private const val TITLE = "Den is keeping the family online"

        /** Whether the service is in the foreground now. */
        @Volatile
        var running = false
            private set

        /** The notification's second line. */
        @Volatile
        private var text = ""

        /** Starts the service, or updates its notification when it already runs. */
        fun start(context: Context, text: String) {
            this.text = text
            val intent = Intent(context, HubService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        /** Changes the notification's second line; posting it again needs no foreground start. */
        fun update(context: Context, text: String) {
            this.text = text
            if (!running) return
            context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(context, text))
        }

        /**
         * Posts the notification again: one posted before Den could notify (Android 13 and later
         * ask first) stays hidden until it is.
         */
        fun showAgain(context: Context) = update(context, text)

        fun stop(context: Context) {
            context.stopService(Intent(context, HubService::class.java))
        }

        private fun notification(context: Context, text: String): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26 && manager?.getNotificationChannel(CHANNEL) == null) {
                val channel = NotificationChannel(CHANNEL, "Keeping the family online", NotificationManager.IMPORTANCE_LOW)
                channel.description = "Shown while this device runs the family's hub."
                channel.setShowBadge(false)
                manager?.createNotificationChannel(channel)
            }
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
            builder
                .setSmallIcon(R.drawable.ic_stat_den)
                .setContentTitle(TITLE)
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
            if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            return builder.build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        try {
            val shown = notification(this, text)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, shown, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, shown)
            }
        } catch (e: RuntimeException) {
            // The system refused a foreground service (started from the background on a newer
            // Android, say). The hub keeps running while the app is open.
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        holdLocks()
        // A restarted service would have no hub in it, so don't ask to be restarted; Den starts
        // the hub, and this service, again when it next opens.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        super.onDestroy()
    }

    private fun holdLocks() {
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "den:hub")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wifiLock == null) {
            // Ignored from Android 14 on, where the system keeps Wi-Fi up for apps in the
            // foreground; older tablets, the usual hubs, still need it.
            @Suppress("DEPRECATION")
            wifiLock = applicationContext.getSystemService(WifiManager::class.java)
                ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "den:hub")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }
}
