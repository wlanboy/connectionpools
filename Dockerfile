FROM registry.access.redhat.com/ubi10/openjdk-25:latest AS build
USER root
WORKDIR /build
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -q -Dmaven.test.skip=true package

FROM registry.access.redhat.com/ubi10/openjdk-25-runtime:latest
WORKDIR /app
COPY --from=build --chown=185:185 /build/target/pool-*.jar app.jar
USER 185
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=70", "-jar", "/app/app.jar"]
