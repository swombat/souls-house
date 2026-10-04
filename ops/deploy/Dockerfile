FROM ruby:4.0.6-slim-trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git openssh-client docker-cli docker-buildx build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && gem install kamal -v 2.12.0 --no-document \
    && docker --version && docker buildx version && kamal version
WORKDIR /work
ENTRYPOINT ["ruby", "-r", "/work/config/house.rb", "-e", "House.load_env!; load Gem.bin_path('kamal', 'kamal')", "--"]
