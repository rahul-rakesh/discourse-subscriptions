# frozen_string_literal: true

module ::Jobs
  class CheckExpiredSubscriptions < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.discourse_subscriptions_enabled
      return unless SiteSetting.discourse_subscriptions_secret_key.present?

      # Set the Stripe API key for the job
      ::Stripe.api_key = SiteSetting.discourse_subscriptions_secret_key

      expired_subscriptions = ::DiscourseSubscriptions::Subscription
                                .where(status: 'active')
                                .where.not(expires_at: nil)
                                .where("expires_at < ?", Time.zone.now)

      return if expired_subscriptions.empty?

      expired_subscriptions.each do |sub|
        begin
          user = sub.customer&.user

          if user && sub.plan_id
            begin
              plan = ::Stripe::Price.retrieve(sub.plan_id)
              group_name = plan[:metadata][:group_name]
              group = ::Group.find_by_name(group_name) if group_name.present?

              if group
                group.remove(user)
              end
            rescue ::Stripe::InvalidRequestError
              # If the plan was deleted in Stripe, we can't get group info,
              # but we should still expire the subscription.
            end
          end

          sub.update!(status: 'expired')

        rescue => e
          Rails.logger.error("Failed to process expired subscription #{sub.id}. Error: #{e.message}")
          next
        end
      end
    end
  end
end
