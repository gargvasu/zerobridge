#!/bin/bash
# Generate a local CA + TLS certificate for zerobridge.local
# Run on the Pi: sudo bash scripts/gen-certs.sh
set -e

OUT="/etc/zerobridge/tls"
mkdir -p "$OUT"

HOSTNAME="zerobridge.local"
WIFI_IP="${WIFI_IP:-$(hostname -I | awk '{print $1}')}"  # override: WIFI_IP=x.x.x.x
DAYS=3650

echo "Generating CA key..."
openssl genrsa -out "$OUT/ca.key" 4096 2>/dev/null

echo "Generating CA certificate..."
openssl req -x509 -new -nodes \
  -key "$OUT/ca.key" \
  -sha256 -days "$DAYS" \
  -subj "/CN=ZeroBridge Local CA/O=ZeroBridge" \
  -out "$OUT/ca.crt"

echo "Generating server key..."
openssl genrsa -out "$OUT/server.key" 2048 2>/dev/null

echo "Generating server CSR..."
openssl req -new \
  -key "$OUT/server.key" \
  -subj "/CN=$HOSTNAME/O=ZeroBridge" \
  -out "$OUT/server.csr"

echo "Signing server certificate..."
cat > "$OUT/server.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $HOSTNAME
DNS.2 = *.zerobridge.local
DNS.3 = raspberrypizero.local
IP.1  = $WIFI_IP
IP.2  = 169.254.206.2
IP.3  = 169.254.96.179
IP.4  = 127.0.0.1
EOF

openssl x509 -req \
  -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" \
  -CAkey "$OUT/ca.key" \
  -CAcreateserial \
  -out "$OUT/server.crt" \
  -days "$DAYS" \
  -sha256 \
  -extfile "$OUT/server.ext"

# Restrict private keys
chmod 600 "$OUT/ca.key" "$OUT/server.key"
chmod 644 "$OUT/ca.crt" "$OUT/server.crt"

echo ""
echo "✅ Certificates generated in $OUT"
echo ""
echo "CA cert to install on iPhone:"
echo "  https://$IP:8443/ca.crt"
echo ""
echo "Or from your Mac:"
echo "  open http://$IP:8080/ca.crt   (if HTTP port is still up)"
echo ""
echo "Fingerprint (verify on iPhone after install):"
openssl x509 -in "$OUT/ca.crt" -fingerprint -sha256 -noout | sed 's/SHA256 Fingerprint=//'
