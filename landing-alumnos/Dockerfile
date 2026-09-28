FROM nginxinc/nginx-unprivileged:1-alpine

COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
COPY privacy.html /usr/share/nginx/html/privacy.html
COPY student-terms.html /usr/share/nginx/html/student-terms.html
COPY teacher-privacy.html /usr/share/nginx/html/teacher-privacy.html
COPY teacher-terms.html /usr/share/nginx/html/teacher-terms.html
COPY styles.css /usr/share/nginx/html/styles.css
COPY assets /usr/share/nginx/html/assets

USER 101:101
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8080/health/ready || exit 1
