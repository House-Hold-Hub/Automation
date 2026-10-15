# Test fixture only; real Dockerfiles belong to the service repositories.
FROM busybox:1.37
ARG GREETING=hello
COPY hello.txt /hello.txt
RUN echo "$GREETING" > /greeting.txt
CMD ["cat", "/greeting.txt"]
