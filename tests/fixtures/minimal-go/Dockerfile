FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY main.go .
RUN go build -o /out/app main.go

FROM alpine:3.20
COPY --from=builder /out/app /usr/local/bin/app
ENTRYPOINT ["/usr/local/bin/app"]
