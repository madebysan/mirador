package com.san.androidsender;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.math.BigInteger;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.PrivateKey;
import java.security.Principal;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.net.Socket;
import java.util.Date;
import javax.net.ssl.KeyManager;
import javax.net.ssl.X509KeyManager;
import javax.net.ssl.SSLContext;
import javax.security.auth.x500.X500Principal;

final class Pairing {
    private static final String ALIAS = "android-sender-tls-ec-v2";
    final SharedPreferences prefs;
    final String token;
    final String fingerprint;
    final SSLContext tls;

    Pairing(Context context) throws Exception {
        prefs = context.getSharedPreferences("sender", Context.MODE_PRIVATE);
        String stored = prefs.getString("token", null);
        if (stored == null) {
            byte[] secret = new byte[32];
            new SecureRandom().nextBytes(secret);
            stored = Base64.encodeToString(secret, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            prefs.edit().putString("token", stored).commit();
        }
        token = stored;
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        if (!keys.containsAlias(ALIAS)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(ALIAS,
                    KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                    // Conscrypt hashes TLS signatures itself and then asks the key store to sign that digest.
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setCertificateSubject(new X500Principal("CN=Android Sender"))
                    .setCertificateSerialNumber(new BigInteger(128, new SecureRandom()).abs().add(BigInteger.ONE))
                    .setCertificateNotBefore(new Date(System.currentTimeMillis() - 86400000L))
                    .setCertificateNotAfter(new Date(System.currentTimeMillis() + 10L * 365 * 86400000))
                    .build());
            generator.generateKeyPair();
        }
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(keys.getCertificate(ALIAS).getEncoded());
        StringBuilder pin = new StringBuilder();
        for (byte value : digest) pin.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        fingerprint = pin.toString();
        prefs.edit().putString("fingerprint", fingerprint).apply();
        PrivateKey privateKey = (PrivateKey) keys.getKey(ALIAS, null);
        X509Certificate certificate = (X509Certificate) keys.getCertificate(ALIAS);
        X509KeyManager manager = new X509KeyManager() {
            public String[] getServerAliases(String type, Principal[] issuers) { return "EC".equals(type) ? new String[]{ALIAS} : null; }
            public String chooseServerAlias(String type, Principal[] issuers, Socket socket) { return "EC".equals(type) ? ALIAS : null; }
            public X509Certificate[] getCertificateChain(String alias) { return ALIAS.equals(alias) ? new X509Certificate[]{certificate} : null; }
            public PrivateKey getPrivateKey(String alias) { return ALIAS.equals(alias) ? privateKey : null; }
            public String[] getClientAliases(String type, Principal[] issuers) { return null; }
            public String chooseClientAlias(String[] types, Principal[] issuers, Socket socket) { return null; }
        };
        tls = SSLContext.getInstance("TLS");
        tls.init(new KeyManager[]{manager}, null, new SecureRandom());
    }
}
