# frozen_string_literal: true

class CreateLlaVoiceRecordingConsents < ActiveRecord::Migration[7.1]
  def up
    return if table_exists?(:lla_voice_recording_consents)

    create_table :lla_voice_recording_consents do |t|
      t.bigint :account_id, null: false
      t.bigint :inbox_id, null: false
      t.bigint :call_id, null: false
      t.bigint :user_id
      t.string :capture_method, null: false, limit: 32
      t.string :disclosure_version, null: false, limit: 64
      t.string :attestation_digest, null: false, limit: 64
      t.string :evidence_digest, null: false, limit: 64
      t.string :actor_reference_digest, null: false, limit: 64
      t.datetime :client_attested_at, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end

    add_integrity
  end

  def down
    drop_table :lla_voice_recording_consents, if_exists: true
  end

  private

  def add_integrity
    add_indexes
    add_foreign_keys
    add_constraints
  end

  def add_indexes
    add_index :lla_voice_recording_consents, %i[account_id call_id],
              unique: true, name: 'idx_lla_recording_consents_call'
    add_index :lla_voice_recording_consents, %i[account_id attestation_digest],
              unique: true, name: 'idx_lla_recording_consents_attestation'
    add_index :lla_voice_recording_consents, %i[account_id captured_at], name: 'idx_lla_recording_consents_timeline'
  end

  def add_foreign_keys
    add_foreign_key :lla_voice_recording_consents, :accounts, on_delete: :cascade
    add_foreign_key :lla_voice_recording_consents, :inboxes,
                    column: %i[account_id inbox_id], primary_key: %i[account_id id],
                    name: 'fk_lla_recording_consents_inbox_tenant', on_delete: :cascade
    add_foreign_key :lla_voice_recording_consents, :calls,
                    column: %i[account_id call_id], primary_key: %i[account_id id],
                    name: 'fk_lla_recording_consents_call_tenant', on_delete: :cascade
    user_fk = { column: :user_id, name: 'fk_lla_recording_consents_user', on_delete: :nullify }
    add_foreign_key :lla_voice_recording_consents, :users, **user_fk
  end

  def add_constraints
    add_check_constraint :lla_voice_recording_consents,
                         "capture_method IN ('agent_attestation')",
                         name: 'chk_lla_recording_consents_method'
    add_check_constraint :lla_voice_recording_consents,
                         "disclosure_version ~ '^[A-Za-z0-9_.:-]{1,64}$'",
                         name: 'chk_lla_recording_consents_disclosure'
    add_check_constraint :lla_voice_recording_consents,
                         'char_length(attestation_digest) = 64 AND char_length(evidence_digest) = 64 ' \
                         'AND char_length(actor_reference_digest) = 64',
                         name: 'chk_lla_recording_consents_digests'
  end
end
