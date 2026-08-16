# frozen_string_literal: true

class Api::V1::Accounts::Captain::ScenariosController < Api::V1::Accounts::Captain::BaseController
  before_action :set_assistant
  before_action :set_scenario, only: [:show, :update, :destroy]
  before_action :authorize_scenario

  def index
    @scenarios = assistant_scenarios.enabled.order(:id)
  end

  def show; end

  def create
    @scenario = assistant_scenarios.create!(scenario_params.merge(account: Current.account))
  end

  def update
    @scenario.update!(scenario_params)
  end

  def destroy
    @scenario.destroy!
    head :no_content
  end

  private

  def set_assistant
    @assistant = Current.account.captain_assistants.find(params[:assistant_id])
  end

  def set_scenario
    @scenario = assistant_scenarios.find(params[:id])
  end

  def authorize_scenario
    authorize(@scenario || Captain::Scenario)
  end

  def assistant_scenarios
    @assistant.scenarios
  end

  def scenario_params
    params.require(:scenario).permit(:title, :description, :instruction, :enabled, tools: [])
  end
end
