# Thin runtime image: the jar is built on the host by `make build-api` (the Makefile
# enforces this before `docker compose build`), which keeps `make up` fast because the
# Maven cache is reused instead of re-downloaded inside the image on every change.
FROM eclipse-temurin:21-jre

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY target/observatory-api-*.jar /app/observatory-api.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/observatory-api.jar"]
