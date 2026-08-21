# frozen_string_literal: true

class Captain::Tools::BaseService
  include Captain::Tools::PermissionHelpers

  attr_reader :assistant, :user

  def initialize(assistant, user: nil)
    @assistant = assistant
    @user = user
  end

  def name
    raise NotImplementedError, "#{self.class} must implement name"
  end

  def description
    raise NotImplementedError, "#{self.class} must implement description"
  end

  def parameters
    raise NotImplementedError, "#{self.class} must implement parameters"
  end

  def execute(arguments)
    raise NotImplementedError, "#{self.class} must implement execute"
  end

  def to_registry_format
    {
      type: 'function',
      function: { name: name, description: description, parameters: parameters }
    }
  end

  def active?
    true
  end
end
