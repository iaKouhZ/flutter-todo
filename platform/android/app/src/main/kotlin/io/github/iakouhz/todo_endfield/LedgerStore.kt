package io.github.iakouhz.todo_endfield

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class ConnectionSettings(val revision: Long, val url: String?, val password: String?)
internal data class WidgetRow(val title: String, val deadline: String)
internal data class WidgetSnapshot(val state: String, val rows: List<WidgetRow>)

internal class LedgerStore(context: Context) {
    private val prefs = context.getSharedPreferences("ledger_settings", Context.MODE_PRIVATE)

    fun readForApp(): Map<String, String> {
        val settings = connection()
        return buildMap {
            settings.url?.let { put("url", it) }
            settings.password?.let { put("password", it) }
        }
    }

    fun connection(): ConnectionSettings = synchronized(lock) {
        ConnectionSettings(
            prefs.getLong("revision", 0),
            prefs.getString("url", null),
            prefs.getString("password", null)?.let(::decrypt),
        )
    }

    fun hasServer(): Boolean = prefs.contains("url")

    fun setServer(url: String) = synchronized(lock) {
        if (url != prefs.getString("url", null)) {
            check(prefs.edit().putString("url", url).remove("password").remove("rows")
                .remove("state").putLong("revision", prefs.getLong("revision", 0) + 1).commit())
        }
    }

    fun setPassword(password: String?) = synchronized(lock) {
        val editor = prefs.edit().remove("rows").remove("state")
            .putLong("revision", prefs.getLong("revision", 0) + 1)
        if (password == null) editor.remove("password")
        else editor.putString("password", encrypt(password))
        check(editor.commit())
    }

    fun snapshot(): WidgetSnapshot = synchronized(lock) {
        val rows = JSONArray(prefs.getString("rows", "[]"))
        WidgetSnapshot(
            prefs.getString("state", "loading") ?: "loading",
            List(rows.length()) { index ->
                val row = rows.optJSONObject(index)
                if (row != null) {
                    WidgetRow(row.optString("title"), row.optString("deadline"))
                } else {
                    // Older builds stored each row as a date-first string.
                    val old = rows.optString(index).split("  ·  ", limit = 2)
                    if (old.size == 2) WidgetRow(old[1], old[0]) else WidgetRow(old[0], "")
                }
            },
        )
    }

    fun publish(revision: Long, state: String, rows: List<WidgetRow>? = null) = synchronized(lock) {
        if (revision == prefs.getLong("revision", 0)) {
            val editor = prefs.edit().putString("state", state)
            if (rows != null) {
                val encoded = JSONArray()
                for (row in rows) {
                    encoded.put(JSONObject().put("title", row.title).put("deadline", row.deadline))
                }
                editor.putString("rows", encoded.toString())
            }
            editor.apply()
        }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
            generateKey()
        }
    }

    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(text: String) = Base64.decode(text, Base64.NO_WRAP)

    private fun encrypt(password: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        return encode(cipher.iv) + ":" + encode(cipher.doFinal(password.toByteArray(Charsets.UTF_8)))
    }

    private fun decrypt(value: String): String {
        val (iv, ciphertext) = value.split(':', limit = 2)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, decode(iv)))
            String(doFinal(decode(ciphertext)), Charsets.UTF_8)
        }
    }

    private companion object {
        const val alias = "todo-endfield-password"
        val lock = Any()
    }
}
