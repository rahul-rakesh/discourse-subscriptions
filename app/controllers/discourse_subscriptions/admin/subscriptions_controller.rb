# frozen_string_literal: true

module DiscourseSubscriptions
  module Admin
    class SubscriptionsController < ::Admin::AdminController
      requires_plugin DiscourseSubscriptions::PLUGIN_NAME

      include DiscourseSubscriptions::Stripe
      include DiscourseSubscriptions::Group
      before_action :set_api_key
      skip_before_action :verify_authenticity_token, only: [:grant]

      PAGE_SIZE = 50

      def index
        Rails.logger.warn "[SUBS ADMIN DEBUG] --- Entering Admin Subscriptions: INDEX ---"
        begin
          offset = params[:offset].to_i

          local_subscriptions = ::DiscourseSubscriptions::Subscription
                                  .joins(customer: :user)
                                  .order(created_at: :desc)

          if params[:username].present?
            local_subscriptions = local_subscriptions.where("users.username_lower = ?", params[:username].downcase)
          end

          total_subscriptions = local_subscriptions.count
          more_records = total_subscriptions > (offset + PAGE_SIZE)
          local_subscriptions = local_subscriptions.limit(PAGE_SIZE).offset(offset)
          Rails.logger.warn "[SUBS ADMIN DEBUG] Found #{total_subscriptions} total subscriptions, processing page with #{local_subscriptions.count}."


          all_subscriptions = local_subscriptions.map do |sub|
            user_obj = sub.customer&.user
            next unless user_obj

            Rails.logger.warn "[SUBS ADMIN DEBUG] Processing local sub ID: #{sub.id}, external_id: #{sub.external_id}, provider: #{sub.provider || 'nil'}, local status: #{sub.status}"

            plan_nickname = "N/A"
            product_name = "N/A"
            renews_at = nil
            status = sub.status
            unit_amount = nil
            currency = nil
            plan_type = 'one_time'

            if (sub.provider == 'Stripe' || sub.provider.nil?) && sub.external_id.start_with?('sub_') && is_stripe_configured?
              begin
                Rails.logger.warn "[SUBS ADMIN DEBUG] Retrieving from Stripe: #{sub.external_id}"
                stripe_sub = ::Stripe::Subscription.retrieve(id: sub.external_id, expand: ['items.data.price.product'])
                price = stripe_sub.items.data[0].price

                plan_nickname = price.nickname
                product_name = price.product.name
                unit_amount = price.unit_amount
                currency = price.currency
                status = stripe_sub.status # Get the latest status from Stripe

                # If canceled at period end, reflect this in our status and set the expiry date
                if stripe_sub.cancel_at_period_end
                  status = 'canceled'
                  renews_at = stripe_sub.current_period_end
                  Rails.logger.warn "[SUBS ADMIN DEBUG] Sub is set to cancel at period end. New Expiry: #{Time.at(renews_at).utc}"
                else
                  renews_at = stripe_sub.current_period_end
                  Rails.logger.warn "[SUBS ADMIN DEBUG] Sub is active. Next renewal: #{Time.at(renews_at).utc}"
                end

                plan_type = price.type
              rescue ::Stripe::InvalidRequestError => e
                Rails.logger.error "[SUBS ADMIN DEBUG] Stripe API error for #{sub.external_id}: #{e.message}"
                status = 'not_in_stripe'
              end
            elsif sub.expires_at.present? # For one-time payments (Razorpay, Manual)
              renews_at = sub.expires_at.to_i
              Rails.logger.warn "[SUBS ADMIN DEBUG] One-time sub. Expiry from DB: #{sub.expires_at.utc}"
            else
              Rails.logger.warn "[SUBS ADMIN DEBUG] Could not determine renewal date for #{sub.external_id}."
            end

            {
              id: sub.external_id,
              provider: (sub.provider || 'Stripe').capitalize,
              status: status,
              user: { id: user_obj.id, username: user_obj.username, avatar_template: user_obj.avatar_template_url },
              created_at: sub.created_at.to_i,
              expires_at: renews_at,
              plan_name: product_name,
              plan_nickname: plan_nickname,
              unit_amount: unit_amount,
              currency: currency,
              plan_type: plan_type
            }
          end.compact

          Rails.logger.warn "[SUBS ADMIN DEBUG] Finished processing. Sending payload to frontend."
          render json: {
            subscriptions: all_subscriptions,
            meta: {
              more: more_records,
              offset: offset + PAGE_SIZE,
              username: params[:username].presence
            }
          }

        rescue => e
          Rails.logger.error("Discourse Subscriptions Error: Failed to process admin subscriptions. Class: #{e.class.name}, Message: #{e.message}, Backtrace: #{e.backtrace.join("\n")}")
          render_json_error(e.message)
        end
      end

      def destroy
        params.require(:id)
        begin
          subscription = ::Stripe::Subscription.update(params[:id], { cancel_at_period_end: true })
          local_sub = ::DiscourseSubscriptions::Subscription.find_by(external_id: params[:id])
          local_sub&.update(status: 'canceled')
          render json: subscription
        rescue ::Stripe::InvalidRequestError => e
          render_json_error e.message
        end
      end

      def revoke
        params.require(:id)
        begin
          subscription = ::DiscourseSubscriptions::Subscription.find_by(external_id: params[:id])
          return render_json_error("Subscription not found") unless subscription

          user = subscription.customer&.user
          plan = ::Stripe::Price.retrieve(subscription.plan_id) if subscription.plan_id

          return render_json_error("Could not retrieve plan details.") if plan.nil?

          group = plan_group(plan)

          if user && group
            safely_remove_user_from_group(user, group, subscription.id)
            subscription.update(status: 'revoked')
            render json: success_json
          else
            render_json_error("Could not find user or group for this subscription.")
          end
        rescue => e
          render_json_error(e.message)
        end
      end

      def grant
        params.require(%i[username plan_id])
        begin
          user = ::User.find_by_username(params[:username])
          return render_json_error("User not found.") unless user

          plan = ::Stripe::Price.retrieve(params[:plan_id])
          return render_json_error("Plan not found.") unless plan

          transaction = {
            id: "manual_#{SecureRandom.hex(8)}",
            customer: "cus_manual_#{user.id}"
          }

          subscribe_controller = DiscourseSubscriptions::SubscribeController.new
          # We need to use `send` because `finalize_discourse_subscription` is a private method
          subscribe_controller.send(:finalize_discourse_subscription, transaction, plan, user, params[:duration], 'manual')
          render json: success_json

        rescue ActiveRecord::RecordInvalid => e
          render_json_error(e.record.errors.full_messages.join(", "))
        rescue => e
          render_json_error(e.message)
        end
      end

      private

      def safely_remove_user_from_group(user, group_to_remove_from, current_sub_id)
        other_subscriptions = ::DiscourseSubscriptions::Subscription
                                .joins(:customer)
                                .where(discourse_subscriptions_customers: { user_id: user.id })
                                .where(status: 'active')
                                .where.not(id: current_sub_id)

        has_other_access = other_subscriptions.any? do |sub|
          if sub.plan_id.present?
            begin
              other_plan = ::Stripe::Price.retrieve(sub.plan_id)
              other_group = plan_group(other_plan)
              other_group&.id == group_to_remove_from.id
            rescue ::Stripe::InvalidRequestError
              false
            end
          else
            false
          end
        end

        unless has_other_access
          group_to_remove_from.remove(user)
        end
      end
    end
  end
end
