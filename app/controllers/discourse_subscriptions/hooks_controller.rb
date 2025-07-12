# frozen_string_literal: true

require 'razorpay'

module DiscourseSubscriptions
  class HooksController < ::ApplicationController
    include DiscourseSubscriptions::Group
    include DiscourseSubscriptions::Stripe

    requires_plugin DiscourseSubscriptions::PLUGIN_NAME

    layout false

    before_action :set_api_key, except: [:razorpay]
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required
    skip_before_action :verify_authenticity_token, only: %i[create razorpay]

    def create
      begin
        payload = request.body.read
        sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
        webhook_secret = SiteSetting.discourse_subscriptions_webhook_secret
        event = ::Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
        Rails.logger.warn("[SUBS DEBUG] Webhook signature verified. Event Type: #{event[:type]}")
      rescue JSON::ParserError => e
        Rails.logger.error("[SUBS DEBUG] JSON Parser Error: #{e.message}")
        return render_json_error e.message
      rescue ::Stripe::SignatureVerificationError => e
        Rails.logger.error("[SUBS DEBUG] Signature Verification Error: #{e.message}")
        return render_json_error e.message
      end

      Rails.logger.warn("[SUBS DEBUG] Full event payload: #{event.to_json}")

      case event[:type]
      when "checkout.session.completed"
        checkout_session = event[:data][:object]
        Rails.logger.warn("[SUBS DEBUG] Processing checkout.session.completed. Payment Status: #{checkout_session[:payment_status]}")

        if checkout_session[:payment_status] != "paid"
          Rails.logger.warn("[SUBS DEBUG] Exiting because payment_status is not 'paid'.")
          return head 200
        end

        external_id = checkout_session[:subscription] || checkout_session[:id]
        if ::DiscourseSubscriptions::Subscription.exists?(external_id: external_id)
          Rails.logger.warn("[SUBS DEBUG] Exiting because subscription with external_id #{external_id} already exists.")
          return head 200
        end

        email = checkout_session[:customer_details][:email]
        Rails.logger.warn("[SUBS DEBUG] Attempting to find email. Found: #{email}")
        return render_json_error "customer email not found in webhook" if email.blank?

        user = ::User.find_by_username_or_email(email)
        return render_json_error "user not found" if !user
        Rails.logger.warn("[SUBS DEBUG] Found user: #{user.username}")

        begin
          line_items = ::Stripe::Checkout::Session.list_line_items(checkout_session[:id], { limit: 1 })
          item = line_items[:data].first
          plan = item[:price]
          Rails.logger.warn("[SUBS DEBUG] Successfully retrieved plan object from line items: #{plan[:id]}")
        rescue => e
          Rails.logger.error("[SUBS DEBUG] FAILED to retrieve line items or plan. Error: #{e.message}")
          return head 200
        end

        group = plan_group(plan)
        Rails.logger.warn("[SUBS DEBUG] Group from plan metadata: #{group&.name || 'None'}")

        stripe_customer_id = checkout_session[:customer] || "cus_#{user.id}_#{SecureRandom.hex(8)}"
        Rails.logger.warn("[SUBS DEBUG] Using Stripe customer ID: #{stripe_customer_id}")

        discourse_customer = Customer.find_or_create_by!(user_id: user.id) do |c|
          c.customer_id = stripe_customer_id
        end
        Rails.logger.warn("[SUBS DEBUG] Created/found local customer record: #{discourse_customer.id}")

        discourse_customer.update!(product_id: plan[:product])
        Rails.logger.warn("[SUBS DEBUG] Associated product #{plan[:product]} with customer #{discourse_customer.id}")

        metadata = plan[:metadata]
        duration = metadata[:duration]&.to_i
        expires_at = duration.present? && duration > 0 ? duration.days.from_now : nil
        Rails.logger.warn("[SUBS DEBUG] Calculated duration: #{duration || 'nil'}, expires_at: #{expires_at || 'nil'}")

        new_subscription = Subscription.new(
          customer_id: discourse_customer.id,
          external_id: external_id,
          plan_id: plan[:id],
          product_id: plan[:product],
          provider: 'Stripe',
          status: 'active',
          duration: duration,
          expires_at: expires_at
        )

        if new_subscription.save
          Rails.logger.warn("[SUBS DEBUG] Successfully saved new subscription record: #{new_subscription.id}")
        else
          Rails.logger.error("[SUBS DEBUG] FAILED to save subscription record. Errors: #{new_subscription.errors.full_messages.join(', ')}")
        end

        group&.add(user)
        Rails.logger.warn("[SUBS DEBUG] Process complete.")

      when "customer.subscription.updated"
        subscription_data = event[:data][:object]
        local_subscription = ::DiscourseSubscriptions::Subscription.find_by(external_id: subscription_data.id)
        return head 200 unless local_subscription
        local_subscription.update(status: subscription_data.status)
        if local_subscription.status == 'active'
          price = subscription_data.items.data[0].price
          if group = plan_group(price)
            group.add(local_subscription.customer.user)
          end
        end

      when "customer.subscription.deleted"
        subscription = event[:data][:object]
        local_sub = ::DiscourseSubscriptions::Subscription.find_by(external_id: subscription.id)
        return head 200 unless local_sub
        local_sub.update(status: subscription.status)
        price = subscription[:items][:data][0][:price]
        return head 200 unless price
        if (group = plan_group(price)) && local_sub.customer&.user
          safely_remove_user_from_group(local_sub.customer.user, group, local_sub.id)
        end
      end

      head 200
    end

    def razorpay
      webhook_secret = SiteSetting.discourse_subscriptions_razorpay_webhook_secret
      webhook_body = request.body.read
      signature = request.env['HTTP_X_RAZORPAY_SIGNATURE']

      begin
        DiscourseSubscriptions::Providers::RazorpayProvider.verify_webhook_signature(webhook_body, signature, webhook_secret)
      rescue ::Razorpay::Error::SignatureVerificationError => e
        Rails.logger.error("Razorpay webhook verification failed: #{e.message}")
        return render_json_error "Invalid webhook signature", status: 403
      end

      event = JSON.parse(webhook_body)

      if event['event'] == 'payment.captured'
        payment_entity = event.dig('payload', 'payment', 'entity')
        payment_id = payment_entity['id']
        notes = payment_entity['notes']

        if notes.blank? || notes['user_id'].blank? || notes['plan_id'].blank?
          Rails.logger.error("Razorpay webhook error: Missing metadata in payment #{payment_id}")
          return render_json_error("Webhook payload is missing required metadata")
        end

        if ::DiscourseSubscriptions::Subscription.exists?(external_id: payment_id)
          return head 200
        end

        user = ::User.find_by(id: notes['user_id'])
        plan = is_stripe_configured? ? ::Stripe::Price.retrieve(notes['plan_id']) : nil

        if user && plan
          transaction = {
            id: payment_id,
            customer: "cus_razorpay_#{user.id}"
          }

          subscribe_controller = DiscourseSubscriptions::SubscribeController.new
          subscribe_controller.instance_variable_set(:@current_user, user)
          subscribe_controller.send(:finalize_discourse_subscription, transaction, plan, user, nil, 'Razorpay')
        else
          Rails.logger.error("Razorpay webhook error: Could not find User(#{notes['user_id']}) or Plan(#{notes['plan_id']})")
        end
      end

      head 200
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

    def update_status(customer_id, subscription_id, status)
      discourse_subscription =
        Subscription.find_by(customer_id: customer_id, external_id: subscription_id)
      discourse_subscription.update(status: status) if discourse_subscription
    end

    def find_active_customer(customer_id, product_id)
      Customer
        .joins(:subscriptions)
        .where(customer_id: customer_id, product_id: product_id)
        .where(
          Subscription.arel_table[:status].eq(nil).or(
            Subscription.arel_table[:status].not_eq("canceled"),
            ),
          )
        .first
    end
  end
end
