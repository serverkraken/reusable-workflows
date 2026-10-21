FROM golang:1.27-alpine AS builder
WORKDIR /src
COPY main.go .
RUN go build -o /out/app main.go

FROM alpine:3.20
COPY --from=builder /out/app /usr/local/bin/app
# Non-root at runtime (Trivy DS-0002).
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/app"]
