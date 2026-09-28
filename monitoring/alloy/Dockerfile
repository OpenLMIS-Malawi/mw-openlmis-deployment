ARG ALLOY_VERSION=v1.5.1
FROM grafana/alloy:${ALLOY_VERSION}
# Loaded as one config from the directory: the package's config.alloy
# (vendored, see PACKAGE_VERSION) plus the Malawi additions.
COPY config.alloy malawi.alloy /etc/alloy/
