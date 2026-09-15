# frozen_string_literal: true

port ENV.fetch("PORT", "9292")
environment ENV.fetch("RACK_ENV", "development")
workers Integer(ENV.fetch("WEB_CONCURRENCY", "0"))
threads Integer(ENV.fetch("RAILS_MAX_THREADS", "1")), Integer(ENV.fetch("RAILS_MAX_THREADS", "1"))
