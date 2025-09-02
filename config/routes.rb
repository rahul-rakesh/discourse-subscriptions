# frozen_string_literal: true
require_dependency "subscriptions_user_constraint"

DiscourseSubscriptions::Engine.routes.draw do
  scope "admin" do
    get "/" => "admin#index"
  end

  namespace :admin, constraints: AdminConstraint.new do
    resources :plans
    resources :subscriptions, only: %i[index destroy] do # Add a do/end block here
      post :revoke, on: :member
      post :grant, on: :collection
      get :load_details, on: :member  # ADD THIS LINE
    end
    resources :products
    resources :coupons, only: %i[index create]
    resource :coupons, only: %i[destroy update]
  end

  namespace :user do
    resources :payments, only: [:index]
    resources :subscriptions, only: %i[index update destroy]
  end

  get "/" => "subscribe#index"
  get ".json" => "subscribe#index"
  get "/:id" => "subscribe#show"
  post "/create" => "subscribe#create"
  post "/finalize" => "subscribe#finalize"
  post "/finalize_razorpay_payment" => "subscribe#finalize_razorpay_payment"

  post "/hooks" => "hooks#create"
  post "/hooks/razorpay" => "hooks#razorpay"
end
