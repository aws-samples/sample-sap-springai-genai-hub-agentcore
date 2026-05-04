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

# Download AWS Distro for OpenTelemetry Java agent.
# Handles: AWS X-Ray trace propagation headers, HTTP client auto-instrumentation
# API calls and JVM metrics export to CloudWatch.
RUN curl -L -o /aws-opentelemetry-agent.jar \
    https://github.com/aws-observability/aws-otel-java-instrumentation/releases/latest/download/aws-opentelemetry-agent.jar

RUN chown appuser:appuser /app/app.jar

USER appuser
EXPOSE 8080

CMD ["java", \
     "-javaagent:/aws-opentelemetry-agent.jar", \
     "-Xmx512m", "-Xms256m", \
     "-Dserver.port=8080", \
     "-jar", "app.jar"]
