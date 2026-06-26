FROM maven:3.9.11 AS builder
WORKDIR /opt/server
COPY pom.xml .
COPY src ./src
RUN mvn clean package && \
    mv target/shipping-*.jar shipping.jar


FROM eclipse-temurin:17-jre-alpine
EXPOSE 8080
RUN addgroup -S roboshop && adduser -S roboshop -G roboshop
WORKDIR /opt/server
ENV CART_ENDPOINT="cart:8080" \
    DB_HOST="mysql"
COPY --from=builder --chown=roboshop:roboshop /opt/server/shipping.jar .
USER roboshop
ENTRYPOINT ["sh", "-c", "sleep 30 && java -jar shipping.jar"]