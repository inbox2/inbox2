# syntax=docker/dockerfile:1
# Build the Inbox2 mail binaries as one small static image: the MX inbound
# receiver (cmd/mx, the entrypoint) and the outbound sender (cmd/smtp — the
# smtp deployment runs the same image with command ["/smtp"]).
# Pure Go (no cgo), so a distroless static base is enough.

FROM golang:1.26-alpine AS build
WORKDIR /src

# Cache deps first.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/mx ./cmd/smtp

# distroless has no package manager or shell, so there's no in-image OS
# upgrade step to run here (unlike api/Dockerfile). Freshness instead comes
# from `docker buildx build --pull` in CI re-pulling the latest
# distroless/static-debian12 digest every build, plus the Trivy scan job
# catching anything that slips through.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/mx /mx
COPY --from=build /out/smtp /smtp

# SMTP. The container binds an unprivileged port (MX_LISTEN=:2525); the node
# maps :25 → :2525 via hostPort, so no privileged bind is needed in-container.
EXPOSE 2525

USER nonroot
ENTRYPOINT ["/mx"]
