# frozen_string_literal: true

class AddLlaOnboardingIdentityToPortals < ActiveRecord::Migration[7.1]
  def up
    add_column :portals, :lla_onboarding_key_digest, :string, limit: 64 unless column_exists?(:portals, :lla_onboarding_key_digest)
    add_index :portals, %i[account_id lla_onboarding_key_digest],
              unique: true,
              where: 'lla_onboarding_key_digest IS NOT NULL',
              name: 'idx_lla_portals_onboarding_identity',
              if_not_exists: true
    add_check_constraint :portals,
                         'lla_onboarding_key_digest IS NULL OR char_length(lla_onboarding_key_digest) = 64',
                         name: 'chk_lla_portals_onboarding_digest',
                         if_not_exists: true
  end

  def down
    remove_check_constraint :portals, name: 'chk_lla_portals_onboarding_digest', if_exists: true
    remove_index :portals, name: 'idx_lla_portals_onboarding_identity', if_exists: true
    remove_column :portals, :lla_onboarding_key_digest if column_exists?(:portals, :lla_onboarding_key_digest)
  end
end
