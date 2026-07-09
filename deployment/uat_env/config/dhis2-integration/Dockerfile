# Builds the dhis2-integration image with the Let's Encrypt root "ISRG Root X1"
# added to the JVM truststore, so the image's JDK (1.8.0_92) can validate
# the https://xchange.health.gov.mw/adx certificate chain.

FROM eclipse-temurin:8-jre AS certbuilder
COPY --from=openlmismw/dhis2-integration:1.0.4 \
     /opt/jdk1.8.0_92/jre/lib/security/cacerts /work/cacerts
COPY isrgrootx1.pem /tmp/isrgrootx1.pem
RUN chmod u+w /work/cacerts \
 && keytool -importcert -noprompt -alias isrgrootx1 \
      -file /tmp/isrgrootx1.pem -keystore /work/cacerts -storepass changeit \
 && keytool -list -keystore /work/cacerts -storepass changeit -alias isrgrootx1

FROM openlmismw/dhis2-integration:1.0.4
COPY --from=certbuilder /work/cacerts /opt/jdk1.8.0_92/jre/lib/security/cacerts
