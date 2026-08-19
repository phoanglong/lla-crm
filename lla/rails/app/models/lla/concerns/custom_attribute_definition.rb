# frozen_string_literal: true

# Deleting a custom attribute has to take it out of the required list too.
#
# `conversation_required_attributes` holds attribute keys. Deleting the attribute
# they name left the key behind, so every conversation in the account then required
# an attribute that no longer existed and could not be supplied — a state an
# operator could reach with one click and not undo from the interface.
module Lla::Concerns::CustomAttributeDefinition
  extend ActiveSupport::Concern

  included do
    after_destroy :cleanup_conversation_required_attributes
  end

  private

  def cleanup_conversation_required_attributes
    return unless conversation_attribute?

    required = account.conversation_required_attributes
    return if required.blank?
    return unless required.include?(attribute_key)

    account.conversation_required_attributes = required - [attribute_key]
    account.save!
  end
end
