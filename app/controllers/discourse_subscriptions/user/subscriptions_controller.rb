# frozen_string_literal: true

module DiscourseSubscriptions
  module User
    class SubscriptionsController < ::ApplicationController
      include DiscourseSubscriptions::Stripe
      include DiscourseSubscriptions::Group

      requires_plugin DiscourseSubscriptions::PLUGIN_NAME

      before_action :set_api_key
      requires_login

      def index
        Rails.logger.warn "[SUBS DEBUG] --- Entering User Subscriptions: INDEX ---"
        begin
          local_subscriptions = ::DiscourseSubscriptions::Subscription
                                  .joins(customer: :user)
                                  .where(users: { id: current_user.id })
                                  .order(created_at: :desc)

          Rails.logger.warn "[SUBS DEBUG] Found #{local_subscriptions.count} local subscription records."

          return render json: [] if local_subscriptions.empty?

          processed_subscriptions = local_subscriptions.map do |sub|
            Rails.logger.warn "[SUBS DEBUG] Processing local sub ID: #{sub.id}, external_id: #{sub.external_id}, provider: #{sub.provider || 'nil'}, status: #{sub.status}"

            plan = nil
            renews_at_timestamp = nil
            status = sub.status

            if (sub.provider == 'Stripe' || sub.provider.nil?) && sub.external_id.start_with?('sub_') && is_stripe_configured?
              begin
                Rails.logger.warn "[SUBS DEBUG] Retrieving from Stripe: #{sub.external_id}"
                stripe_sub = ::Stripe::Subscription.retrieve(id: sub.external_id, expand: ['items.data.price.product'])
                price = stripe_sub[:items][:data][0][:price]
                Rails.logger.warn "[SUBS DEBUG] Stripe retrieve successful. Plan ID: #{price&.id}, Recurring: #{price&.recurring.present?}"

                plan = price
                status = stripe_sub[:status]

                if stripe_sub[:cancel_at_period_end]
                  status = 'canceled'
                  renews_at_timestamp = stripe_sub[:current_period_end]
                  Rails.logger.warn "[SUBS DEBUG] Sub is set to cancel at period end. New Expiry: #{Time.at(renews_at_timestamp).utc}"
                else
                  renews_at_timestamp = stripe_sub[:current_period_end]
                  Rails.logger.warn "[SUBS DEBUG] Sub is active. Next renewal: #{Time.at(renews_at_timestamp).utc}"
                end

              rescue ::Stripe::InvalidRequestError => e
                Rails.logger.error "[SUBS DEBUG] Stripe API error for #{sub.external_id}: #{e.message}"
                status = 'not_in_stripe'
              end
            elsif sub.expires_at.present?
              renews_at_timestamp = sub.expires_at.to_i
              Rails.logger.warn "[SUBS DEBUG] One-time sub. Expiry from DB: #{sub.expires_at.utc}"
            else
              Rails.logger.warn "[SUBS DEBUG] Could not determine renewal date for #{sub.external_id}."
            end

            next unless plan

            {
              id: sub.external_id,
              provider: (sub.provider || 'Stripe').capitalize,
              status: status,
              plan_nickname: plan[:nickname],
              product_name: plan[:product]&.name,
              renews_at: renews_at_timestamp,
              unit_amount: plan[:unit_amount],
              currency: plan[:currency],
              plan_type: plan[:type]
            }
          end.compact

          Rails.logger.warn "[SUBS DEBUG] Final payload being sent to frontend: #{processed_subscriptions.to_json}"
          render json: processed_subscriptions

        rescue => e
          Rails.logger.error("[SUBS DEBUG] UNHANDLED ERROR in User Subscriptions INDEX: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}")
          render_json_error(e)
        end
      end

      def destroy
        Rails.logger.warn "[SUBS DEBUG] --- Entering User Subscriptions: DESTROY (Cancel) ---"
        Rails.logger.warn "[SUBS DEBUG] Canceling subscription ID: #{params[:id]}"
        begin
          stripe_sub = ::Stripe::Subscription.update(params[:id], { cancel_at_period_end: true })

          if stripe_sub
            Rails.logger.warn "[SUBS DEBUG] Stripe API call successful."
            local_sub = ::DiscourseSubscriptions::Subscription.find_by(external_id: params[:id])
            local_sub&.update(status: 'canceled')
            Rails.logger.warn "[SUBS DEBUG] Local DB record status updated to 'canceled'."

            response = {
              id: stripe_sub.id,
              status: 'canceled',
              renews_at: stripe_sub.current_period_end,
              plan_type: 'recurring'
            }

            Rails.logger.warn "[SUBS DEBUG] Sending success response to frontend: #{response.to_json}"
            render json: response
          else
            Rails.logger.error "[SUBS DEBUG] Stripe API did not return a subscription object."
            render_json_error I18n.t("discourse_subscriptions.customer_not_found")
          end
        rescue ::Stripe::InvalidRequestError => e
          Rails.logger.error "[SUBS DEBUG] Stripe API error on cancel: #{e.message}"
          render_json_error e.message
        end
      end

      def update
        params.require(:payment_method)
        begin
          subscription = ::DiscourseSubscriptions::Subscription.find_by(external_id: params[:id])
          customer = ::DiscourseSubscriptions::Customer.find(subscription.customer_id)

          ::Stripe::PaymentMethod.attach(params[:payment_method], { customer: customer.customer_id })

          ::Stripe::Subscription.update(
            params[:id],
            { default_payment_method: params[:payment_method] },
            )
          render json: success_json
        rescue ::Stripe::InvalidRequestError
          render_json_error I18n.t("discourse_subscriptions.card.invalid")
        end
      end
    end
  end
end
