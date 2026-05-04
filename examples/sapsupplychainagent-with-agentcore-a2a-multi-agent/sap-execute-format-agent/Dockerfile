FROM public.ecr.aws/docker/library/amazoncorretto:25-al2023-headless

RUN yum install -y shadow-utils coreutils-single && \
    groupadd --system appuser && \
    adduser --system --gid appuser --create-home appuser

WORKDIR /app
# Use pre-built JAR from local Maven build (Step 2 of deploy.sh)
COPY sap-execute-format-agent/target/*.jar app.jar

# Pin ADOT agent version with checksum verification
RUN curl -L -o /aws-opentelemetry-agent.jar \
    https://github.com/aws-observability/aws-otel-java-instrumentation/releases/download/v2.26.1/aws-opentelemetry-agent.jar && \
    echo "461a635ccb7d042282bb23248dad92a1e1504fdb1bfb37e5cac14c8160bead47  /aws-opentelemetry-agent.jar" | sha256sum -c -

RUN chown appuser:appuser /app/app.jar

USER appuser
EXPOSE 9000

CMD ["java", \
     "-javaagent:/aws-opentelemetry-agent.jar", \
     "-Xmx512m", "-Xms256m", \
     "-Dserver.port=9000", \
     "-jar", "app.jar"]
