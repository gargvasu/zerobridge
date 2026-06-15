use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Key, Nonce,
};
use base64::prelude::*;
use hkdf::Hkdf;
use p256::{ecdh::EphemeralSecret, elliptic_curve::sec1::ToEncodedPoint, PublicKey};
use rand::RngCore;
use sha2::Sha256;

pub struct E2ESession {
    cipher: Aes256Gcm,
}

impl E2ESession {
    /// Generate an ephemeral P-256 key pair.
    /// Returns (secret, uncompressed-pubkey-base64url).
    pub fn generate() -> (EphemeralSecret, String) {
        let secret = EphemeralSecret::random(&mut rand::rngs::OsRng);
        let pubkey = secret.public_key();
        let encoded = pubkey.to_encoded_point(false); // uncompressed: 04 || x || y, 65 bytes
        let b64 = BASE64_URL_SAFE_NO_PAD.encode(encoded.as_bytes());
        (secret, b64)
    }

    /// Complete ECDH with the peer's base64url-encoded uncompressed P-256 public key.
    /// Derives AES-256-GCM session key via HKDF-SHA256(ikm=shared_x, info="zerobridge-e2e").
    pub fn from_ecdh(secret: EphemeralSecret, peer_pubkey_b64: &str) -> Result<Self, String> {
        let peer_bytes = BASE64_URL_SAFE_NO_PAD
            .decode(peer_pubkey_b64)
            .map_err(|e| format!("base64 decode peer key: {e}"))?;

        let peer_pub = PublicKey::from_sec1_bytes(&peer_bytes)
            .map_err(|e| format!("invalid P-256 pubkey: {e}"))?;

        let shared = secret.diffie_hellman(&peer_pub);
        let ikm = shared.raw_secret_bytes(); // x-coordinate, 32 bytes

        let hk = Hkdf::<Sha256>::new(None, ikm.as_slice());
        let mut key_bytes = [0u8; 32];
        hk.expand(b"zerobridge-e2e", &mut key_bytes)
            .map_err(|e| format!("HKDF expand: {e}"))?;

        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key_bytes));
        Ok(E2ESession { cipher })
    }

    /// Encrypt plaintext → standard-base64(12-byte-iv || AES-GCM-ciphertext+tag).
    pub fn encrypt(&self, plaintext: &str) -> Result<String, String> {
        let mut iv_bytes = [0u8; 12];
        rand::rngs::OsRng.fill_bytes(&mut iv_bytes);
        let nonce = Nonce::from_slice(&iv_bytes);

        let ciphertext = self
            .cipher
            .encrypt(nonce, plaintext.as_bytes())
            .map_err(|e| format!("AES-GCM encrypt: {e}"))?;

        let mut payload = Vec::with_capacity(12 + ciphertext.len());
        payload.extend_from_slice(&iv_bytes);
        payload.extend_from_slice(&ciphertext);

        Ok(BASE64_STANDARD.encode(&payload))
    }

    /// Decrypt standard-base64(iv || ciphertext+tag) → plaintext string.
    pub fn decrypt(&self, enc_b64: &str) -> Result<String, String> {
        let payload = BASE64_STANDARD
            .decode(enc_b64)
            .map_err(|e| format!("base64 decode payload: {e}"))?;

        if payload.len() < 12 {
            return Err("payload too short for IV".into());
        }
        let (iv_bytes, ciphertext) = payload.split_at(12);
        let nonce = Nonce::from_slice(iv_bytes);

        let plaintext = self
            .cipher
            .decrypt(nonce, ciphertext)
            .map_err(|e| format!("AES-GCM decrypt: {e}"))?;

        String::from_utf8(plaintext).map_err(|e| format!("UTF-8 decode: {e}"))
    }
}
