# frozen_string_literal: true

class AddProductIdToSubscriptionsTable < ActiveRecord::Migration[7.1]
  def change
    add_column :discourse_subscriptions_subscriptions, :product_id, :string
  end
end
