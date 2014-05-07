#!/usr/bin/env bash

cert_dir=$(readlink -f $(dirname $0))
if [ ! -f $cert_dir/server.crt.der ]; then
    $cert_dir/generate_keys.sh
fi

sudo keytool -storepass changeit \
    -keystore $JAVA_HOME/jre/lib/security/cacerts \
    -delete \
    -alias postgresql

sudo keytool -storepass changeit \
    -keystore $JAVA_HOME/jre/lib/security/cacerts \
    -alias postgresql \
    -noprompt \
    -import -file $cert_dir/server.crt.der
