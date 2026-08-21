# frozen_string_literal: true

# Account settings owned by LLA.
#
# `conversation_required_attributes` is a CRM capability with nothing to do with
# Chatwoot Cloud, but the only place it was permitted was an enterprise concern
# that also fired Google marketing attribution on every account creation. With
# enterprise off the setting could not be set at all; with enterprise on, creating
# an account read marketing cookies and posted attribution. The setting is kept and
# the attribution is gone.
module Lla::Api::V1::AccountsSettings
  private

  def permitted_settings_attributes
    super + [{ conversation_required_attributes: [] }]
  end
end
