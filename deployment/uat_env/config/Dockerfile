FROM gliderlabs/alpine:3.4

COPY log/logback.xml /config/log/logback.xml
COPY scalyr/agent.json /config/scalyr/agent.json
COPY cert/root.crt /config/cert/root.crt

CMD /bin/true

