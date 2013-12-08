#!/usr/bin/env bash

read -n 1 -p "Are you sure you want to generate new keys: [N] " i
case $i in
    y|Y) ;;
    *) echo; echo "Aborted"; exit 1;;
esac

rm server.*
openssl genrsa -des3 -out server.key.secure -passout pass:testkey 4096 && \
    openssl rsa -in server.key.secure -out server.key -passin pass:testkey && \
    rm server.key.secure && \
    openssl req -new -key server.key -out server.csr -batch -passin pass:testkey && \
    openssl x509 -req -days 365 -in server.csr -signkey server.key -out server.crt -passin pass:testkey && \
    openssl x509 -in server.crt -out server.crt.der -outform der && \
    chmod 0600 server.key
