class RemoveCampaignFeatures < ActiveRecord::Migration[7.1]
  def up
    # Remove campaign-related site settings
    DB.exec("DELETE FROM site_settings WHERE name LIKE 'discourse_subscriptions_campaign%'")

    # Remove campaign-related Redis keys
    Discourse.redis.del("subscriptions_goal_met_date")

    # Remove any campaign-specific groups (optional)
    Group.where("name LIKE '%campaign%' OR name LIKE '%supporter%'").destroy_all
  end

  def down
    # Irreversible - campaign data will be lost
    raise ActiveRecord::IrreversibleMigration
  end
end
