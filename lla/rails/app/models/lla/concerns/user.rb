# frozen_string_literal: true

module Lla::Concerns::User
  extend ActiveSupport::Concern

  included do
    has_many :copilot_threads, dependent: :destroy_async
    # Captain responses authored from a user's own material. Polymorphic, so
    # without the association the rows survive the user and point at nothing.
    has_many :captain_responses,
             class_name: 'Captain::AssistantResponse',
             as: :documentable,
             dependent: :destroy_async
  end
end
