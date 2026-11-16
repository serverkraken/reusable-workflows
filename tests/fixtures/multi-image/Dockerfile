FROM alpine:3.24
RUN echo "api" > /role
# Non-root at runtime (Trivy DS-0002).
USER 65532:65532
ENTRYPOINT ["cat", "/role"]
