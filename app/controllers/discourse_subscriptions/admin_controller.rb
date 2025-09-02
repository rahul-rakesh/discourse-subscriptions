# frozen_string_literal: true

module DiscourseSubscriptions
  class AdminController < ::Admin::AdminController
    requires_plugin DiscourseSubscriptions::PLUGIN_NAME

    def index
      head 200
    end
  end
end
