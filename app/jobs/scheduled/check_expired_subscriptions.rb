# frozen_string_literal: true

module ::Jobs
  class CheckExpiredSubscriptions < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.discourse_subscriptions_enabled

      api_key = args[:api_key] || SiteSetting.discourse_subscriptions_secret_key
      return unless api_key.present?

      ::Stripe.api_key = api_key

      expired_subscriptions = ::DiscourseSubscriptions::Subscription
                                .where(status: 'active')
                                .where.not(expires_at: nil)
                                .where("expires_at < ?", Time.zone.now)

      return if expired_subscriptions.empty?

      expired_subscriptions.each do |sub|
        begin
          if (user = sub.customer&.user) && sub.plan_id
            begin
              plan = ::Stripe::Price.retrieve(sub.plan_id)
              if (group_name = plan[:metadata][:group_name]).present? && (group = ::Group.find_by_name(group_name))
                group.remove(user)
              end
            rescue ::Stripe::InvalidRequestError
              # Plan may have been deleted from Stripe; this is fine.
              # We still want to expire the local subscription.
            end
          end

          # Always mark the local subscription as expired.
          # Use update! to ensure any failure is logged by the rescue block.
          sub.update!(status: 'expired')

        rescue => e
          Rails.logger.error("Failed to process expired subscription #{sub.id}. Error: #{e.class} - #{e.message}")
          next
        end
      end
    end
  end
end
