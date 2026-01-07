FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o demo-backend main.go

FROM scratch
COPY --from=builder /app/demo-backend /demo-backend
USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["/demo-backend"]
