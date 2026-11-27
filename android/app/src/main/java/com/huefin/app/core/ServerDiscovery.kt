package com.huefin.app.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException

/** Finds Jellyfin servers on the home network (Jellyfin answers "who is JellyfinServer?" on UDP port 7359). */
object ServerDiscovery {
    data class Found(val id: String, val name: String, val address: String)

    suspend fun scan(waitMs: Int = 2000): List<Found> = withContext(Dispatchers.IO) {
        val found = linkedMapOf<String, Found>()
        runCatching {
            DatagramSocket().use { s ->
                s.broadcast = true
                s.soTimeout = 400
                val msg = "who is JellyfinServer?".toByteArray()
                s.send(DatagramPacket(msg, msg.size, InetAddress.getByName("255.255.255.255"), 7359))
                val end = System.currentTimeMillis() + waitMs
                val buf = ByteArray(4096)
                while (System.currentTimeMillis() < end) {
                    try {
                        val p = DatagramPacket(buf, buf.size)
                        s.receive(p)
                        val o = Json.parseToJsonElement(String(p.data, 0, p.length)).jsonObject
                        val id = o["Id"]?.jsonPrimitive?.content ?: continue
                        val address = o["Address"]?.jsonPrimitive?.content ?: continue
                        found[id] = Found(id, o["Name"]?.jsonPrimitive?.content ?: "Jellyfin", address)
                    } catch (_: SocketTimeoutException) {}
                }
            }
        }
        found.values.toList()
    }
}
