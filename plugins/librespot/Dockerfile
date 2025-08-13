FROM golang:1.20-alpine

RUN apk add --no-cache git build-base

RUN git clone https://github.com/devgianlu/go-librespot.git /go-librespot

WORKDIR /go-librespot

RUN go build -v ./cmd/daemon

CMD ["./daemon"]
