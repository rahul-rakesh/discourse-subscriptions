import Route from "@ember/routing/route";
import { service } from "@ember/service"; // Import service
import Product from "discourse/plugins/discourse-subscriptions/discourse/models/product";
import Plan from "discourse/plugins/discourse-subscriptions/discourse/models/plan";

export default class SubscribeIndexRoute extends Route {
  @service siteSettings; // Inject siteSettings service

  model() {
    return Product.findAll().then(products => {
      const isRazorpay = this.siteSettings.discourse_subscriptions_payment_provider === 'Razorpay';

      products.forEach(product => {
        if (product.plans && product.plans.length > 0) {
          let plans = product.plans;

          // If Razorpay is active, filter out any recurring plans
          if (isRazorpay) {
            plans = plans.filter(p => p.type !== 'recurring');
          }

          const planModels = plans.map(p => Plan.create(p));
          product.set('plans', planModels);
        }
      });
      // Filter out products that have no plans left after filtering
      return products.filter(p => p.plans && p.plans.length > 0);
    });
  }
}
