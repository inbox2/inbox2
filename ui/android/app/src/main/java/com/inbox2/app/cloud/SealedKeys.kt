package com.inbox2.app.cloud

import android.app.Activity
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** The sealed-mail identity key, encrypted under a Keystore key that needs a strong
 *  biometric for every use. Enrolling a new finger invalidates it. */
object SealedKeys {
    private const val ALIAS = "inbox2.sealed.identity"
    private const val PREFS = "sealed_identity"
    private const val TRANSFORM = "AES/GCM/NoPadding"

    // ponytail: platform prompt only, API 30+. Older phones type the password each time.
    fun available(context: Context): Boolean = Build.VERSION.SDK_INT >= 30 &&
        context.getSystemService(BiometricManager::class.java)
            ?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    fun hasKey(context: Context) = prefs(context).contains("ct")

    fun delete(context: Context) {
        prefs(context).edit().clear().apply()
        keystore().deleteEntry(ALIAS)
    }

    suspend fun save(activity: Activity, identity: String): Boolean {
        if (Build.VERSION.SDK_INT < 30) return false
        keystore().deleteEntry(ALIAS)
        val cipher = runCatching { Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, newKey()) } }.getOrNull() ?: return false
        val done = authenticate(activity, cipher) ?: return false
        val ct = done.doFinal(identity.toByteArray())
        prefs(activity).edit().putString("ct", b64(ct)).putString("iv", b64(done.iv)).apply()
        return true
    }

    suspend fun load(activity: Activity): String? {
        if (Build.VERSION.SDK_INT < 30 || !hasKey(activity)) return null
        val p = prefs(activity)
        val key = keystore().getKey(ALIAS, null) as? SecretKey ?: return null
        val cipher = try {
            Cipher.getInstance(TRANSFORM).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(p.getString("iv", ""), Base64.NO_WRAP)))
            }
        } catch (_: KeyPermanentlyInvalidatedException) {
            delete(activity); return null
        }
        val done = authenticate(activity, cipher) ?: return null
        return runCatching { String(done.doFinal(Base64.decode(p.getString("ct", ""), Base64.NO_WRAP))) }.getOrNull()
    }

    @androidx.annotation.RequiresApi(30)
    private suspend fun authenticate(activity: Activity, cipher: Cipher): Cipher? = suspendCancellableCoroutine { cont ->
        val cancel = CancellationSignal()
        cont.invokeOnCancellation { cancel.cancel() }
        val executor = activity.mainExecutor
        BiometricPrompt.Builder(activity)
            .setTitle("Unlock your key")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButton("Cancel", executor) { _, _ -> if (cont.isActive) cont.resume(null) }
            .build()
            .authenticate(BiometricPrompt.CryptoObject(cipher), cancel, executor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (cont.isActive) cont.resume(result.cryptoObject?.cipher)
                }
                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    if (cont.isActive) cont.resume(null)
                }
            })
    }

    @androidx.annotation.RequiresApi(30)
    private fun newKey(): SecretKey = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
        init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .build())
        generateKey()
    }

    private fun keystore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
}
