# frozen_string_literal: true

module Lla::AsyncDispatcher
  def listeners
    (super + [CaptainListener.instance]).uniq
  end
end
