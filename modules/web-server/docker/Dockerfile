# Deploy to:   dev / prod
# Apply:       docker build -t web-server:local .
# Module:      web-server
# Requires:    none
#
# Custom Nginx image for the web-server module — replaces runtime bind mounts
# with build-time COPY on top of the rootless nginx-unprivileged base.
# Parameters modified from baseline: none

FROM nginxinc/nginx-unprivileged:stable-alpine

COPY configs/nginx/nginx.conf /etc/nginx/nginx.conf
COPY configs/html/index.html /usr/share/nginx/html/index.html

EXPOSE 8080
