# frozen_string_literal: true

module Travis
  def config
    ::JobBoard.config
  end

  module_function :config

  def logger
    ::JobBoard.logger
  end

  module_function :logger
end
