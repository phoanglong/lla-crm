# frozen_string_literal: true

module Onboarding::HelpCenterErrors
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  class CurationSkipped < Error; end
  class ArticleBuildFailed < Error; end
end
