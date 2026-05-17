# Intentionally OLD base image with known HIGH/CRITICAL CVEs.
# Renovate ignores tests/fixtures/** (see .github/renovate.json5),
# so this version pin stays put.
#
# Why node:10-alpine specifically: alpine:3.x base images by 2026 have most
# HIGH/CRITICAL CVEs backfilled upstream — even with --ignore-unfixed=false,
# trivy detects 0 findings. node:10 EOL'd in 2021 and ships an old npm + many
# Node-ecosystem CVEs that persist indefinitely, making the failure-path test
# stable over time.
FROM node:10-alpine
USER nobody
CMD ["true"]
