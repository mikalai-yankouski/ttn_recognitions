FROM ruby:3.4-bookworm

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    libvips42 imagemagick \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .

ENV PORT=9292 RACK_ENV=production
EXPOSE 9292
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
