#!/bin/bash
# Создаёт локальный сертификат подписи «RubaiSTT Local Signing» в связке ключей login.
# Зачем: с ad-hoc подписью macOS сбрасывает разрешение Accessibility после каждой сборки,
# с одним постоянным сертификатом — помнит. Доверие системы сертификату не нужно (проверено:
# codesign подписывает и без него). Запускать один раз на новом Mac; повторный запуск ничего не делает.
set -e
ID="RubaiSTT Local Signing"
if security find-certificate -c "$ID" >/dev/null 2>&1; then
    echo "Сертификат «$ID» уже есть"; exit 0
fi
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$ID
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/k.pem" -out "$T/c.pem" -config "$T/cfg" 2>/dev/null
# Старые алгоритмы .p12 обязательны: PKCS12 от OpenSSL 3 по умолчанию macOS не принимает (так же понимает LibreSSL)
openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:rubai \
    -name "$ID" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
security import "$T/c.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P rubai -T /usr/bin/codesign
echo "Готово: «$ID». При первой подписи macOS может спросить пароль связки ключей — нажмите «Разрешать всегда»."
