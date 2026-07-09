# Builds the dhis2-integration image with the Let's Encrypt root "ISRG Root X1"
# added to the JVM truststore, so the image's JDK (1.8.0_92) can validate
# the https://xchange.health.gov.mw/adx certificate chain.

FROM openlmismw/dhis2-integration:1.0.4
COPY isrgrootx1.pem /tmp/isrgrootx1.pem
RUN chmod u+w /opt/jdk1.8.0_92/jre/lib/security/cacerts \
 && /opt/jdk1.8.0_92/bin/keytool -importcert -noprompt -alias isrgrootx1 \
      -file /tmp/isrgrootx1.pem \
      -keystore /opt/jdk1.8.0_92/jre/lib/security/cacerts -storepass changeit \
 && /opt/jdk1.8.0_92/bin/keytool -list \
      -keystore /opt/jdk1.8.0_92/jre/lib/security/cacerts -storepass changeit \
      -alias isrgrootx1
