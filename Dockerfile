FROM eclipse-temurin:21-jdk-alpine as builder

WORKDIR /app

COPY . .

RUN chmod +x mvnw && ./mvnw clean package -DskipTests -B 

#-----------------------

FROM eclipse-temurin:21-jre-alpine

WORKDIR /app

RUN addgroup -S bankapp && adduser -S -G bankapp bankapp
RUN chown bankapp:bankapp /app

COPY --from=builder /app/target/*.jar app.jar

EXPOSE 8080

CMD ["java", "-jar", "app.jar"]


