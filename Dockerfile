FROM ruby:3.3-slim

WORKDIR /app

ENV BIND_ADDRESS=0.0.0.0
ENV PORT=4567

COPY . .

EXPOSE 4567

CMD ["ruby", "server.rb"]
