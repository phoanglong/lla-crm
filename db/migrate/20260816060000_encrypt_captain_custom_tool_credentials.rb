# frozen_string_literal: true

class EncryptCaptainCustomToolCredentials < ActiveRecord::Migration[7.1]
  def up
    add_column :captain_custom_tools, :auth_config_ciphertext, :text unless column_exists?(:captain_custom_tools, :auth_config_ciphertext)
    return unless legacy_credentials_exist?

    raise 'Active Record encryption keys are required to migrate Captain custom-tool credentials' unless Chatwoot.encryption_configured?

    migration_model.reset_column_information
    migration_model.where.not(auth_config: {}).find_each do |tool|
      legacy_config = tool.read_attribute(:auth_config)
      tool.update_columns(auth_config_ciphertext: legacy_config.to_json, auth_config: {}) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    return unless column_exists?(:captain_custom_tools, :auth_config_ciphertext)

    migration_model.reset_column_information
    encrypted_tools = migration_model.where.not(auth_config_ciphertext: nil)
    if encrypted_tools.exists?
      raise 'Active Record encryption keys are required to roll back Captain custom-tool credentials' unless Chatwoot.encryption_configured?

      encrypted_tools.find_each do |tool|
        tool.update_columns(auth_config: JSON.parse(tool.auth_config_ciphertext), auth_config_ciphertext: nil) # rubocop:disable Rails/SkipsModelValidations
      end
    end
    remove_column :captain_custom_tools, :auth_config_ciphertext
  end

  private

  def legacy_credentials_exist?
    migration_model.reset_column_information
    migration_model.where.not(auth_config: {}).exists?
  end

  def migration_model
    @migration_model ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'captain_custom_tools'
      encrypts :auth_config_ciphertext if Chatwoot.encryption_configured?
    end
  end
end
