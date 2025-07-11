# frozen_string_literal: true

module ::Jobs
  class CheckExpiredSubscriptions < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      Rails.logger.warn("[SUBS JOB DEBUG] --- Starting CheckExpiredSubscriptions job at #{Time.zone.now} ---")

      api_key = args[:api_key] || SiteSetting.discourse_subscriptions_secret_key
      unless api_key.present?
        Rails.logger.error("[SUBS JOB DEBUG] FAILED: Stripe secret key is not configured.")
        return
      end

      ::Stripe.api_key = api_key
      Rails.logger.warn("[SUBS JOB DEBUG] Stripe API key has been set.")

      expired_subscriptions = ::DiscourseSubscriptions::Subscription
                                .where(status: 'active')
                                .where.not(expires_at: nil)
                                .where("expires_at < ?", Time.zone.now)

      Rails.logger.warn("[SUBS JOB DEBUG] Found #{expired_subscriptions.count} subscriptions to expire.")
      return if expired_subscriptions.empty?

      expired_subscriptions.each do |sub|
        Rails.logger.warn("[SUBS JOB DEBUG] Processing subscription with attributes: #{sub.attributes.inspect}")
        begin
          user = sub.customer&.user

          if user && sub.plan_id
            begin
              plan = ::Stripe::Price.retrieve(sub.plan_id)
              group_name = plan[:metadata][:group_name]
              group = ::Group.find_by_name(group_name) if group_name.present?

              if group
                Rails.logger.warn("[SUBS JOB DEBUG] Removing user #{user.username} from group #{group.name}.")
                group.remove(user)
              end
            rescue => e
              Rails.logger.warn("[SUBS JOB DEBUG] Could not remove from group for sub #{sub.id}. Reason: #{e.message}")
            end
          end

          Rails.logger.warn("[SUBS JOB DEBUG] About to update subscription ID: #{sub.id} to status 'expired'.")
          if sub.update(status: 'expired')
            Rails.logger.warn("[SUBS JOB DEBUG] SUCCESS: Marked subscription #{sub.id} as 'expired'.")
          else
            Rails.logger.error("[SUBS JOB DEBUG] FAILED to update subscription #{sub.id}. Errors: #{sub.errors.full_messages.join(', ')}")
          end

        rescue => e
          Rails.logger.error("[SUBS JOB DEBUG] FATAL: Unhandled exception for sub #{sub.id}. Error: #{e.class} #{e.message}")
          next
        end
      end
      Rails.logger.warn("[SUBS JOB DEBUG] --- Finished CheckExpiredSubscriptions job ---")
    end
  end
end
