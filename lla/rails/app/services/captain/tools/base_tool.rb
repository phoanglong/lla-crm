# frozen_string_literal: true

class Captain::Tools::BaseTool < RubyLLM::Tool
  prepend Captain::Tools::Instrumentation
  include Captain::Tools::PermissionHelpers

  attr_reader :assistant, :user

  def initialize(assistant, user: nil)
    @assistant = assistant
    @user = user
    super()
  end

  def active?
    true
  end
end
