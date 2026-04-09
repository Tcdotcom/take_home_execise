# ---------------------------------------------------------------------------
# Stage 1 — Build
# Uses the official Go Alpine image to keep the build layer small.
# CGO is disabled so the binary is fully static and can run on distroless.
# ---------------------------------------------------------------------------
FROM golang:1.22-alpine AS builder

# Install ca-certificates so the runtime image can make TLS calls,
# and tzdata for timezone-aware logging if needed.
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /build

# Copy dependency manifests first to leverage Docker layer caching.
COPY go.mod ./
# COPY go.sum ./ # Uncomment once external dependencies exist.
RUN go mod download

# Copy the rest of the source and build a static binary.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -trimpath -o /app main.go

# ---------------------------------------------------------------------------
# Stage 2 — Runtime
# Uses Google's distroless static image which contains:
#   - No shell, no package manager, no libc — minimal attack surface
#   - The "nonroot" tag runs as UID 65532 by default
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

# Copy timezone data and CA certificates from the builder.
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the compiled binary.
COPY --from=builder /app /app

# Expose the default application port.
EXPOSE 8080

# Run as the built-in nonroot user (UID 65532).
USER nonroot:nonroot

ENTRYPOINT ["/app"]
