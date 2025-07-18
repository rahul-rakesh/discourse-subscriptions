# frozen_string_literal: true

module DiscourseSubscriptions
  class SubscribeController < ::ApplicationController
    include DiscourseSubscriptions::Stripe
    include DiscourseSubscriptions::Group

    requires_plugin DiscourseSubscriptions::PLUGIN_NAME

    before_action :set_api_key
    requires_login except: %i[index]

    def index
      begin
        products = []
        if is_stripe_configured?
          local_products = ::DiscourseSubscriptions::Product.all
          user_products = current_user_products

          local_products.each do |p|
            begin
              product_data = ::Stripe::Product.retrieve(p.external_id)
              next unless product_data.active

              product_plans_data = ::Stripe::Price.list(
                product: product_data.id,
                active: true,
                limit: 100
              )

              is_subscribed = user_products.include?(product_data.id)
              is_repurchaseable = product_data.metadata[:repurchaseable] == "true"


              products << {
                id: product_data.id,
                name: product_data.name,
                description: PrettyText.cook(product_data.description || product_data.metadata[:description]),
                subscribed: is_subscribed && !is_repurchaseable,
                repurchaseable: is_repurchaseable,
                metadata: product_data.metadata.to_h,
                plans: serialize_plans(product_plans_data)
              }
            rescue ::Stripe::InvalidRequestError => e
              Rails.logger.warn("[Subscriptions] Could not retrieve Stripe product with ID #{p.external_id}: #{e.message}")
              next
            end
          end
        end
        render_json_dump products.sort_by { |p| p[:name] }
      rescue ::Stripe::InvalidRequestError => e
        render_json_error e.message
      end
    end

    def create
      params.require(:plan)
      begin
        plan = ::Stripe::Price.retrieve(params[:plan])

        if SiteSetting.discourse_subscriptions_payment_provider == "Razorpay"
          if plan.type == 'recurring'
            return render_json_error(I18n.t("js.discourse_subscriptions.razorpay.recurring_not_supported"))
          end
          notes = { user_id: current_user.id, username: current_user.username, plan_id: plan.id }
          order = DiscourseSubscriptions::Providers::RazorpayProvider.create_order(plan[:unit_amount], plan[:currency].upcase, notes)
          render_json_dump order
        else
          mode = plan.type == 'recurring' ? 'subscription' : 'payment'
          success_url = "#{Discourse.base_url}/u/#{current_user.username_lower}/billing/subscriptions?checkout=success"
          cancel_url = "#{Discourse.base_url}/s?checkout=cancel"
          session = ::Stripe::Checkout::Session.create(
            customer_email: current_user.email,
            payment_method_types: ['card'],
            line_items: [{ price: plan.id, quantity: 1 }],
            mode: mode,
            success_url: success_url,
            cancel_url: cancel_url,
            metadata: metadata_user
          )
          render json: { session_id: session.id }
        end
      rescue ::Stripe::InvalidRequestError, ::Razorpay::Error => e
        render_json_error e.message
      end
    end

    def finalize_razorpay_payment
      params.require(%i[plan_id razorpay_payment_id razorpay_order_id razorpay_signature])
      begin
        if DiscourseSubscriptions::Providers::RazorpayProvider.verify_payment(params[:razorpay_payment_id], params[:razorpay_order_id], params[:razorpay_signature])
          plan = ::Stripe::Price.retrieve(params[:plan_id])
          transaction = { id: params[:razorpay_payment_id], customer: "cus_razorpay_#{current_user.id}" }
          finalize_discourse_subscription(transaction, plan, current_user, nil, 'Razorpay')
          render json: success_json
        else
          render_json_error(I18n.t("discourse_subscriptions.card.declined"))
        end
      rescue ::Razorpay::Error, ::Stripe::InvalidRequestError => e
        render_json_error(e.message)
      end
    end

    private

    def finalize_discourse_subscription(transaction, plan, user, duration_in_days = nil, provider = nil)
      group_name = plan[:metadata][:group_name]
      group = ::Group.find_by_name(group_name) if group_name.present?
      group&.add(user)

      duration = duration_in_days.present? ? duration_in_days.to_i : nil
      duration ||= plan[:metadata][:duration]&.to_i

      expires_at = duration.present? && duration > 0 ? duration.days.from_now : nil

      customer = ::DiscourseSubscriptions::Customer.find_or_create_by!(user_id: user.id) do |c|
        c.customer_id = transaction[:customer]
      end
      customer.update!(customer_id: transaction[:customer])

      ::DiscourseSubscriptions::Subscription.create!(
        customer_id: customer.id,
        external_id: transaction[:id],
        status: "active",
        provider: provider || SiteSetting.discourse_subscriptions_payment_provider,
        plan_id: plan.id,
        product_id: plan[:product],
        duration: duration,
        expires_at: expires_at
      )
    end

    def current_user_products
      return [] if current_user.nil?

      user_subs = ::DiscourseSubscriptions::Subscription.joins(:customer)
                                                        .where(discourse_subscriptions_customers: { user_id: current_user.id })
                                                        .where(status: 'active')
                                                        .where("expires_at IS NULL OR expires_at > ?", Time.zone.now)

      plan_ids = user_subs.pluck(:plan_id).uniq

      return [] if plan_ids.empty? || !is_stripe_configured?

      product_ids = plan_ids.map do |plan_id|
        begin
          plan = ::Stripe::Price.retrieve(plan_id)
          plan[:product]
        rescue ::Stripe::InvalidRequestError => e
          nil
        end
      end.compact.uniq

      return product_ids
    end

    def serialize_plans(plans)
      plans[:data]
        .map do |plan|
        next if plan.unit_amount.to_i == 0
        { id: plan.id, unit_amount: plan.unit_amount, currency: plan.currency, type: plan.type, recurring: plan.recurring, nickname: plan.nickname, metadata: plan.metadata.to_h }
      end.compact.sort_by { |plan| plan[:unit_amount] }
    end

    def contributors
      return unless SiteSetting.discourse_subscriptions_campaign_show_contributors

      subscriptions = ::DiscourseSubscriptions::Subscription.order(created_at: :desc)

      campaign_product = SiteSetting.discourse_subscriptions_campaign_product
      if campaign_product.present?
        subscriptions = subscriptions.where(product_id: campaign_product)
      end

      user_ids = subscriptions.limit(15).joins(:customer).pluck("discourse_subscriptions_customers.user_id").uniq.first(5)

      contributors = ::User.where(id: user_ids)

      # Renders the user data needed for the avatar display on the campaign banner
      render_serialized(contributors, BasicUserSerializer)
    end

    def metadata_user
      { user_id: current_user.id, username: current_user.username_lower }
    end
  end
end
