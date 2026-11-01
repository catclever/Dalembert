FROM ruby:3.3-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . .

# Ensure llm.yml exists from example if not mounted or present
RUN if [ ! -f llm.yml ] && [ -f llm.example.yml ]; then cp llm.example.yml llm.yml; fi

RUN bundle install

EXPOSE 8089

HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD curl -f http://localhost:8089/healthz || exit 1

CMD ["bundle", "exec", "bin/dalembert-server"]
