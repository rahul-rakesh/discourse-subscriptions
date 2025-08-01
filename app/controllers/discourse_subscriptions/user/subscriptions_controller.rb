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
        begin
          local_subscriptions = ::DiscourseSubscriptions::Subscription
                                  .joins(customer: :user)
                                  .where(users: { id: current_user.id })
                                  .order(created_at: :desc)

          processed_subscriptions = local_subscriptions.map do |sub|
            plan_nickname = "N/A"
            product_name = "N/A"
            renews_at = nil
            status = sub.status
            unit_amount = nil
            currency = nil
            plan_type = 'one_time'
            plan = nil

            if (sub.provider == 'Stripe' || sub.provider.nil?) && is_stripe_configured?
              begin
                plan = ::Stripe::Price.retrieve(id: sub.plan_id, expand: ['product']) rescue nil

                if sub.external_id.start_with?('sub_')
                  stripe_sub = ::Stripe::Subscription.retrieve(sub.external_id)
                  status = stripe_sub.status
                  if stripe_sub.cancel_at_period_end
                    status = 'canceled'
                  end
                  renews_at = stripe_sub.current_period_end
                  plan_type = 'recurring'
                elsif sub.expires_at
                  renews_at = sub.expires_at.to_i
                end
              rescue ::Stripe::InvalidRequestError
                status = 'not_in_stripe'
              end
            elsif sub.expires_at.present?
              renews_at = sub.expires_at.to_i
              plan = ::Stripe::Price.retrieve(id: sub.plan_id, expand: ['product']) rescue nil if is_stripe_configured?
            end

            if plan
              plan_nickname = plan[:nickname]
              product_name = plan[:product]&.name
              unit_amount = plan[:unit_amount]
              currency = plan[:currency]
              plan_type ||= plan[:type]
            end

            {
              id: sub.external_id,
              provider: (sub.provider || 'Stripe').capitalize,
              status: status,
              plan_nickname: plan_nickname,
              product_name: product_name,
              renews_at: renews_at,
              unit_amount: unit_amount,
              currency: currency,
              plan_type: plan_type
            }
          end.compact

          # FIX: This now renders the plain array, which the UI expects.
          render json: processed_subscriptions

        rescue => e
          Rails.logger.error("Error fetching user subscriptions: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}")
          render_json_error(e)
        end
      end

      def destroy
        begin
          stripe_sub = ::Stripe::Subscription.update(params[:id], { cancel_at_period_end: true })

          if stripe_sub
            local_sub = ::DiscourseSubscriptions::Subscription.find_by(external_id: params[:id])
            local_sub&.update(status: 'canceled')

            render json: {
              id: stripe_sub.id,
              status: 'canceled',
              renews_at: stripe_sub.current_period_end
            }
          else
            render_json_error I18n.t("discourse_subscriptions.customer_not_found")
          end
        rescue ::Stripe::InvalidRequestError => e
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
