FROM alpine:3.20

RUN apk add --no-cache \
      bash curl jq ffmpeg \
      alsa-lib-dev openssl-dev dbus-dev pkgconf \
      build-base cargo rust

RUN cargo install songrec --locked --no-default-features -F ffmpeg

COPY tracks.sh /usr/local/bin/tracks.sh
RUN chmod +x /usr/local/bin/tracks.sh

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/tracks.sh"]
