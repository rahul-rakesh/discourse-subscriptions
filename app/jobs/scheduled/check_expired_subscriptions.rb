# frozen_string_literal: true

module ::Jobs
  class CheckExpiredSubscriptions < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      Rails.logger.warn("[SUBS JOB DEBUG] --- Starting CheckExpiredSubscriptions job at #{Time.zone.now} ---")
      return unless SiteSetting.discourse_subscriptions_enabled

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
          unless user
            Rails.logger.warn("[SUBS JOB DEBUG] Could not find user for subscription ID #{sub.id}, expiring it anyway.")
            sub.update!(status: 'expired')
            next
          end

          if sub.plan_id && SiteSetting.discourse_subscriptions_public_key.present?
            begin
              plan = ::Stripe::Price.retrieve(sub.plan_id)
              group_name = plan[:metadata][:group_name]
              group = ::Group.find_by_name(group_name) if group_name.present?

              if group
                Rails.logger.warn("[SUBS JOB DEBUG] Expiring user #{user.username} from group #{group.name} for subscription #{sub.id}")
                group.remove(user)
              end

            rescue ::Stripe::InvalidRequestError => e
              Rails.logger.warn("[SUBS JOB DEBUG] Could not retrieve plan #{sub.plan_id} from Stripe while expiring sub #{sub.id}. It may have been deleted. Error: #{e.message}")
            end
          end

          Rails.logger.warn("[SUBS JOB DEBUG] About to update subscription ID: #{sub.id} to status 'expired'.")
          if sub.update(status: 'expired')
            Rails.logger.warn("[SUBS JOB DEBUG] SUCCESS: Marked subscription #{sub.id} as 'expired' for user #{user.username}.")
          else
            Rails.logger.error("[SUBS JOB DEBUG] FAILED to update subscription #{sub.id}. Errors: #{sub.errors.full_messages.join(', ')}")
          end

        rescue => e
          Rails.logger.error("[SUBS JOB DEBUG] UNHANDLED EXCEPTION while processing subscription #{sub.id}. Error: #{e.class} #{e.message}")
          next
        end
      end
      Rails.logger.warn("[SUBS JOB DEBUG] --- Finished CheckExpiredSubscriptions job ---")
    end
  end
end
