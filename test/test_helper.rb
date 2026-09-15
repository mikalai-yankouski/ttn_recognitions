# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "json"
require "minitest/autorun"
require "rack/test"

ENV["RACK_ENV"] ||= "test"
