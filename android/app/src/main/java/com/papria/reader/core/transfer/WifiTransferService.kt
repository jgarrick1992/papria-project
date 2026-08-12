package com.papria.reader.core.transfer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.flow.StateFlow

/** Keeps the temporary Wi-Fi receiver alive while the transfer page is visible. */
class WifiTransferService : Service() {
    private var server: WifiTransferServer? = null
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    override fun onCreate() {
        super.onCreate()
        activeServer = null
        val channelId = "wifi-transfer"
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(channelId, "Wi-Fi transfer", NotificationManager.IMPORTANCE_LOW))
        startForeground(TRANSFER_NOTIFICATION_ID, NotificationCompat.Builder(this, channelId).setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("Papria Wi-Fi transfer").setContentText("Waiting for files").setOngoing(true).build())
        val candidate = WifiTransferServer(this, serviceLiveState)
        if (runCatching { candidate.start() }.isSuccess) {
            server = candidate
            activeServer = candidate
            currentUploadUrl = candidate.uploadUrl
            registerMdns(candidate.port)
        } else {
            candidate.close()
            stopSelf()
        }
    }

    override fun onDestroy() {
        registrationListener?.let { runCatching { nsdManager?.unregisterService(it) } }
        registrationListener = null
        nsdManager = null
        activeServer = null
        server?.close(); server = null; currentUploadUrl = null; currentMdnsName = null
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null

    private fun registerMdns(port: Int) {
        val manager = getSystemService(NsdManager::class.java) ?: return
        val info = NsdServiceInfo().apply {
            // Bearer material belongs only in the QR URL fragment, never in
            // a LAN-advertised service label.
            serviceName = "Papria-WiFi"
            serviceType = "_http._tcp"
            this.port = port
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) { currentMdnsName = "${serviceInfo.serviceName}.local" }
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { currentMdnsName = null }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) { currentMdnsName = null }
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { currentMdnsName = null }
        }
        nsdManager = manager
        registrationListener = listener
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    companion object {
        private const val TRANSFER_NOTIFICATION_ID = 1001
        private val serviceLiveState = WifiTransferLiveState()
        /**
         * Observable receiver-side upload state for the active foreground service.
         * Values are emitted only by [WifiTransferServer]; callers cannot mutate it.
         */
        val uploadSnapshot: StateFlow<WifiTransferServerSnapshot> = serviceLiveState.snapshot
        @Volatile private var activeServer: WifiTransferServer? = null

        /**
         * Requests cancellation of a live upload through the active local receiver.
         * This cannot bypass the receiver's safe-stage checks or alter the LAN protocol.
         */
        fun cancelUpload(uploadId: String): Boolean = activeServer?.cancelUpload(uploadId) == true
        @Volatile var currentUploadUrl: String? = null
        @Volatile var currentMdnsName: String? = null
    }
}
