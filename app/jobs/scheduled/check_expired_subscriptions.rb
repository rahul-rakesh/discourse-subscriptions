# frozen_string_literal: true

module ::Jobs
  class CheckExpiredSubscriptions < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      Rails.logger.warn("[SUBS DEBUG] Running CheckExpiredSubscriptions job.")
      return unless SiteSetting.discourse_subscriptions_enabled

      expired_subscriptions = ::DiscourseSubscriptions::Subscription
                                .where(status: 'active')
                                .where.not(expires_at: nil)
                                .where("expires_at < ?", Time.zone.now)

      Rails.logger.warn("[SUBS DEBUG] Found #{expired_subscriptions.count} subscriptions to expire.")
      return if expired_subscriptions.empty?

      expired_subscriptions.each do |sub|
        begin
          user = sub.customer&.user
          unless user
            Rails.logger.warn("[SUBS DEBUG] Could not find user for subscription ID #{sub.id}, expiring it anyway.")
            sub.update(status: 'expired')
            next
          end

          # Attempt to find the plan on Stripe to get group info, but do not fail if it's missing
          if sub.plan_id && SiteSetting.discourse_subscriptions_public_key.present?
            begin
              plan = ::Stripe::Price.retrieve(sub.plan_id)
              group_name = plan.metadata&.group_name
              group = ::Group.find_by_name(group_name) if group_name.present?

              if group
                Rails.logger.warn("[SUBS DEBUG] Expiring user #{user.username} from group #{group.name} for subscription #{sub.external_id}")
                group.remove(user)
              end

            rescue ::Stripe::InvalidRequestError => e
              Rails.logger.warn("[SUBS DEBUG] Could not retrieve plan #{sub.plan_id} from Stripe while expiring sub #{sub.id}. It may have been deleted. Error: #{e.message}")
            end
          end

          # IMPORTANT: Mark the subscription as expired regardless of whether the group removal was successful
          sub.update(status: 'expired')
          Rails.logger.warn("[SUBS DEBUG] Successfully marked subscription #{sub.id} as 'expired' for user #{user.username}.")

        rescue => e
          Rails.logger.error("[SUBS DEBUG] Failed to process expired subscription #{sub.id}. Error: #{e.message}")
          next
        end
      end
    end
  end
end
