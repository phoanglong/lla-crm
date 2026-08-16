# frozen_string_literal: true

module Lla::Concerns::User
  extend ActiveSupport::Concern

  included do
    has_many :copilot_threads, dependent: :destroy_async
  end
end
