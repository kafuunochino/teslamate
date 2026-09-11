FROM golang:1.26-bookworm AS build
ARG FLEET_TELEMETRY_REVISION=8fbaa100bd365936dab6ecbf0e2d7070c4d765cb
RUN apt-get update && apt-get install -y --no-install-recommends libzmq3-dev libsodium-dev python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/teslamotors/fleet-telemetry.git . && git checkout --detach "$FLEET_TELEMETRY_REVISION"
COPY timestamp_mqtt.py /tmp/timestamp_mqtt.py
RUN python3 /tmp/timestamp_mqtt.py
ENV CGO_ENABLED=1 GOMAXPROCS=2 GOMEMLIMIT=768MiB CGO_LDFLAGS="-lstdc++"
RUN go test -p 1 ./datastore/mqtt && go build -p 1 -o /fleet-telemetry ./cmd/main.go

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libzmq5 libsodium23 curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /fleet-telemetry /fleet-telemetry
USER 1000:1000
ENTRYPOINT ["/fleet-telemetry"]
CMD ["-config", "/config/server.json"]
