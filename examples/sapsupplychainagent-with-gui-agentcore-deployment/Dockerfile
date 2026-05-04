FROM public.ecr.aws/docker/library/maven:3-amazoncorretto-25-al2023 AS builder

WORKDIR /build
COPY pom.xml .
COPY src ./src

RUN rm -rf src/main/resources/static
RUN mvn clean package -DskipTests -ntp

FROM public.ecr.aws/docker/library/amazoncorretto:25-al2023-headless

RUN yum install -y shadow-utils python3.11 python3.11-pip && \
    groupadd --system appuser && \
    adduser --system --gid appuser --create-home appuser

WORKDIR /app
COPY --from=builder /build/target/*.jar app.jar

RUN chown appuser:appuser /app/app.jar

USER appuser
EXPOSE 8080

ENTRYPOINT ["java", "-Xmx512m", "-Xms256m", "-Dserver.port=8080", "-jar", "app.jar"]
