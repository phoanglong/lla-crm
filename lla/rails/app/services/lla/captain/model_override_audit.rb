# frozen_string_literal: true

class Lla::Captain::ModelOverrideAudit
  COMMENT = 'lla_captain_model_routes'

  def initialize(account:, previous_models:, actor:, request:)
    @account = account
    @previous_models = (previous_models || {}).stringify_keys
    @current_models = (account.captain_models || {}).stringify_keys
    @actor = actor
    @request = request
  end

  def record!
    return if changed_features.empty?

    Audited.audit_class.create!(
      auditable: account,
      associated: account,
      user: actor,
      username: actor&.email,
      action: 'update',
      comment: COMMENT,
      audited_changes: { 'captain_model_routes' => [routes(previous_models), routes(current_models)] },
      remote_address: request.remote_ip,
      request_uuid: request.uuid
    )
  end

  private

  attr_reader :account, :previous_models, :current_models, :actor, :request

  def changed_features
    @changed_features ||= (previous_models.keys | current_models.keys).reject do |feature_key|
      previous_models[feature_key] == current_models[feature_key]
    end.sort
  end

  def routes(models)
    account_view = account.dup
    account_view.settings = account.settings.deep_dup.merge('captain_models' => models.presence)

    changed_features.index_with do |feature_key|
      Llm::FeatureRouter.resolve(feature: feature_key, account: account_view).slice(:provider, :model, :source)
    end
  end
end
